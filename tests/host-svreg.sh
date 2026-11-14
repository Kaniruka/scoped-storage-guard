#!/bin/bash
# Host-side checks for the built helpers: no kernel, no device.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SVREG=$REPO/out/svreg
SVCTL=$REPO/out/svctl
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

[ -x "$SVREG" ] || { echo "build first: make host" >&2; exit 1; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dir"

out=$("$SVREG" inspect /tmp/definitely-missing-scv 2>&1); rc=$?
eq "missing path rejected" "$rc" 4
case "$out" in *reason=missing*) ok "missing reason" ;; *) bad "missing reason" ;; esac

mkdir -p /dev/shm/scv-selftest-$$ 2>/dev/null &&
	out=$("$SVREG" inspect "/dev/shm/scv-selftest-$$" 2>&1) && rc=0 || rc=$?
eq "tmpfs rejected" "$rc" 4
case "$out" in *reason=tmpfs*) ok "tmpfs reason" ;; *) bad "tmpfs reason" ;; esac
rmdir "/dev/shm/scv-selftest-$$" 2>/dev/null

fs=$(stat -f -c %T "$WORK" 2>/dev/null)
case "$fs" in
ext2/ext3|ext4) allow=ext4 ;;
f2fs) allow=f2fs ;;
*) allow= ;;
esac
if [ -n "$allow" ]; then
	out=$("$SVREG" --fs-allow "$allow" inspect "$WORK/dir" 2>&1); rc=$?
	eq "host dir accepted with explicit fs allow" "$rc" 0
	case "$out" in *eligible=yes*) ok "eligibility printed" ;; *) bad "eligibility printed" ;; esac
fi

out=$("$SVREG" --fs-allow notafs inspect "$WORK/dir" 2>&1); rc=$?
eq "unknown fs name rejected" "$rc" 2

out=$("$SVCTL" status 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "absent control exits non-zero" || bad "absent control exits non-zero"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
