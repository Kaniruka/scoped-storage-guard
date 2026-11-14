#!/usr/bin/env python3
"""Build the QEMU fixture initramfs from the repository's own build outputs."""
from pathlib import Path
import gzip
import stat
import sys

here = Path(__file__).resolve().parent
repo = here.parent.parent
out = repo / "out"
parts = []
counter = 0


def entry(name, mode, data=b"", major=0, minor=0):
    global counter
    counter += 1
    encoded = name.encode() + b"\0"
    values = [counter, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor,
              len(encoded), 0]
    header = b"070701" + b"".join(f"{v:08x}".encode() for v in values)
    parts.append(header + encoded + b"\0" * ((-(len(header) + len(encoded))) % 4))
    parts.append(data + b"\0" * ((-len(data)) % 4))


for name in ("dev", "proc", "sys"):
    entry(name, stat.S_IFDIR | 0o755)
entry("dev/console", stat.S_IFCHR | 0o600, major=5, minor=1)
entry("dev/null", stat.S_IFCHR | 0o666, major=1, minor=3)

sources = [("init", out / "vm-init.arm64"),
           ("svctl", out / "svctl.arm64"),
           ("svreg", out / "svreg.arm64")]
for name, path in sources:
    if not path.is_file():
        sys.exit(f"missing build output: {path}")
    entry(name, stat.S_IFREG | 0o755, path.read_bytes())
entry("empty", stat.S_IFREG | 0o600)
entry("TRAILER!!!", 0)
data = b"".join(parts)
target = out / "initramfs.cpio.gz"
target.write_bytes(gzip.compress(data, mtime=0))
print(f"initramfs bytes={len(data)} target={target}")
