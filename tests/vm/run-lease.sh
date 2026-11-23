#!/bin/bash
# Kernel regression runner: boots the supplied Image and asserts the
# fail-open lease contract in tests/vm/lease.c.
#
#   KERNEL_IMAGE=/path/to/Image tests/vm/run-lease.sh
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
KERNEL_IMAGE=${KERNEL_IMAGE:-${1:-}}
QEMU=${QEMU:-qemu-system-aarch64}
AARCH64_CC=${AARCH64_CC:-aarch64-linux-gnu-gcc}
TIMEOUT=${QEMU_TIMEOUT:-180}

[ -n "$KERNEL_IMAGE" ] && [ -r "$KERNEL_IMAGE" ] || {
	echo "usage: KERNEL_IMAGE=/path/to/Image $0" >&2; exit 2; }
command -v "$QEMU" >/dev/null || { echo "missing $QEMU" >&2; exit 2; }

OUT=$REPO/out
mkdir -p "$OUT"
"$AARCH64_CC" -static -O2 -Wall -Wextra -I"$REPO/include/uapi" \
	-o "$OUT/lease.arm64" "$HERE/lease.c"

python3 - "$OUT" <<'PY'
import gzip, stat, sys
from pathlib import Path
out = Path(sys.argv[1])
parts, counter = [], 0
def entry(name, mode, data=b"", major=0, minor=0):
    global counter
    counter += 1
    enc = name.encode() + b"\0"
    vals = [counter, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(enc), 0]
    hdr = b"070701" + b"".join(f"{v:08x}".encode() for v in vals)
    parts.append(hdr + enc + b"\0" * ((-(len(hdr) + len(enc))) % 4))
    parts.append(data + b"\0" * ((-len(data)) % 4))
for d in ("dev", "proc", "sys", "fixture"):
    entry(d, stat.S_IFDIR | 0o755)
entry("dev/console", stat.S_IFCHR | 0o600, major=5, minor=1)
entry("dev/null", stat.S_IFCHR | 0o666, major=1, minor=3)
entry("init", stat.S_IFREG | 0o755, (out / "lease.arm64").read_bytes())
entry("TRAILER!!!", 0)
data = b"".join(parts)
(out / "lease-initramfs.cpio.gz").write_bytes(gzip.compress(data, mtime=0))
print("initramfs bytes", len(data))
PY

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
set +e
timeout "$TIMEOUT" "$QEMU" -M virt -cpu max -smp 2 -m 1024 -nographic -no-reboot \
	-nic none -kernel "$KERNEL_IMAGE" -initrd "$OUT/lease-initramfs.cpio.gz" \
	-append "console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init panic=-1" \
	>"$LOG" 2>&1
rc=$?
set -e
grep -E "^LEASE " "$LOG" || true
if grep -q "^LEASE RESULT PASS" "$LOG"; then
	echo "lease regression PASS"
	exit 0
fi
echo "lease regression FAIL (qemu rc=$rc)" >&2
exit 1
