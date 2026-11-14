#!/system/bin/sh
# KernelSU late_start service stage: proceed in the background.
MODDIR=$(dirname "$0")
exec "$MODDIR/bin/autostart.sh"
