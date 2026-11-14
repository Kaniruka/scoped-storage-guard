#!/system/bin/sh
# Scoped Storage Guard supervisor.
#
# Resolves one complete snapshot, publishes it exactly once over an empty
# registry, keeps it current, and releases only this module's own generation.
# All state is root-only; the default status carries no paths and no UID table.
set -u
umask 077

SELF_DIR=$(dirname "$0")
MODDIR=$(dirname "$SELF_DIR")

STATE_DIR=${SCV_STATE_DIR:-/data/adb/scoped-storage-guard}
CONFIG=${SCV_CONFIG:-$MODDIR/config/scv.conf}
CONTROL=${SCV_CONTROL:-/sys/kernel/security/scoped_visibility/control}
SVREG=${SCV_SVREG:-$SELF_DIR/svreg}
SVCTL=${SCV_SVCTL:-$SELF_DIR/svctl}
RESOLVER=${SCV_RESOLVER:-$SELF_DIR/scv-resolve.sh}
GETPROP=${SCV_GETPROP:-getprop}
PM=${SCV_PM:-pm}
NS_MODE=${SCV_NS_MODE:-}
NS_PREFIX=${SCV_NS:-}
LEGACY_STATE=${SCV_LEGACY_STATE:-/data/adb/scoped-visibility}
LEGACY_MODULE=${SCV_LEGACY_MODULE:-/data/adb/modules/gki_scoped_visibility}

WAIT_INTERVAL=${SCV_WAIT_INTERVAL:-5}
STEADY_INTERVAL=${SCV_STEADY_INTERVAL:-20}
SLOW_INTERVAL=${SCV_SLOW_INTERVAL:-30}
MAX_WAIT=${SCV_MAX_WAIT:-900}
MAX_CYCLES=${SCV_MAX_CYCLES:-0}
MAX_APPLY_FAIL=${SCV_MAX_APPLY_FAIL:-3}
LOG_MAX=${SCV_LOG_MAX:-65536}
CONTROL_TRIES=${SCV_CONTROL_TRIES:-3}

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOT_ID" ] || BOOT_ID=unknown
STATUS=$STATE_DIR/status
LOG=$STATE_DIR/log
LOCKD=$STATE_DIR/lock
OWNER=$LOCKD/owner
STOP=$STATE_DIR/stop
RESOLVE=$STATE_DIR/resolve
SNAPSHOT=$STATE_DIR/snapshot
DIAG=$STATE_DIR/diagnostics

STATE=
REASON=
PUBLISHED=0
EXPECT_GEN=
SAVED_GEN=
SAVED_FP=
CFG_SAVED=
FS_ALLOW=fuse,f2fs,ext4
ISO=unknown
FAILS=0
CYCLES=0
WAITED=0
C_GEN=
C_COUNT=
NEW_GEN=
RC=1

log_line() {
	printf '%s boot=%s %s gen=%s count=%s\n' \
		"$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null)" "$BOOT_ID" "$*" \
		"${SAVED_GEN:--}" "$(grep -c . "$SNAPSHOT" 2>/dev/null)" \
		>>"$LOG" 2>/dev/null
	[ -f "$LOG" ] || return 0
	sz=$(wc -c <"$LOG" 2>/dev/null)
	[ -n "$sz" ] || return 0
	if [ "$sz" -gt "$LOG_MAX" ]; then
		mv -f "$LOG" "$LOG.old" 2>/dev/null
	fi
}

set_state() { # state reason
	[ -n "$STATE" ] && [ "$1" = "$STATE" ] && [ "$2" = "$REASON" ] && return 0
	STATE=$1
	REASON=$2
	tmp=$STATUS.tmp.$$
	gen=-
	[ -n "$SAVED_GEN" ] && gen=$SAVED_GEN
	cnt=$(grep -c . "$SNAPSHOT" 2>/dev/null)
	[ -n "$cnt" ] || cnt=0
	{
		printf 'module_id=scoped_storage_guard\n'
		printf 'state=%s\n' "$STATE"
		printf 'reason=%s\n' "$REASON"
		printf 'published=%s\n' "$PUBLISHED"
		printf 'generation=%s\n' "$gen"
		printf 'expected_generation=%s\n' "$EXPECT_GEN"
		printf 'count=%s\n' "$cnt"
		printf 'users=%s\n' "${RES_USERS:-0}"
		printf 'isolate=%s\n' "$ISO"
		printf 'namespace=%s\n' "$NS_MODE"
		printf 'boot_id=%s\n' "$BOOT_ID"
		printf 'pid=%s\n' "$$"
		printf 'updated=%s\n' "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null)"
	} >"$tmp" 2>/dev/null || return 0
	chmod 600 "$tmp" 2>/dev/null
	mv -f "$tmp" "$STATUS" 2>/dev/null
	log_line "$STATE $REASON"
}

owner_verified() {
	p=$1
	[ -n "$p" ] || return 1
	[ -r "/proc/$p/cmdline" ] || return 1
	tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -q 'autostart.sh' || return 1
	return 0
}

take_lock() {
	mkdir -p "$STATE_DIR" 2>/dev/null || exit 1
	chmod 700 "$STATE_DIR" 2>/dev/null
	tries=0
	while [ "$tries" -lt 3 ]; do
		tries=$((tries + 1))
		if mkdir "$LOCKD" 2>/dev/null; then
			{
				printf 'pid=%s\n' "$$"
				printf 'boot_id=%s\n' "$BOOT_ID"
				printf 'module=scoped_storage_guard\n'
			} >"$OWNER" 2>/dev/null
			chmod 600 "$OWNER" 2>/dev/null
			return 0
		fi
		lpid=$(sed -n 's/^pid=//p' "$OWNER" 2>/dev/null | head -n1)
		lboot=$(sed -n 's/^boot_id=//p' "$OWNER" 2>/dev/null | head -n1)
		if [ "$lboot" = "$BOOT_ID" ] && owner_verified "$lpid"; then
			return 1
		fi
		rm -rf "$LOCKD" 2>/dev/null
	done
	return 1
}

drop_lock() {
	[ -d "$LOCKD" ] || return 0
	lpid=$(sed -n 's/^pid=//p' "$OWNER" 2>/dev/null | head -n1)
	[ "$lpid" = "$$" ] && rm -rf "$LOCKD" 2>/dev/null
	return 0
}

detect_ns() {
	[ "$NS_MODE" = direct ] && return 0
	[ "$NS_MODE" = ns ] && [ -n "$NS_PREFIX" ] && return 0
	init_ns=$(readlink /proc/1/ns/mnt 2>/dev/null)
	[ -n "$init_ns" ] || return 1
	for cand in "/data/adb/ksu/bin/busybox nsenter -t 1 -m" "/system/bin/nsenter -t 1 -m"; do
		# shellcheck disable=SC2086
		if $cand /system/bin/true >/dev/null 2>&1; then
			# shellcheck disable=SC2086
			got=$($cand readlink /proc/self/ns/mnt 2>/dev/null)
			if [ -n "$got" ] && [ "$got" = "$init_ns" ]; then
				NS_PREFIX=$cand
				NS_MODE=ns
				return 0
			fi
		fi
	done
	self_ns=$(readlink /proc/self/ns/mnt 2>/dev/null)
	if [ -n "$self_ns" ] && [ "$self_ns" = "$init_ns" ]; then
		NS_MODE=direct
		return 0
	fi
	return 1
}

ns_run() {
	if [ "$NS_MODE" = ns ]; then
		$NS_PREFIX "$@"
	else
		"$@"
	fi
}

prop_ok() {
	val=$("$GETPROP" persist.sys.vold_app_data_isolation_enabled 2>/dev/null)
	if [ "$val" = true ]; then
		ISO=ok
		return 0
	fi
	if [ -n "$val" ]; then
		ISO=other
	else
		ISO=absent
	fi
	return 1
}

do_resolve() {
	diag=0
	[ -f "$DIAG" ] && diag=1
	SCV_STATE_DIR="$STATE_DIR" SCV_CONFIG="$CONFIG" SCV_CONTROL="$CONTROL" \
		SCV_SVREG="$SVREG" SCV_PM="$PM" SCV_GETPROP="$GETPROP" \
		SCV_NS_MODE="$NS_MODE" SCV_NS="$NS_PREFIX" SCV_DIAG="$diag" \
		sh "$RESOLVER" >/dev/null 2>&1
	RES_STATUS=$(sed -n 's/^status=//p' "$RESOLVE" 2>/dev/null | head -n1)
	RES_REASON=$(sed -n 's/^reason=//p' "$RESOLVE" 2>/dev/null | head -n1)
	RES_FP=$(sed -n 's/^fp=//p' "$RESOLVE" 2>/dev/null | head -n1)
	RES_USERS=$(sed -n 's/^users=//p' "$RESOLVE" 2>/dev/null | head -n1)
	fs=$(sed -n 's/^fs_allow=//p' "$RESOLVE" 2>/dev/null | head -n1)
	[ -n "$fs" ] && FS_ALLOW=$fs
	[ -n "$RES_STATUS" ] || { RES_STATUS=config_required; RES_REASON=RESOLVER_FAILED; }
	[ -n "$RES_REASON" ] || RES_REASON=unknown
}

read_status() {
	out=$(ns_run "$SVCTL" status 2>/dev/null)
	[ -n "$out" ] || return 1
	C_GEN=$(printf '%s\n' "$out" | sed -n 's/^generation=\([0-9][0-9]*\).*/\1/p' | head -n1)
	C_COUNT=$(printf '%s\n' "$out" | sed -n 's/.*count=\([0-9][0-9]*\).*/\1/p' | head -n1)
	[ -n "$C_GEN" ] || return 1
	[ -n "$C_COUNT" ] || C_COUNT=unknown
	return 0
}

do_apply() {
	out=$(ns_run "$SVREG" --fs-allow "$FS_ALLOW" apply "$1" "$SNAPSHOT" 2>&1)
	RC=$?
	NEW_GEN=$(printf '%s\n' "$out" | sed -n 's/^PUBLISHED generation=\([0-9][0-9]*\).*/\1/p' | tail -n1)
	return 0
}

clear_own() {
	if [ "$PUBLISHED" -eq 0 ] && [ -z "$SAVED_GEN" ]; then
		set_state WAITING "released:$1"
		return 0
	fi
	if ! read_status; then
		set_state CLEAR_FAILED "control-unreadable"
		drop_lock
		exit 5
	fi
	if [ "$C_GEN" != "$SAVED_GEN" ]; then
		set_state CONFLICT "foreign-generation:$C_GEN"
		drop_lock
		exit 4
	fi
	ns_run "$SVCTL" clear "$SAVED_GEN" >/dev/null 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		set_state CLEAR_FAILED "clear-exit:$rc"
		drop_lock
		exit 5
	fi
	CLEARED_FROM=$SAVED_GEN
	PUBLISHED=0
	SAVED_GEN=
	SAVED_FP=
	# The only acceptable post-clear generation is our own + 1; a different
	# value means another writer or an unexpected interface and is never
	# adopted as the next expected generation.
	EXPECT_GEN=$((CLEARED_FROM + 1))
	if ! read_status; then
		set_state CLEAR_FAILED "readback-unavailable"
		drop_lock
		exit 5
	fi
	if [ "$C_COUNT" != 0 ]; then
		set_state CONFLICT "foreign-policy-after-clear"
		drop_lock
		exit 4
	fi
	if [ "$C_GEN" != "$EXPECT_GEN" ]; then
		set_state CLEAR_FAILED "unexpected-generation:$C_GEN"
		drop_lock
		exit 5
	fi
	set_state WAITING "released:$1"
	return 0
}

on_signal() {
	trap - INT TERM HUP
	log_line "signal-stop"
	if [ "$PUBLISHED" -eq 1 ]; then
		clear_own signal
	fi
	set_state STOPPED signal
	drop_lock
	exit 0
}

fix_legacy_perms() {
	[ -d "$LEGACY_STATE" ] || return 0
	chmod 700 "$LEGACY_STATE" 2>/dev/null
	chmod -R go-rwx "$LEGACY_STATE" 2>/dev/null
	log_line "legacy-state-permissions-tightened"
	LEGACY_FIXED=1
}

# ------------------------------------------------------------------ main ----
take_lock || exit 0
trap on_signal INT TERM HUP
mkdir -p "$STATE_DIR" 2>/dev/null || exit 1
chmod 700 "$STATE_DIR" 2>/dev/null
# umask only protects new files; an inherited 0666 log/status must be fixed.
for f in "$STATUS" "$LOG" "$RESOLVE" "$RESOLVE.detail" "$SNAPSHOT" "$DIAG" \
	"$STATE_DIR/prop.state" "$STATE_DIR/status.prevboot" "$CONFIG"; do
	[ -e "$f" ] && chmod 600 "$f" 2>/dev/null
done
fix_legacy_perms

if [ -d "$LEGACY_MODULE" ] && [ ! -e "$LEGACY_MODULE/disable" ] && \
	[ ! -e "$LEGACY_MODULE/remove" ]; then
	set_state LEGACY_MODULE legacy-module-active
	drop_lock
	exit 0
fi

if [ -f "$STATUS" ] && ! grep -q "^boot_id=$BOOT_ID$" "$STATUS" 2>/dev/null; then
	mv -f "$STATUS" "$STATE_DIR/status.prevboot" 2>/dev/null
	chmod 600 "$STATE_DIR/status.prevboot" 2>/dev/null
fi
rm -f "$STOP" 2>/dev/null

for f in "$SVREG" "$SVCTL" "$RESOLVER"; do
	[ -e "$f" ] || { set_state FAILED "missing:$f"; drop_lock; exit 1; }
done
[ -f "$CONFIG" ] || { set_state CONFIG_REQUIRED config-missing; drop_lock; exit 1; }

if ! detect_ns; then
	ISO=unknown
	set_state BLOCKED ns-unverified
	drop_lock
	exit 2
fi

tries=0
while [ ! -e "$CONTROL" ]; do
	tries=$((tries + 1))
	if [ "$tries" -ge "$CONTROL_TRIES" ]; then
		set_state UNSUPPORTED control-absent
		drop_lock
		exit 2
	fi
	sleep "$SLOW_INTERVAL"
done

while :; do
	CYCLES=$((CYCLES + 1))
	if [ "$MAX_CYCLES" -gt 0 ] && [ "$CYCLES" -gt "$MAX_CYCLES" ]; then
		drop_lock
		exit 0
	fi

	if [ -e "$MODDIR/remove" ] || [ -e "$MODDIR/disable" ] || [ -e "$STOP" ]; then
		if [ "$PUBLISHED" -eq 1 ]; then
			clear_own module-disabled
		fi
		set_state STOPPED module-disabled
		drop_lock
		exit 0
	fi

	if ! prop_ok; then
		if [ "$PUBLISHED" -eq 1 ]; then
			clear_own isolation-off
		fi
		set_state BLOCKED_ISOLATION isolate-$ISO
		sleep "$WAIT_INTERVAL"
		continue
	fi

	do_resolve
	case "$RES_STATUS" in
	ok) ;;
	*)
		if [ "$PUBLISHED" -eq 1 ]; then
			clear_own "resolve-$RES_STATUS"
		fi
		case "$RES_STATUS" in
		waiting)
			set_state WAITING "$RES_REASON"
			;;
		*)
			set_state CONFIG_REQUIRED "$RES_REASON"
			;;
		esac
		if [ "$RES_STATUS" = waiting ] && [ "$WAITED" -lt "$MAX_WAIT" ]; then
			sleep "$WAIT_INTERVAL"
			WAITED=$((WAITED + WAIT_INTERVAL))
		else
			sleep "$SLOW_INTERVAL"
		fi
		continue
		;;
	esac

	if [ "$PUBLISHED" -eq 0 ]; then
		if ! read_status; then
			set_state FAILED control-unreadable
			sleep "$SLOW_INTERVAL"
			continue
		fi
		if [ "$C_COUNT" != 0 ]; then
			set_state CONFLICT "registry-not-empty:$C_COUNT"
			drop_lock
			exit 4
		fi
		if [ -z "$EXPECT_GEN" ]; then
			EXPECT_GEN=$C_GEN
		elif [ "$C_GEN" != "$EXPECT_GEN" ]; then
			set_state CONFLICT "generation-moved:$C_GEN"
			drop_lock
			exit 4
		fi
		do_apply "$EXPECT_GEN"
		case "$RC" in
		0)
			PUBLISHED=1
			SAVED_GEN=$NEW_GEN
			EXPECT_GEN=$SAVED_GEN
			SAVED_FP=$RES_FP
			FAILS=0
			set_state PUBLISHED "own-generation:$SAVED_GEN"
			;;
		3)
			set_state CONFLICT apply-generation-moved
			drop_lock
			exit 3
			;;
		*)
			FAILS=$((FAILS + 1))
			set_state FAILED "apply-exit:$RC"
			if [ "$FAILS" -ge "$MAX_APPLY_FAIL" ]; then
				drop_lock
				exit 1
			fi
			sleep "$SLOW_INTERVAL"
			continue
			;;
		esac
	else
		if ! read_status; then
			set_state CLEAR_FAILED control-unreadable
			sleep "$SLOW_INTERVAL"
			continue
		fi
		if [ "$C_GEN" != "$SAVED_GEN" ]; then
			set_state CONFLICT "foreign-generation:$C_GEN"
			drop_lock
			exit 4
		fi
		if [ "$RES_FP" != "$SAVED_FP" ]; then
			do_apply "$EXPECT_GEN"
			case "$RC" in
			0)
				SAVED_GEN=$NEW_GEN
				EXPECT_GEN=$SAVED_GEN
				SAVED_FP=$RES_FP
				FAILS=0
				set_state PUBLISHED "republished:$SAVED_GEN"
				;;
			3)
				set_state CONFLICT republish-generation-moved
				drop_lock
				exit 3
				;;
			*)
				FAILS=$((FAILS + 1))
				set_state FAILED "republish-exit:$RC"
				if [ "$FAILS" -ge "$MAX_APPLY_FAIL" ]; then
					drop_lock
					exit 1
				fi
				;;
			esac
		else
			set_state UNCHANGED "own-generation:$SAVED_GEN"
		fi
	fi

	sleep "$STEADY_INTERVAL"
done
