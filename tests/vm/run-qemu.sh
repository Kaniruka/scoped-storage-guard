#!/bin/bash
# Real control-node smoke test. The kernel image is always supplied by the
# caller; this repository never hardcodes a workspace or artifact path.
#
#   KERNEL_IMAGE=/path/to/Image tests/vm/run-qemu.sh
#   tests/vm/run-qemu.sh /path/to/Image
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
KERNEL_IMAGE=${KERNEL_IMAGE:-${1:-}}
QEMU=${QEMU:-qemu-system-aarch64}
AARCH64_CC=${AARCH64_CC:-aarch64-linux-gnu-gcc}
TIMEOUT=${QEMU_TIMEOUT:-180}

if [ -z "$KERNEL_IMAGE" ] || [ ! -r "$KERNEL_IMAGE" ]; then
	echo "usage: KERNEL_IMAGE=/path/to/Image $0   (or pass Image as $1)" >&2
	exit 2
fi
command -v "$QEMU" >/dev/null || { echo "missing $QEMU" >&2; exit 2; }

make -s -C "$REPO" arm64
mkdir -p "$REPO/out"
"$AARCH64_CC" -static -O2 -Wall -Wextra -o "$REPO/out/vm-init.arm64" "$HERE/vm-init.c"
python3 "$HERE/make-initramfs.py"

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
set +e
timeout "$TIMEOUT" "$QEMU" -M virt -cpu cortex-a57 -m 512 -nographic -no-reboot -nic none \
	-kernel "$KERNEL_IMAGE" -initrd "$REPO/out/initramfs.cpio.gz" \
	-append "console=ttyAMA0 rdinit=/init panic=-1" >"$LOG" 2>&1
rc=$?
set -e

grep -E '^SMOKE ' "$LOG" || true
if [ "$rc" -ne 0 ] && ! grep -q 'SMOKE RESULT PASS' "$LOG"; then
	echo "QEMU exited rc=$rc without a PASS result" >&2
	exit 1
fi
grep -q 'SMOKE RESULT PASS' "$LOG" || { echo "QEMU smoke FAILED" >&2; exit 1; }
echo "QEMU control smoke PASS"
