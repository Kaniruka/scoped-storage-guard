#!/system/bin/sh
# Manager action: concise, read-only, no paths and no UID table.
set -u
MODDIR=$(dirname "$0")
STATE_DIR=${SCV_STATE_DIR:-/data/adb/scoped-storage-guard}
echo "== state =="
if [ -f "$STATE_DIR/status" ]; then
	grep -E '^(state|reason|generation|count|users|isolate)=' "$STATE_DIR/status" 2>/dev/null
else
	echo "no state file (module never started this boot)"
fi
echo "== isolation key =="
echo "persist.sys.vold_app_data_isolation_enabled=$(getprop persist.sys.vold_app_data_isolation_enabled 2>/dev/null)"
echo "== controls =="
echo "$MODDIR/bin/scvctl.sh status|diagnostics|stop|disable"
