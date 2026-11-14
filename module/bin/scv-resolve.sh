#!/system/bin/sh
# scv-resolve.sh - build ONE complete, verified snapshot for the covered users.
#
# Read-only with respect to the kernel: it probes directories, the running user
# list and the provider package, then writes STATE_DIR/{snapshot,resolve,
# resolve.detail}. It never publishes and never adopts a generation.
#
# Completeness is tracked per (user, Android/data|obb): the raw lower object and
# at least one real FUSE object are required for each pair.
set -u
umask 077

SELF_DIR=$(dirname "$0")
MODDIR=$(dirname "$SELF_DIR")

STATE_DIR=${SCV_STATE_DIR:-/data/adb/scoped-storage-guard}
CONFIG=${SCV_CONFIG:-$MODDIR/config/scv.conf}
SVREG=${SCV_SVREG:-$SELF_DIR/svreg}
PM=${SCV_PM:-pm}
NS_MODE=${SCV_NS_MODE:-direct}
NS_PREFIX=${SCV_NS:-}
DIAG=${SCV_DIAG:-0}
FS_ALLOW=fuse,f2fs,ext4

case "$NS_MODE" in
ns|direct) ;;
*) NS_MODE=direct ;;
esac

mkdir -p "$STATE_DIR" 2>/dev/null || exit 1
chmod 700 "$STATE_DIR" 2>/dev/null

LIST=$STATE_DIR/.cand.$$
LIST2=$STATE_DIR/.cand2.$$
PROBE=$STATE_DIR/.probe.$$
PROBE2=$STATE_DIR/.probe2.$$
ACCEPT=$STATE_DIR/.accept.$$
ACCEPT2=$STATE_DIR/.accept2.$$
RES_TMP=$STATE_DIR/.resolve.$$
SNAP_TMP=$STATE_DIR/.snapshot.$$
DETAIL_TMP=$STATE_DIR/.detail.$$

cleanup() {
	rm -f "$LIST" "$LIST2" "$PROBE" "$PROBE2" "$ACCEPT" "$ACCEPT2" \
		"$ACCEPT2.sorted" "$RES_TMP" "$SNAP_TMP" "$DETAIL_TMP" 2>/dev/null
}
trap cleanup EXIT HUP INT TERM

ns_run() {
	if [ "$NS_MODE" = ns ]; then
		$NS_PREFIX "$@"
	else
		"$@"
	fi
}

emit() { # status reason [extra detail lines...]
	st=$1
	rs=$2
	shift 2
	{
		printf 'status=%s\n' "$st"
		printf 'reason=%s\n' "$rs"
		printf 'entries=%s\n' "${ENTRIES:-0}"
		printf 'users=%s\n' "${USER_COUNT:-0}"
		printf 'fuse=%s\n' "${FUSE_COUNT:-0}"
		printf 'lower=%s\n' "${LOWER_COUNT:-0}"
		printf 'provider_uids=%s\n' "${PROVIDER_UID_COUNT:-0}"
		printf 'fs_allow=%s\n' "$FS_ALLOW"
		printf 'fp=%s\n' "${FP:--}"
		printf 'config_sha=%s\n' "${CONFIG_SHA:--}"
		printf 'updated=%s\n' "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null)"
		while [ "$#" -gt 0 ]; do
			printf '%s\n' "$1"
			shift
		done
	} >"$RES_TMP" 2>/dev/null || return 1
	chmod 600 "$RES_TMP" 2>/dev/null
	mv -f "$RES_TMP" "$STATE_DIR/resolve" 2>/dev/null
	if [ "$st" != ok ]; then
		rm -f "$STATE_DIR/snapshot" 2>/dev/null
	fi
	exit 0
}

fs_allowed() {
	case ",$FS_ALLOW," in
	*",$1,"*) return 0 ;;
	esac
	return 1
}

lookup() { # path probefile - exact first field only
	awk -F'|' -v p="$1" '$1 == p { print; exit }' "$2" 2>/dev/null
}

accept_obj() { # path fs dev ino
	printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$ACCEPT"
}

list_has() { # list item
	case " $1 " in
	*" $2 "*) return 0 ;;
	esac
	return 1
}

expand_user() { # template user
	printf '%s' "$1" | sed "s/{user}/$2/g"
}

probe_file() { # list out
	: >"$2"
	total=$(grep -c . "$1" 2>/dev/null)
	[ -n "$total" ] || total=0
	off=0
	while [ "$off" -lt "$total" ]; do
		chunk=$(sed -n "$((off + 1)),$((off + 24))p" "$1")
		off=$((off + 24))
		# shellcheck disable=SC2086
		out=$(ns_run "$SVREG" --fs-allow "$FS_ALLOW" inspect $chunk 2>/dev/null)
		printf '%s\n' "$out" | awk '
			/^OBJECT / {
				p = ""; f = ""; d = ""; i = "";
				for (n = 1; n <= NF; n++) {
					if ($n ~ /^path=/) p = substr($n, 6);
					else if ($n ~ /^fs=/) f = substr($n, 4);
					else if ($n ~ /^dev=/) d = substr($n, 5);
					else if ($n ~ /^ino=/) i = substr($n, 5);
				}
				if (p != "") print p "|" f "|" d "|" i;
			}' >>"$2"
	done
}

# ---------------------------------------------------------------- config ----
USERS_CFG=
USERS_AUTO=1
PROVIDER_PKG=com.android.providers.media.module
PROVIDER_UID=auto
ALLOW_UIDS=
FUSE_ROOT=
FUSE_DATA=
FUSE_OBB=
CONFIG_ERR=

[ -f "$CONFIG" ] || emit config_required CONFIG_MISSING
CONFIG_SHA=$(sha256sum "$CONFIG" 2>/dev/null | cut -d' ' -f1)

while IFS= read -r raw || [ -n "$raw" ]; do
	line=$(printf '%s' "$raw" | tr -d '\r')
	case "$line" in
	''|'#'*) continue ;;
	esac
	case "$line" in
	*=*) ;;
	*)
		CONFIG_ERR=no-separator
		continue
		;;
	esac
	key=${line%%=*}
	val=${line#*=}
	case "$key" in
	user)
		if [ "$val" = auto ]; then
			USERS_AUTO=1
		else
			case "$val" in
			''|*[!0-9]*) CONFIG_ERR=bad-user ;;
			*)
				USERS_AUTO=0
				USERS_CFG="$USERS_CFG $val"
				;;
			esac
		fi
		;;
	provider_package)
		PROVIDER_PKG=$val
		;;
	provider_uid)
		case "$val" in
		auto|off) PROVIDER_UID=$val ;;
		''|*[!0-9]*) CONFIG_ERR=bad-provider-uid ;;
		*) PROVIDER_UID=$val ;;
		esac
		;;
	allow_uid)
		case "$val" in
		''|*[!0-9]*) CONFIG_ERR=bad-allow-uid ;;
		*) ALLOW_UIDS="$ALLOW_UIDS $val" ;;
		esac
		;;
	fuse_root|fuse_data|fuse_obb)
		case "$val" in
		''|*' '*) CONFIG_ERR=bad-fuse-template ;;
		*'{user}'*) ;;
		*) CONFIG_ERR=explicit-needs-user ;;
		esac
		case "$key" in
		fuse_root) FUSE_ROOT=$val ;;
		fuse_data) FUSE_DATA=$val ;;
		fuse_obb) FUSE_OBB=$val ;;
		esac
		;;
	fs_allow)
		case "$val" in
		''|*,|*,,*) CONFIG_ERR=bad-fs-allow ;;
		*) FS_ALLOW=$val ;;
		esac
		;;
	*)
		CONFIG_ERR="unknown-key:$key"
		;;
	esac
done <"$CONFIG"

[ -n "$CONFIG_ERR" ] && emit config_required "CONFIG_INVALID:$CONFIG_ERR"

# Explicit per-kind FUSE mappings are authoritative for the pair they name.
explicit_fuse_path() { # user kind -> prints path
	case "$1" in
	'') return 1 ;;
	esac
	case "$2" in
	data) t=$FUSE_DATA ;;
	obb) t=$FUSE_OBB ;;
	*) return 1 ;;
	esac
	if [ -n "$t" ]; then
		expand_user "$t" "$1"
		return 0
	fi
	if [ -n "$FUSE_ROOT" ]; then
		root=$(expand_user "$FUSE_ROOT" "$1")
		printf '%s/Android/%s' "$root" "$2"
		return 0
	fi
	return 1
}

# ----------------------------------------------------------------- users ----
pm_users=$(ns_run "$PM" list users 2>/dev/null)
[ -n "$pm_users" ] || emit config_required PM_UNAVAILABLE

all_ids=$(printf '%s\n' "$pm_users" | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p' | sort -n -u)
running_ids=$(printf '%s\n' "$pm_users" | awk '/running/ { if (match($0, /UserInfo\{[0-9]+/)) print substr($0, RSTART + 9, RLENGTH - 9) }' | sort -n -u)

if [ "$USERS_AUTO" = 1 ]; then
	USERS=$running_ids
	[ -n "$USERS" ] || emit waiting NO_RUNNING_USERS
else
	USERS=
	for id in $USERS_CFG; do
		if printf '%s\n' "$running_ids" | grep -qx "$id"; then
			USERS="$USERS $id"
		elif printf '%s\n' "$all_ids" | grep -qx "$id"; then
			emit waiting "USER_NOT_RUNNING:$id"
		else
			emit config_required "USER_UNKNOWN:$id"
		fi
	done
	USERS=$(printf '%s\n' $USERS | grep -v '^$' | sort -n -u)
fi
USER_COUNT=$(printf '%s\n' "$USERS" | grep -c .)

# -------------------------------------------------------------- provider ----
# A central provider may serve several users. Query every verified running
# user, not only the coverage set: rc!=0 is a transient failure, rc0 with no
# matching package means "not installed for this user" and is skipped, and a
# non-empty non-matching response is treated as an invalid response. At least
# one exact match is required; nothing is derived arithmetically.
PROVIDER_UIDS=
PROVIDER_VERIFIED=
if [ -n "$PROVIDER_PKG" ] && [ "$PROVIDER_UID" != off ]; then
	for u in $running_ids; do
		out=$(ns_run "$PM" list packages -U --user "$u" "$PROVIDER_PKG" 2>/dev/null)
		rc=$?
		if [ "$rc" -ne 0 ]; then
			emit waiting "PROVIDER_QUERY_FAILED:$u"
		fi
		if [ -z "$out" ]; then
			# rc0 and no package: the provider is not installed for this user.
			continue
		fi
		uid=$(printf '%s\n' "$out" | awk -v pkg="$PROVIDER_PKG" '
			{ if ($1 == "package:" pkg && $2 ~ /^uid:[0-9]+$/) { sub(/^uid:/, "", $2); print $2 } }' | head -n1)
		[ -n "$uid" ] || emit config_required "PROVIDER_RESPONSE_INVALID:$u"
		[ "$uid" = 0 ] && emit config_required "PROVIDER_UID_ZERO:$u"
		PROVIDER_UIDS="$PROVIDER_UIDS $uid"
	done
	PROVIDER_VERIFIED=$(printf '%s\n' $PROVIDER_UIDS | grep -v '^$' | sort -n -u | tr '\n' ' ')
	if [ -z "$PROVIDER_VERIFIED" ]; then
		emit config_required NO_PROVIDER_UID
	fi
	if [ "$PROVIDER_UID" = auto ]; then
		PROVIDER_UIDS=$PROVIDER_VERIFIED
	else
		case " $PROVIDER_VERIFIED " in
		*" $PROVIDER_UID "*) PROVIDER_UIDS=$PROVIDER_UID ;;
		*) emit config_required "PROVIDER_UID_MISMATCH:$PROVIDER_UID" ;;
		esac
	fi
fi
PROVIDER_UID_COUNT=$(printf '%s\n' $PROVIDER_UIDS | grep -c .)

# ---------------------------------------------------------------- ranges ----
# Sorted union of the explicit base identities and every UID PackageManager
# reported. Provider UIDs are process identities: one process may serve several
# users, so every verified UID is allowed on every object and DAC/SELinux still
# decides actual access.
ALLOW_LIST=$(printf '%s\n' $ALLOW_UIDS | grep -v '^$')
[ -n "$ALLOW_LIST" ] || emit config_required NO_BASE_UIDS
UID_LIST=$(printf '%s\n' $ALLOW_UIDS $PROVIDER_UIDS | grep -v '^$' | sort -n -u)
RANGES=
for id in $UID_LIST; do
	case "$id" in
	0) ;;
	0*) emit config_required "UID_NOT_CANONICAL:$id" ;;
	esac
	case "$id" in
	*[!0-9]*) emit config_required "UID_INVALID:$id" ;;
	esac
	if [ "$id" -ge 4294967295 ]; then
		emit config_required "UID_INVALID:$id"
	fi
	RANGES="$RANGES$id-$id,"
done
RANGES=${RANGES%,}

# ---------------------------------------------------------------- probes ----
: >"$LIST"
: >"$ACCEPT"
for u in $USERS; do
	for kind in data obb; do
		p=$(explicit_fuse_path "$u" "$kind" 2>/dev/null) && {
			printf '%s\n' "$p" >>"$LIST"
			continue
		}
		printf '%s\n' "/mnt/user/$u/emulated/$u/Android/$kind" >>"$LIST"
	done
	printf '%s\n' "/data/media/$u/Android/data" "/data/media/$u/Android/obb" >>"$LIST"
done
probe_file "$LIST" "$PROBE"

MISSING_LOWER_USERS=
GOT=
EXPLICIT_PAIRS=
EXPLICIT_MISSING=
EXPLICIT_BAD=
OVER_SEEN=
LOWER_COUNT=0
FUSE_COUNT=0

for u in $USERS; do
	ok_lower=1
	for kind in data obb; do
		p="/data/media/$u/Android/$kind"
		rec=$(lookup "$p" "$PROBE")
		if [ -z "$rec" ]; then
			ok_lower=0
			continue
		fi
		fs=${rec#*|}
		fs=${fs%%|*}
		dev=$(printf '%s' "$rec" | cut -d'|' -f3)
		ino=$(printf '%s' "$rec" | cut -d'|' -f4)
		if ! fs_allowed "$fs"; then
			emit config_required "FS_NOT_ALLOWED:$u"
		fi
		accept_obj "$p" "$fs" "$dev" "$ino"
		LOWER_COUNT=$((LOWER_COUNT + 1))
	done
	[ "$ok_lower" = 1 ] || MISSING_LOWER_USERS="$MISSING_LOWER_USERS $u"

	for kind in data obb; do
		pair="$u:$kind"
		rec=
		ep=$(explicit_fuse_path "$u" "$kind" 2>/dev/null) && {
			EXPLICIT_PAIRS="$EXPLICIT_PAIRS $pair"
			rec=$(lookup "$ep" "$PROBE")
			if [ -z "$rec" ]; then
				EXPLICIT_MISSING="$EXPLICIT_MISSING $pair"
			else
				fs=${rec#*|}
				fs=${fs%%|*}
				if [ "$fs" = fuse ]; then
					dev=$(printf '%s' "$rec" | cut -d'|' -f3)
					ino=$(printf '%s' "$rec" | cut -d'|' -f4)
					accept_obj "$ep" "$fs" "$dev" "$ino"
					FUSE_COUNT=$((FUSE_COUNT + 1))
					GOT="$GOT $pair"
				else
					EXPLICIT_BAD="$EXPLICIT_BAD $pair"
				fi
			fi
			continue
		}
		p="/mnt/user/$u/emulated/$u/Android/$kind"
		rec=$(lookup "$p" "$PROBE")
		[ -z "$rec" ] && continue
		fs=${rec#*|}
		fs=${fs%%|*}
		if [ "$fs" = fuse ]; then
			dev=$(printf '%s' "$rec" | cut -d'|' -f3)
			ino=$(printf '%s' "$rec" | cut -d'|' -f4)
			accept_obj "$p" "$fs" "$dev" "$ino"
			FUSE_COUNT=$((FUSE_COUNT + 1))
			GOT="$GOT $pair"
		else
			OVER_SEEN="$OVER_SEEN $pair"
		fi
	done
done

# Per-kind cross-namespace fallback for pairs that are still incomplete.
: >"$LIST2"
NEED=
for u in $USERS; do
	for kind in data obb; do
		pair="$u:$kind"
		list_has "$GOT" "$pair" && continue
		list_has "$EXPLICIT_PAIRS" "$pair" && continue
		NEED="$NEED $pair"
		for v in $USERS; do
			[ "$v" = "$u" ] && continue
			printf '%s\n' "/mnt/user/$v/emulated/$u/Android/$kind" >>"$LIST2"
		done
	done
done
[ -s "$LIST2" ] && probe_file "$LIST2" "$PROBE2"

for pair in $NEED; do
	u=${pair%%:*}
	kind=${pair#*:}
	found=0
	for v in $USERS; do
		[ "$v" = "$u" ] && continue
		p="/mnt/user/$v/emulated/$u/Android/$kind"
		rec=$(lookup "$p" "$PROBE2")
		[ -z "$rec" ] && continue
		fs=${rec#*|}
		fs=${fs%%|*}
		if [ "$fs" = fuse ]; then
			found=1
			dev=$(printf '%s' "$rec" | cut -d'|' -f3)
			ino=$(printf '%s' "$rec" | cut -d'|' -f4)
			accept_obj "$p" "$fs" "$dev" "$ino"
			FUSE_COUNT=$((FUSE_COUNT + 1))
		else
			OVER_SEEN="$OVER_SEEN $pair"
		fi
	done
	[ "$found" = 1 ] && GOT="$GOT $pair"
done

# Classify only what is still missing after the fallback: an early non-FUSE
# candidate must not poison a pair that a cross-namespace FUSE view satisfied.
FINAL_BAD=
FINAL_MISSING=
for pair in $NEED; do
	list_has "$GOT" "$pair" && continue
	if list_has "$OVER_SEEN" "$pair"; then
		FINAL_BAD="$FINAL_BAD $pair"
	else
		FINAL_MISSING="$FINAL_MISSING $pair"
	fi
done

if [ "$DIAG" = 1 ]; then
	{
		printf 'users=%s\n' "$USER_COUNT"
		printf 'uid_list=%s\n' "$UID_LIST"
		printf 'fs_allow=%s\n' "$FS_ALLOW"
		printf 'got=%s\n' "$GOT"
		printf 'explicit=%s\n' "$EXPLICIT_PAIRS"
		printf 'over_seen=%s\n' "$OVER_SEEN"
		printf 'final_bad=%s\n' "$FINAL_BAD"
		printf 'final_missing=%s\n' "$FINAL_MISSING"
		while IFS= read -r p; do
			rec=$(lookup "$p" "$PROBE")
			if [ -z "$rec" ]; then
				printf 'MISSING %s\n' "$p"
			else
				printf 'OBJECT %s\n' "$rec"
			fi
		done <"$LIST"
		[ -s "$LIST2" ] && while IFS= read -r p; do
			rec=$(lookup "$p" "$PROBE2")
			if [ -z "$rec" ]; then
				printf 'MISSING %s\n' "$p"
			else
				printf 'OBJECT %s\n' "$rec"
			fi
		done <"$LIST2"
	} >"$DETAIL_TMP" 2>/dev/null
	chmod 600 "$DETAIL_TMP" 2>/dev/null
	mv -f "$DETAIL_TMP" "$STATE_DIR/resolve.detail" 2>/dev/null
fi

[ -n "$MISSING_LOWER_USERS" ] && emit waiting STORAGE_PENDING
[ -n "$EXPLICIT_BAD" ] && emit config_required "NO_FUSE_VIEW:${EXPLICIT_BAD# }"
[ -n "$EXPLICIT_MISSING" ] && emit waiting EXPLICIT_FUSE_PENDING
[ -n "$FINAL_BAD" ] && emit config_required "NO_FUSE_VIEW:${FINAL_BAD# }"
[ -n "$FINAL_MISSING" ] && emit waiting FUSE_PENDING

sort -u "$ACCEPT" | awk -F'|' '{ k = $3 "|" $4; if (seen[k]++) next; print }' >"$ACCEPT2"
sort -t'|' -k1,1 "$ACCEPT2" >"$ACCEPT2.sorted" && mv -f "$ACCEPT2.sorted" "$ACCEPT2"
ENTRIES=$(grep -c . "$ACCEPT2")
[ "$ENTRIES" -gt 32 ] && emit config_required OBJECT_LIMIT
[ "$ENTRIES" -lt 1 ] && emit waiting NO_OBJECTS

FP=$( { cat "$ACCEPT2"; printf '%s\n' "$RANGES" "$CONFIG_SHA"; } | sha256sum | cut -d' ' -f1 )

: >"$SNAP_TMP"
while IFS='|' read -r p fs dev ino; do
	printf '%s\t%s\n' "$p" "$RANGES" >>"$SNAP_TMP"
done <"$ACCEPT2"
chmod 600 "$SNAP_TMP" 2>/dev/null
mv -f "$SNAP_TMP" "$STATE_DIR/snapshot" 2>/dev/null || emit config_required SNAPSHOT_WRITE

emit ok -
