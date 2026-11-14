#!/bin/bash
# UID upper-bound predicate: width-independent by construction.
#
# Android's mksh has 32-bit signed integers, so the previous
# [ "$id" -ge 4294967295 ] was TRUE on device for every value (the constant
# wraps to -1) and the resolver refused valid UIDs with UID_INVALID:0.
# u32_bound_ok is pattern-only; this test proves the accepted/rejected table
# and, when mksh/busybox are available, runs the same predicate under them.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
RESOLVER=$REPO/module/bin/scv-resolve.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
FAILED=

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED | $1"; printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

sed -n '/^# BEGIN sv-u32$/,/^# END sv-u32$/p' "$RESOLVER" >"$WORK/u32.sh"
[ -s "$WORK/u32.sh" ] || { echo "cannot extract u32_bound_ok" >&2; exit 1; }
grep -q 'u32_bound_ok()' "$WORK/u32.sh" || { echo "extracted block lacks the predicate" >&2; exit 1; }

cat >"$WORK/probe.sh" <<'EOS'
BLOCK=$1
shift
. "$BLOCK"
for v in "$@"; do
	if u32_bound_ok "$v"; then
		printf 'accept [%s]\n' "$v"
	else
		printf 'reject [%s]\n' "$v"
	fi
done
EOS

VALUES='0 5 999 1000 999999999 1000000000 4000000000 4294967294 4294967295 4294967296 5000000000 9999999999 18446744073709551616'
EXPECTED='accept [0]
accept [5]
accept [999]
accept [1000]
accept [999999999]
accept [1000000000]
accept [4000000000]
accept [4294967294]
reject [4294967295]
reject [4294967296]
reject [5000000000]
reject [9999999999]
reject [18446744073709551616]'

check_shell() { # label shell [args...]
	LABEL=$1
	shift
	# shellcheck disable=SC2086
	OUT=$("$@" "$WORK/probe.sh" "$WORK/u32.sh" $VALUES 2>&1)
	RC=$?
	eq "$LABEL: probe exits 0" "$RC" 0
	eq "$LABEL: predicate table" "$OUT" "$EXPECTED"
	# an empty token must be rejected, not treated as zero or as an error
	EMPTY=$("$@" "$WORK/probe.sh" "$WORK/u32.sh" "" 2>&1)
	eq "$LABEL: empty rejected" "$EMPTY" 'reject []'
}

check_shell dash dash

for extra in mksh busybox; do
	if ! command -v "$extra" >/dev/null 2>&1; then
		printf 'skip %s (not installed)\n' "$extra"
		continue
	fi
	if [ "$extra" = busybox ]; then
		# busybox is a multi-call binary: "busybox sh <script>" needs two argv
		# entries, not a single "busybox sh" path.
		check_shell "busybox sh" busybox sh
	else
		check_shell "$extra" "$extra"
	fi
done

# Regression guard: no arithmetic bound may reappear against a wide literal.
if grep -nE '\-(ge|gt|le|lt)[[:space:]]+[0-9]{10,}' "$REPO"/module/bin/*.sh \
	| grep -vE ':[0-9]+:[[:space:]]*#'; then
	bad "no arithmetic comparison against a wide literal"
else
	ok "no arithmetic comparison against a wide literal"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || printf 'failed:%s\n' "$FAILED"
[ "$FAIL" -eq 0 ]
