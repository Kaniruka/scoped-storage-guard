#!/bin/bash
# Exercise the real C parser/UAPI boundary without a running patched kernel.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cc -Iinclude/uapi -Isrc -Wall -Wextra -Werror -o "$work/parser" tests/v2-parser.c src/sv_parse.c
"$work/parser" "$work"
cc -shared -fPIC -Iinclude/uapi -Wall -Wextra -Werror -o "$work/ioctl.so" tests/v2-ioctl.c
: >"$work/control"
printf 'root\t%s\t0\t0-0,1000-1000\npackage\t0\t10001\tcom.example.own\n' "$work" >"$work/policy"
LD_PRELOAD="$work/ioctl.so" out/svctl --control "$work/control" status | grep -q 'version=2'
if SCV_TEST_V1=1 LD_PRELOAD="$work/ioctl.so" out/svctl --control "$work/control" status >/dev/null 2>&1; then
 echo 'FAIL v1 kernel accepted'; exit 1
fi
LD_PRELOAD="$work/ioctl.so" out/svreg --control "$work/control" apply 0 "$work/policy" | grep -q 'PUBLISHED generation=1 count=1'
if SCV_TEST_V1=1 LD_PRELOAD="$work/ioctl.so" out/svreg --control "$work/control" apply 0 "$work/policy" >/dev/null 2>&1; then
 echo 'FAIL v1 publication accepted'; exit 1
fi
printf 'root\t%s\t0\t0-0\n' "$work" >"$work/guard"
LD_PRELOAD="$work/ioctl.so" out/svreg --control "$work/control" apply 0 "$work/guard" | grep -q 'PUBLISHED generation=1 count=1'
# The lease is explicit: the default tolerates a slow pm query, and an
# out-of-range value is refused before the control node is touched.
LD_PRELOAD="$work/ioctl.so" out/svreg --control "$work/control" --lease-ms 90000 apply 0 "$work/policy" | grep -q 'PUBLISHED generation=1 count=1'
if LD_PRELOAD="$work/ioctl.so" out/svreg --control "$work/control" --lease-ms 999 apply 0 "$work/policy" >/dev/null 2>&1; then
 echo 'FAIL out-of-range lease accepted'; exit 1
fi
if LD_PRELOAD="$work/ioctl.so" out/svreg --control "$work/control" --lease-ms 300001 apply 0 "$work/policy" >/dev/null 2>&1; then
 echo 'FAIL oversized lease accepted'; exit 1
fi
if LD_PRELOAD="$work/ioctl.so" out/svctl --control "$work/control" --lease-ms 0 clear 1 >/dev/null 2>&1; then
 echo 'FAIL svctl accepted an invalid lease'; exit 1
fi
echo 'v2 helpers: parser, old-kernel rejection, child publication, lease bounds and root-only guard passed'
