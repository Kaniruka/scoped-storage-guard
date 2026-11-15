#!/system/bin/sh
# Runs at the next post-fs-data after a remove request.
#
# Releases only this module's own generation, restores only a value this module
# set in the same boot, then removes the root-only state directory. A foreign
# generation and the persistent property store are never touched.
set -u
umask 077

MODDIR=$(dirname "$0")
STATE_DIR=${SCV_STATE_DIR:-/data/adb/scoped-storage-guard}
CONTROL=${SCV_CONTROL:-/sys/kernel/security/scoped_visibility/control}
SVCTL=$MODDIR/bin/svctl
STATUS=$STATE_DIR/status
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOT_ID" ] || BOOT_ID=unknown

say() { printf '%s\n' "$*"; }

field() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | head -n1; }

st_id=$(field module_id)
st_boot=$(field boot_id)
st_pub=$(field published)
st_gen=$(field generation)

if [ "$st_id" != scoped_storage_guard ]; then
	say "state is absent or belongs to another module; nothing released"
elif [ "$st_boot" != "$BOOT_ID" ]; then
	say "state is from boot $st_boot (current $BOOT_ID); registry is per-boot"
elif [ "$st_pub" != 1 ]; then
	say "nothing published this boot; nothing released"
elif [ ! -e "$CONTROL" ]; then
	say "control node absent; nothing to release"
else
	cur=$("$SVCTL" --control "$CONTROL" status 2>/dev/null | sed -n 's/^generation=\([0-9][0-9]*\).*/\1/p' | head -n1)
	if [ "$cur" != "$st_gen" ]; then
		say "generation $cur is not ours ($st_gen); external policy untouched"
	elif "$SVCTL" --control "$CONTROL" clear "$st_gen" >/dev/null 2>&1; then
		say "released own generation $st_gen"
	else
		say "clear failed for own generation $st_gen"
	fi
fi

if [ -x "$MODDIR/bin/scv-prop.sh" ]; then
	SCV_STATE_DIR="$STATE_DIR" "$MODDIR/bin/scv-prop.sh" restore >/dev/null 2>&1 ||
		say "property restore reported a failure"
fi

if [ -d "$STATE_DIR/lock" ]; then
	if [ -f "$STATE_DIR/lock/owner" ] &&
		grep -q '^module=scoped_storage_guard$' "$STATE_DIR/lock/owner" 2>/dev/null; then
		rm -rf "$STATE_DIR/lock" 2>/dev/null
		[ -e "$STATE_DIR/lock" ] && say "lock directory could not be removed"
	else
		say "lock directory has no matching owner marker; left in place"
	fi
fi

# The state directory holds resolved paths and UID ranges; remove it.
rm -rf "$STATE_DIR" 2>/dev/null
say "Scoped Storage Guard state removed"
exit 0
