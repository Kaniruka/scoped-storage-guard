#!/system/bin/sh
# Explicit operator controls. status and diagnostics are read-only; stop and
# disable release this module's own state only.
set -u
umask 077

SELF_DIR=$(dirname "$0")
MODDIR=$(dirname "$SELF_DIR")
STATE_DIR=${SCV_STATE_DIR:-/data/adb/scoped-storage-guard}
CONTROL=${SCV_CONTROL:-/sys/kernel/security/scoped_visibility/control}
SVCTL=${SCV_SVCTL:-$SELF_DIR/svctl}
GETPROP=${SCV_GETPROP:-getprop}
STATUS=$STATE_DIR/status
RESOLVE=$STATE_DIR/resolve
DETAIL=$STATE_DIR/resolve.detail
DIAG=$STATE_DIR/diagnostics
LOCKOWNER=$STATE_DIR/lock/owner
CMD=${1:-status}

live_pid() {
	[ -f "$LOCKOWNER" ] || return 1
	lpid=$(sed -n 's/^pid=//p' "$LOCKOWNER" 2>/dev/null | head -n1)
	lboot=$(sed -n 's/^boot_id=//p' "$LOCKOWNER" 2>/dev/null | head -n1)
	[ -n "$lpid" ] || return 1
	now_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
	[ "$lboot" = "$now_boot" ] || return 1
	[ -r "/proc/$lpid/cmdline" ] || return 1
	tr '\0' ' ' <"/proc/$lpid/cmdline" 2>/dev/null | grep -q 'autostart.sh' || return 1
	printf '%s' "$lpid"
}

restore_prop() {
	[ -x "$MODDIR/bin/scv-prop.sh" ] || return 0
	SCV_STATE_DIR="$STATE_DIR" "$MODDIR/bin/scv-prop.sh" restore
}

field() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | head -n1; }

do_stop() {
	pid=$(live_pid)
	if [ -n "$pid" ]; then
		: >"$STATE_DIR/stop" 2>/dev/null
		chmod 600 "$STATE_DIR/stop" 2>/dev/null
		kill -TERM "$pid" 2>/dev/null
		n=0
		while [ -d "/proc/$pid" ] && [ "$n" -lt 10 ]; do
			sleep 1
			n=$((n + 1))
		done
		restore_prop
		echo "supervisor pid $pid signalled (it releases its own snapshot on TERM)"
		return 0
	fi

	if [ ! -f "$STATUS" ]; then
		echo "no state file; nothing to release"
		return 0
	fi
	st_id=$(field module_id)
	st_boot=$(field boot_id)
	st_pub=$(field published)
	st_gen=$(field generation)
	if [ "$st_id" != scoped_storage_guard ]; then
		echo "refused: state is not from this module; nothing released"
		return 4
	fi
	if [ "$st_pub" != 1 ]; then
		echo "no published generation recorded for this boot; nothing to release"
		return 0
	fi
	cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
	if [ "$st_boot" != "$cur_boot" ]; then
		echo "refused: recorded state is from boot $st_boot, not the current boot"
		return 4
	fi
	[ -e "$CONTROL" ] || { echo "control node absent; nothing to release"; return 0; }
	cur=$("$SVCTL" status 2>/dev/null | sed -n 's/^generation=\([0-9][0-9]*\).*/\1/p' | head -n1)
	if [ "$cur" != "$st_gen" ]; then
		echo "refused: current generation $cur is not ours ($st_gen); external policy untouched"
		return 4
	fi
	"$SVCTL" clear "$st_gen" >/dev/null 2>&1 || { echo "clear failed for own generation $st_gen"; return 5; }
	restore_prop
	echo "released own generation $st_gen"
	return 0
}

need_root() {
	[ "$(id -u 2>/dev/null)" = 0 ] && return 0
	echo "diagnostics is root-only" >&2
	return 1
}

show_diagnostics() {
	if [ -f "$DETAIL" ]; then
		cat "$DETAIL"
	else
		echo "detailed output is off (no per-path data recorded)"
		echo "run: $MODDIR/bin/scvctl.sh diagnostics on   # then wait one supervisor cycle"
	fi
	echo "--- concise state ---"
	sed -n 's/^state=/state=/p;s/^reason=/reason=/p;s/^generation=/generation=/p;s/^count=/count=/p' "$STATUS" 2>/dev/null
}

case "$CMD" in
status)
	grep -E '^(state|reason|generation|count|users|isolate|namespace|boot_id)=' "$STATUS" 2>/dev/null ||
		echo "no state file (module never started this boot)"
	echo "isolation_key=$($GETPROP persist.sys.vold_app_data_isolation_enabled 2>/dev/null)"
	if [ -e "$CONTROL" ]; then
		printf 'control: '
		"$SVCTL" status 2>&1 | head -n1
	else
		echo "control: absent"
	fi
	;;
diagnostics)
	need_root || exit 1
	case "${2:-show}" in
	on)
		: >"$DIAG" 2>/dev/null
		chmod 600 "$DIAG" 2>/dev/null
		echo "detailed resolve output enabled for this boot (root-only files)"
		;;
	off)
		rm -f "$DIAG" "$DETAIL" 2>/dev/null
		echo "detailed resolve output disabled"
		;;
	show)
		show_diagnostics
		;;
	*)
		echo "usage: $0 diagnostics on|off|show" >&2
		exit 2
		;;
	esac
	;;
stop)
	do_stop
	;;
disable)
	: >"$MODDIR/disable" 2>/dev/null
	echo "wrote disable marker; releasing own state"
	do_stop
	echo "reboot restores the cached system_server isolation gate"
	;;
*)
	echo "usage: $0 status|diagnostics on|off|show|stop|disable" >&2
	exit 2
	;;
esac
