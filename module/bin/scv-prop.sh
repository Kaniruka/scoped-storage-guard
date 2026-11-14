#!/system/bin/sh
# Restore the RAM-only isolation key exactly as recorded by post-fs-data.sh.
# The record is bound to one boot; anything else is left untouched.
set -u
umask 077

SELF_DIR=$(dirname "$0")
MODDIR=$(dirname "$SELF_DIR")
STATE_DIR=${SCV_STATE_DIR:-/data/adb/scoped-storage-guard}
KEY=persist.sys.vold_app_data_isolation_enabled
REC=$STATE_DIR/prop.state
GETPROP=${SCV_GETPROP:-getprop}

[ "${1:-}" = restore ] || { echo "usage: $0 restore" >&2; exit 2; }
[ -f "$REC" ] || { echo "no property record; nothing to restore"; exit 0; }

RESETPROP=${SCV_RESETPROP:-}
if [ -z "$RESETPROP" ]; then
	for c in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop; do
		[ -x "$c" ] && { RESETPROP=$c; break; }
	done
fi
[ -n "$RESETPROP" ] || RESETPROP=$(command -v resetprop 2>/dev/null)

st_boot=$(sed -n 's/^boot_id=//p' "$REC" | head -n1)
owned=$(sed -n 's/^owned=//p' "$REC" | head -n1)
had=$(sed -n 's/^had=//p' "$REC" | head -n1)
before=$(sed -n 's/^before=//p' "$REC" | head -n1)
cur_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)

[ "$st_boot" = "$cur_boot" ] || { echo "record is from another boot; property untouched"; exit 0; }
[ "$owned" = 1 ] || { echo "module did not set the property this boot; nothing to restore"; exit 0; }
[ -n "$RESETPROP" ] || { echo "resetprop unavailable; property left as-is"; exit 1; }

# Only two originals can be recorded: an absent key (delete) or an explicit
# false (write false back). Anything else was refused at set time.
if [ "$had" = 1 ]; then
	if [ "$before" != false ]; then
		echo "recorded original value is unknown; refusing to guess"
		exit 1
	fi
	"$RESETPROP" -n "$KEY" false >/dev/null 2>&1 || { echo "restore write failed"; exit 1; }
	now=$("$GETPROP" "$KEY" 2>/dev/null)
	[ "$now" = false ] || { echo "restore verification failed"; exit 1; }
else
	"$RESETPROP" --delete "$KEY" >/dev/null 2>&1 || { echo "delete failed"; exit 1; }
	now=$("$GETPROP" "$KEY" 2>/dev/null)
	[ -z "$now" ] || { echo "delete verification failed"; exit 1; }
fi

{
	printf 'boot_id=%s\n' "$st_boot"
	printf 'state=restored\n'
	printf 'owned=0\n'
	printf 'had=%s\n' "$had"
	printf 'before=%s\n' "$before"
	printf 'updated=%s\n' "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null)"
} >"$REC.tmp.$$" 2>/dev/null
chmod 600 "$REC.tmp.$$" 2>/dev/null
mv -f "$REC.tmp.$$" "$REC" 2>/dev/null
echo "previous RAM value restored"
exit 0
