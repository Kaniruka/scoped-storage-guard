#!/bin/bash
# Dual-user resolver run under a chosen shell. Offline: stub pm/svreg, no device.
#
# On Android the resolver runs under mksh, which is not POSIX in every corner:
# a bare "|" inside a ${var#...} pattern is alternation there, so
# ${rec#*|} + ${fs%%|*} parsed an empty fs and the boot died with
# FS_NOT_ALLOWED:0. This test executes the real resolver end to end (dual
# fixture, 8 objects) under each available shell instead of only probing the
# UID predicate.
#
# Shell selection: positional arguments are shell argv specs
#   tests/resolver.sh dash 'busybox sh' mksh
# or set SCV_SHELLS to a semicolon-separated list. With no argument the default
# list is tried and missing shells are skipped.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
RESOLVER=${SCV_RESOLVER_UNDER_TEST:-$REPO/module/bin/scv-resolve.sh}
STUBS=$REPO/tests/stubs
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
FAILED=

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED | $1"; printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" ;; esac; }
field_of() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n1; }

[ -f "$RESOLVER" ] || { echo "missing $RESOLVER" >&2; exit 1; }

cat >"$WORK/users" <<'EOS'
UserInfo{0:Owner:c13} running
UserInfo{9:Owner:c13} running
EOS
cat >"$WORK/pkgs" <<'EOS'
0:com.android.providers.media.module:10055
9:com.android.providers.media.module:90055
EOS
printf '%s|%s|%s|%s\n' \
	/data/media/0/Android/data f2fs 254:55 100 \
	/data/media/0/Android/obb f2fs 254:55 101 \
	/data/media/9/Android/data f2fs 254:55 200 \
	/data/media/9/Android/obb f2fs 254:55 201 \
	/mnt/user/0/emulated/0/Android/data fuse 0:220 100 \
	/mnt/user/0/emulated/0/Android/obb fuse 0:220 101 \
	/mnt/user/9/emulated/9/Android/data f2fs 254:55 200 \
	/mnt/user/9/emulated/9/Android/obb f2fs 254:55 201 \
	/mnt/user/0/emulated/9/Android/data fuse 0:250 200 \
	/mnt/user/0/emulated/9/Android/obb fuse 0:250 201 >"$WORK/world"
cat >"$WORK/scv.conf" <<'EOS'
user=auto
provider_package=com.android.providers.media.module
provider_uid=auto
allow_uid=0
allow_uid=1000
fs_allow=fuse,f2fs,ext4
EOS
mkdir -p "$WORK/calls"

run_case() { # label shell argv...
	LABEL=$1
	shift
	STATE=$WORK/state.out
	rm -rf "$STATE"
	mkdir -p "$STATE"
	OUT=$(env SCV_STATE_DIR="$STATE" SCV_CONFIG="$WORK/scv.conf" \
		SCV_PM="$STUBS/pm" SCV_SVREG="$STUBS/svreg" SCV_GETPROP="$STUBS/getprop" \
		SCV_NS_MODE=direct STUB_WORLD="$WORK/world" STUB_USERS="$WORK/users" \
		STUB_PKGS="$WORK/pkgs" STUB_CALLS="$WORK/calls" \
		"$@" "$RESOLVER" 2>&1)
	RC=$?
	RES=$STATE/resolve
	eq "$LABEL: resolver exits 0" "$RC" 0
	eq "$LABEL: state" "$(field_of status "$RES")" ok
	eq "$LABEL: entries" "$(field_of entries "$RES")" 8
	eq "$LABEL: lower objects" "$(field_of lower "$RES")" 4
	eq "$LABEL: fuse objects" "$(field_of fuse "$RES")" 4
	eq "$LABEL: users" "$(field_of users "$RES")" 2
	eq "$LABEL: provider uids" "$(field_of provider_uids "$RES")" 2
	eq "$LABEL: snapshot lines" "$(grep -c . "$STATE/snapshot" 2>/dev/null)" 8
	has "$(cat "$STATE/snapshot" 2>/dev/null)" "/mnt/user/0/emulated/9/Android/data" \
		"$LABEL: cross-namespace FUSE view kept"
	has "$(cat "$STATE/snapshot" 2>/dev/null)" "10055-10055,90055-90055" \
		"$LABEL: provider union in ranges"
	case "$OUT$(cat "$RES")" in
	*"FS_NOT_ALLOWED"*) bad "$LABEL: no FS_NOT_ALLOWED" ;;
	*) ok "$LABEL: no FS_NOT_ALLOWED" ;;
	esac
	rm -rf "$STATE"
}

shells=
if [ "$#" -gt 0 ]; then
	shells=$*
elif [ -n "${SCV_SHELLS:-}" ]; then
	shells=$(printf '%s' "$SCV_SHELLS" | tr ';' ' ')
else
	shells="dash mksh busybox sh"
fi

ran=0
# Default and env lists are whitespace-separated specs; a multi-word spec such as
# "busybox sh" is passed as one positional argument instead.
set -- $shells
while [ "$#" -gt 0 ]; do
	spec=$1
	shift
	if [ "$spec" = busybox ] && [ "$#" -gt 0 ] && [ "$1" = sh ]; then
		spec="busybox sh"
		shift
	fi
	read -r bin rest <<EOF
$spec
EOF
	if ! command -v "$bin" >/dev/null 2>&1; then
		printf 'skip %s (not installed)\n' "$spec"
		continue
	fi
	# shellcheck disable=SC2086
	run_case "$spec" $spec
	ran=$((ran + 1))
done
[ "$ran" -gt 0 ] || bad "at least one shell ran the resolver"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || printf 'failed:%s\n' "$FAILED"
[ "$FAIL" -eq 0 ]
