#!/system/bin/sh
# V2 enforces child authorization in the kernel; no ROM property activation.
# Restore a previous release's same-boot owned RAM value during an upgrade.
MODDIR=${MODDIR:-$(dirname "$0")}
[ ! -x "$MODDIR/bin/scv-prop.sh" ] || "$MODDIR/bin/scv-prop.sh" restore >/dev/null 2>&1
exit 0
