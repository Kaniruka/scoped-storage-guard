#!/system/bin/sh
# Early, conditional activation of the standard native-isolation key.
#
# Runs in KernelSU's post-fs-data stage, before system_server constructs its
# cached isolation gates. The key is set ONLY when this boot exposes a readable
# control node whose UAPI answers, and the previous RAM value is recorded so
# this boot's cleanup can put it back. Nothing here writes a persistent
# property store and no property name is invented by this module.
set -u
umask 077

MODDIR=${MODDIR:-$(dirname "$0")}
STATE_DIR=${SCV_STATE_DIR:-/data/adb/scoped-storage-guard}
CONTROL=${SCV_CONTROL:-/sys/kernel/security/scoped_visibility/control}
KEY=persist.sys.vold_app_data_isolation_enabled
SVCTL=${SCV_SVCTL:-$MODDIR/bin/svctl}
GETPROP=${SCV_GETPROP:-getprop}

[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
chmod 700 "$STATE_DIR" 2>/dev/null

BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOT_ID" ] || BOOT_ID=unknown
LOG=$STATE_DIR/log
REC=$STATE_DIR/prop.state
TMP=$REC.tmp.$$

say() {
	printf '%s boot=%s post-fs-data %s\n' \
		"$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null)" "$BOOT_ID" "$*" \
		>>"$LOG" 2>/dev/null
}

write_rec() { # state owned had before
	{
		printf 'boot_id=%s\n' "$BOOT_ID"
		printf 'state=%s\n' "$1"
		printf 'owned=%s\n' "$2"
		printf 'had=%s\n' "$3"
		printf 'before=%s\n' "$4"
		printf 'updated=%s\n' "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null)"
	} >"$TMP" 2>/dev/null || return 1
	chmod 600 "$TMP" 2>/dev/null
	mv -f "$TMP" "$REC" 2>/dev/null
}

find_resetprop() {
	for c in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop; do
		[ -x "$c" ] && { printf '%s' "$c"; return 0; }
	done
	command -v resetprop 2>/dev/null
}

RESETPROP=${SCV_RESETPROP:-$(find_resetprop)}

# Never compete with the legacy module for the same standard property or for
# the registry: when it is still active this boot, record the conflict and
# leave the property untouched.
LEGACY_MODULE=${SCV_LEGACY_MODULE:-/data/adb/modules/gki_scoped_visibility}
if [ -d "$LEGACY_MODULE" ] && [ ! -e "$LEGACY_MODULE/disable" ] &&
	[ ! -e "$LEGACY_MODULE/remove" ]; then
	write_rec legacy-module 0 0 -
	say "legacy module gki_scoped_visibility is active; property left untouched"
	exit 0
fi

if [ ! -r "$CONTROL" ]; then
	write_rec unsupported 0 0 -
	say "control node absent or unreadable; property left untouched"
	exit 0
fi
out=$("$SVCTL" status 2>/dev/null)
case "$out" in
generation=*) ;;
*)
	write_rec unsupported 0 0 -
	say "control node did not answer the expected UAPI; property left untouched"
	exit 0
	;;
esac

# A repeat post-fs-data in the same boot must not turn our own value into an
# "external" one: keep the recorded ownership when it still verifies.
if [ -f "$REC" ]; then
	r_boot=$(sed -n 's/^boot_id=//p' "$REC" | head -n1)
	r_owned=$(sed -n 's/^owned=//p' "$REC" | head -n1)
	if [ "$r_boot" = "$BOOT_ID" ] && [ "$r_owned" = 1 ]; then
		cur=$("$GETPROP" "$KEY" 2>/dev/null)
		if [ "$cur" = true ]; then
			say "isolation key already owned by this module in this boot"
			exit 0
		fi
		write_rec unverified 1 0 -
		say "recorded ownership no longer verifies; not touching the key again"
		exit 0
	fi
fi

# A property dump distinguishes a missing key from one that exists empty,
# false or unknown; getprop KEY alone does not.
dump=$("$GETPROP" 2>/dev/null | grep -F "[$KEY]:" | head -n1)
mode=absent
case "$dump" in
"[$KEY]: [true]") mode=present ;;
"[$KEY]: [false]") mode=false ;;
"[$KEY]: "*) mode=unknown ;;
esac
if [ "$mode" = present ]; then
	write_rec present 0 1 true
	say "isolation key already true; not owned by this module"
	exit 0
fi
if [ "$mode" = unknown ]; then
	# Empty or unrecognised original: refuse to guess how to restore it.
	write_rec foreign-value 0 1 -
	say "isolation key has an unknown value; refusing to change it"
	exit 0
fi
had=0
before=-
if [ "$mode" = false ]; then
	had=1
	before=false
fi

if [ -z "$RESETPROP" ]; then
	write_rec no-resetprop 0 "$had" "$before"
	say "resetprop unavailable; no property write attempted"
	exit 0
fi

if ! "$RESETPROP" -n "$KEY" true >/dev/null 2>&1; then
	write_rec failed 0 "$had" "$before"
	say "resetprop -n failed; property left untouched"
	exit 0
fi
now=$("$GETPROP" "$KEY" 2>/dev/null)
if [ "$now" != true ]; then
	write_rec failed 0 "$had" "$before"
	say "RAM write did not verify; property state unknown"
	exit 0
fi
write_rec set 1 "$had" "$before"
say "isolation key set in RAM for this boot (owned, original recorded)"
exit 0
