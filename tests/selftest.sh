#!/bin/bash
# Offline self-test: no device, no kernel, no network, no real property store.
# Stubs emulate svreg/svctl/pm/getprop/resetprop; the real scripts under test
# are module/bin/*.sh and module/post-fs-data.sh.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
STUBS=$REPO/tests/stubs
AUTOSTART=$REPO/module/bin/autostart.sh
SCVCTL=$REPO/module/bin/scvctl.sh
POSTFS=$REPO/module/post-fs-data.sh
UNINST=$REPO/module/uninstall.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
FAILED=
RC=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED | $1"; printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
file_has() { if [ -f "$2" ] && grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
file_lacks() { if [ -f "$2" ] && grep -qF -- "$3" "$2"; then bad "$1"; else ok "$1"; fi; }
file_absent() { if [ -e "$2" ]; then bad "$1"; else ok "$1"; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null; }

new_case() {
	NAME=$1
	D=$WORK/$NAME
	rm -rf "$D"
	mkdir -p "$D/state" "$D/calls"
	: >"$D/world"
	echo 1 >"$D/gen"
	echo 0 >"$D/count"
	: >"$D/control"
	printf 'true' >"$D/prop"
	unset STUB_PROP_ABSENT
	: >"$D/users"
	: >"$D/pkgs"
	: >"$D/calls/all"
	echo 0 >"$D/calls/inspect.n"
	cat >"$D/scv.conf" <<'EOF'
user=auto
provider_package=com.android.providers.media.module
provider_uid=auto
allow_uid=0
allow_uid=1000
fs_allow=fuse,f2fs,ext4
EOF
	export STUB_WORLD=$D/world STUB_GEN=$D/gen STUB_COUNT=$D/count STUB_CONTROL=$D/control
	export STUB_PROP=$D/prop STUB_USERS=$D/users STUB_PKGS=$D/pkgs STUB_CALLS=$D/calls
	export STUB_APPLIED=$D/applied STUB_RESETPROP_LOG=$D/resetprop.log
	export SCV_STATE_DIR=$D/state SCV_CONFIG=$D/scv.conf SCV_CONTROL=$D/control
	export SCV_LEGACY_STATE=$D/legacy-state SCV_LEGACY_MODULE=$D/legacy-module
	export SCV_SVREG=$STUBS/svreg SCV_SVCTL=$STUBS/svctl
	export SCV_GETPROP=$STUBS/getprop SCV_PM=$STUBS/pm
	export SCV_NS_MODE=direct SCV_WAIT_INTERVAL=0 SCV_STEADY_INTERVAL=0 SCV_SLOW_INTERVAL=0
	export SCV_MAX_WAIT=1 SCV_MAX_CYCLES=1 SCV_MAX_APPLY_FAIL=2 SCV_CONTROL_TRIES=1
	unset STUB_INO_BUMP_AFTER STUB_BUMP_BEFORE_APPLY STUB_REMOVE_AFTER STUB_REMOVE_PATH STUB_CLEAR_JUMP STUB_PM_RC STUB_PM_GARBAGE
}

add_user() { printf 'UserInfo{%s:Owner:c13} running\n' "$1" >>"$D/users"; }
add_pkg() { printf '%s:%s:%s\n' "$1" "$2" "$3" >>"$D/pkgs"; }
world() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$D/world"; }
state() { sed -n "s/^$1=//p" "$D/state/status" 2>/dev/null | head -n1; }
run_sup() { sh "$AUTOSTART" >"$D/out" 2>&1; RC=$?; }

fixture_single() {
	add_user 0
	add_pkg 0 com.android.providers.media.module 10055
	world /data/media/0/Android/data f2fs 254:55 100
	world /data/media/0/Android/obb f2fs 254:55 101
	world /mnt/user/0/emulated/0/Android/data fuse 0:220 100
	world /mnt/user/0/emulated/0/Android/obb fuse 0:220 101
}

fixture_dual() {
	add_user 0
	add_user 9
	add_pkg 0 com.android.providers.media.module 10055
	add_pkg 9 com.android.providers.media.module 90055
	world /data/media/0/Android/data f2fs 254:55 100
	world /data/media/0/Android/obb f2fs 254:55 101
	world /data/media/9/Android/data f2fs 254:55 200
	world /data/media/9/Android/obb f2fs 254:55 201
	world /mnt/user/0/emulated/0/Android/data fuse 0:220 100
	world /mnt/user/0/emulated/0/Android/obb fuse 0:220 101
	# user 9's own namespace is a whole-F2FS overmount, not a FUSE object
	world /mnt/user/9/emulated/9/Android/data f2fs 254:55 200
	world /mnt/user/9/emulated/9/Android/obb f2fs 254:55 201
	world /mnt/user/0/emulated/9/Android/data fuse 0:250 200
	world /mnt/user/0/emulated/9/Android/obb fuse 0:250 201
}

# ---------------------------------------------------------------- dual user --
new_case dual
fixture_dual
run_sup
eq "dual: exit" "$RC" 0
eq "dual: published" "$(state state)" PUBLISHED
eq "dual: count" "$(state count)" 8
eq "dual: applied lines" "$(grep -c . "$D/applied" 2>/dev/null)" 8
u0=$(grep -F '/data/media/0/Android/data' "$D/applied")
case "$u0" in *"10055-10055"*) ok "dual: user0 object allows its PM uid" ;; *) bad "dual: user0 object allows its PM uid" ;; esac
case "$u0" in *"90055-90055"*) ok "dual: union keeps the other verified PM uid" ;; *) bad "dual: union keeps the other verified PM uid" ;; esac
file_lacks "dual: overmounted path never registered" "$D/applied" "/mnt/user/9/emulated/9/"
file_has "dual: cross namespace FUSE view registered" "$D/applied" "/mnt/user/0/emulated/9/Android/data"
file_has "dual: snapshot carries base identities" "$D/state/snapshot" "0-0,1000-1000,"

# ------------------------------------------------------------ single direct --
new_case single
fixture_single
run_sup
eq "single: published" "$(state state)" PUBLISHED
eq "single: count" "$(state count)" 4
file_has "single: direct FUSE view used" "$D/applied" "/mnt/user/0/emulated/0/Android/data"

# ------------------------------------------------------------- overmount ----
new_case overmount
add_user 0
add_pkg 0 com.android.providers.media.module 10055
world /data/media/0/Android/data f2fs 254:55 100
world /data/media/0/Android/obb f2fs 254:55 101
world /mnt/user/0/emulated/0/Android/data f2fs 254:55 100
world /mnt/user/0/emulated/0/Android/obb f2fs 254:55 101
run_sup
eq "overmount: refused" "$(state state)" CONFIG_REQUIRED
case "$(state reason)" in
NO_FUSE_VIEW*) ok "overmount: reason" ;;
*) bad "overmount: reason ($(state reason))" ;;
esac
file_absent "overmount: nothing applied" "$D/applied"

# -------------------------------------------------- incomplete second user --
new_case incomplete
add_user 0
add_user 9
add_pkg 0 com.android.providers.media.module 10055
add_pkg 9 com.android.providers.media.module 90055
world /data/media/0/Android/data f2fs 254:55 100
world /data/media/0/Android/obb f2fs 254:55 101
world /data/media/9/Android/data f2fs 254:55 200
world /data/media/9/Android/obb f2fs 254:55 201
world /mnt/user/0/emulated/0/Android/data fuse 0:220 100
world /mnt/user/0/emulated/0/Android/obb fuse 0:220 101
run_sup
eq "incomplete: waiting" "$(state state)" WAITING
eq "incomplete: no partial publish" "$(state count)" 0
file_absent "incomplete: nothing applied" "$D/applied"

# --------------------------------------------------------- provider rules --
new_case provider_mismatch
fixture_single
sed -i 's/^provider_uid=auto/provider_uid=12345/' "$D/scv.conf"
run_sup
eq "provider: mismatch refused" "$(state state)" CONFIG_REQUIRED
case "$(state reason)" in
PROVIDER_UID_MISMATCH*) ok "provider: mismatch reason" ;;
*) bad "provider: mismatch reason ($(state reason))" ;;
esac
file_absent "provider: nothing applied" "$D/applied"

new_case provider_missing
fixture_single
: >"$D/pkgs"
run_sup
eq "provider: unresolved refused" "$(state state)" CONFIG_REQUIRED
eq "provider: unresolved reason" "$(state reason)" NO_PROVIDER_UID
file_absent "provider: unresolved nothing applied" "$D/applied"

# A central provider may be installed for only one of the running users.
new_case shared_provider
add_user 0
add_user 9
add_pkg 0 com.android.providers.media.module 10055
world /data/media/0/Android/data f2fs 254:55 100
world /data/media/0/Android/obb f2fs 254:55 101
world /data/media/9/Android/data f2fs 254:55 200
world /data/media/9/Android/obb f2fs 254:55 201
world /mnt/user/0/emulated/0/Android/data fuse 0:220 100
world /mnt/user/0/emulated/0/Android/obb fuse 0:220 101
world /mnt/user/0/emulated/9/Android/data fuse 0:250 200
world /mnt/user/0/emulated/9/Android/obb fuse 0:250 201
run_sup
eq "shared_provider: published" "$(state state)" PUBLISHED
eq "shared_provider: count" "$(state count)" 8
line=$(grep -F '/data/media/9/Android/data' "$D/applied")
case "$line" in *"10055-10055"*) ok "shared_provider: verified UID used" ;; *) bad "shared_provider: verified UID used" ;; esac
case "$line" in *"90055-90055"*) bad "shared_provider: no invented per-user UID" ;; *) ok "shared_provider: no invented per-user UID" ;; esac

new_case provider_query_failed
fixture_single
export STUB_PM_RC=1
run_sup
eq "provider: query failure waits" "$(state state)" WAITING
case "$(state reason)" in
PROVIDER_QUERY_FAILED*) ok "provider: query failure reason" ;;
*) bad "provider: query failure reason ($(state reason))" ;;
esac
file_absent "provider: query failure not applied" "$D/applied"

new_case provider_garbage
fixture_single
export STUB_PM_GARBAGE=1
run_sup
eq "provider: invalid response refused" "$(state state)" CONFIG_REQUIRED
case "$(state reason)" in
PROVIDER_RESPONSE_INVALID*) ok "provider: invalid response reason" ;;
*) bad "provider: invalid response reason ($(state reason))" ;;
esac
file_absent "provider: invalid response not applied" "$D/applied"

new_case provider_explicit
fixture_dual
sed -i 's/^provider_uid=auto/provider_uid=10055/' "$D/scv.conf"
run_sup
eq "provider: explicit verified UID adopted" "$(state state)" PUBLISHED
line=$(grep -F '/data/media/0/Android/data' "$D/applied")
case "$line" in *"10055-10055"*) ok "provider: explicit UID present" ;; *) bad "provider: explicit UID present" ;; esac
case "$line" in *"90055-90055"*) bad "provider: explicit UID only" ;; *) ok "provider: explicit UID only" ;; esac

# -------------------------------------------------------------- uid bounds ---
# Android mksh uses 32-bit signed integers, so a numeric upper bound such as
# [ 0 -ge 4294967295 ] is TRUE on device and refused every valid UID. The bound
# is decided as a decimal string; these cases pin the accepted/rejected edges.
new_case uid_max
fixture_single
sed -i 's/^allow_uid=1000$/allow_uid=1000\nallow_uid=4294967294/' "$D/scv.conf"
run_sup
eq "uid: uint32 max accepted" "$(state state)" PUBLISHED
file_has "uid: max range present" "$D/state/snapshot" "10055-10055,4294967294-4294967294"

new_case uid_over_max
fixture_single
sed -i 's/^allow_uid=1000$/allow_uid=1000\nallow_uid=4294967295/' "$D/scv.conf"
run_sup
eq "uid: 4294967295 refused" "$(state state)" CONFIG_REQUIRED
eq "uid: 4294967295 reason" "$(state reason)" "UID_INVALID:4294967295"
file_absent "uid: 4294967295 not applied" "$D/applied"

new_case uid_over_32
fixture_single
sed -i 's/^allow_uid=1000$/allow_uid=1000\nallow_uid=4294967296/' "$D/scv.conf"
run_sup
eq "uid: 4294967296 refused" "$(state state)" CONFIG_REQUIRED
eq "uid: 4294967296 reason" "$(state reason)" "UID_INVALID:4294967296"

new_case uid_huge
fixture_single
sed -i 's/^allow_uid=1000$/allow_uid=1000\nallow_uid=99999999999999999999/' "$D/scv.conf"
run_sup
eq "uid: 20-digit token refused" "$(state state)" CONFIG_REQUIRED
eq "uid: 20-digit reason" "$(state reason)" "UID_INVALID:99999999999999999999"

new_case uid_leading_zero
fixture_single
sed -i 's/^allow_uid=1000$/allow_uid=1000\nallow_uid=01000/' "$D/scv.conf"
run_sup
eq "uid: leading zero refused" "$(state state)" CONFIG_REQUIRED
eq "uid: leading zero reason" "$(state reason)" "UID_NOT_CANONICAL:01000"

new_case uid_negative
fixture_single
sed -i 's/^allow_uid=1000$/allow_uid=1000\nallow_uid=-1/' "$D/scv.conf"
run_sup
eq "uid: negative refused" "$(state state)" CONFIG_REQUIRED
eq "uid: negative reason" "$(state reason)" "CONFIG_INVALID:bad-allow-uid"

# --------------------------------------------------- partial per-kind FUSE --
new_case partial_fuse
fixture_single
sed -i '\|/mnt/user/0/emulated/0/Android/obb|d' "$D/world"
run_sup
eq "partial: incomplete obb blocks publish" "$(state state)" WAITING
eq "partial: nothing published" "$(state count)" 0
file_absent "partial: nothing applied" "$D/applied"

# ------------------------------------------------- cross-namespace per kind --
new_case cross_kind
add_user 0
add_user 9
add_pkg 0 com.android.providers.media.module 10055
add_pkg 9 com.android.providers.media.module 90055
world /data/media/0/Android/data f2fs 254:55 100
world /data/media/0/Android/obb f2fs 254:55 101
world /data/media/9/Android/data f2fs 254:55 200
world /data/media/9/Android/obb f2fs 254:55 201
world /mnt/user/0/emulated/0/Android/data fuse 0:220 100
world /mnt/user/0/emulated/0/Android/obb fuse 0:220 101
# user 9 direct data is FUSE; direct obb is a whole-F2FS overmount
world /mnt/user/9/emulated/9/Android/data fuse 0:260 200
world /mnt/user/9/emulated/9/Android/obb f2fs 254:55 201
world /mnt/user/0/emulated/9/Android/obb fuse 0:250 201
run_sup
eq "cross_kind: published" "$(state state)" PUBLISHED
eq "cross_kind: count" "$(state count)" 8
file_has "cross_kind: obb via cross namespace" "$D/applied" "/mnt/user/0/emulated/9/Android/obb"
file_lacks "cross_kind: overmounted obb not registered" "$D/applied" "/mnt/user/9/emulated/9/Android/obb"

# ---------------------------------------------------- explicit multi-user ----
new_case explicit_users
fixture_dual
sed -i '/^user=/d' "$D/scv.conf"
printf 'user=0\nuser=9\n' >>"$D/scv.conf"
run_sup
eq "explicit_users: published" "$(state state)" PUBLISHED
eq "explicit_users: count" "$(state count)" 8

# ------------------------------------------------ explicit FUSE mappings ----
new_case fuse_explicit
fixture_single
sed -i '\|/mnt/user/0/emulated/0/Android|d' "$D/world"
world /mnt/user/9/emulated/0/Android/data fuse 0:270 100
world /mnt/user/9/emulated/0/Android/obb fuse 0:270 101
printf 'fuse_root=/mnt/user/9/emulated/{user}\n' >>"$D/scv.conf"
run_sup
eq "explicit_fuse: published" "$(state state)" PUBLISHED
eq "explicit_fuse: count" "$(state count)" 4
file_has "explicit_fuse: mapping used" "$D/applied" "/mnt/user/9/emulated/0/Android/data"

new_case fuse_explicit_missing
fixture_single
sed -i '\|/mnt/user/0/emulated/0/Android|d' "$D/world"
printf 'fuse_data=/mnt/user/0/emulated/{user}/Android/data\nfuse_obb=/mnt/user/0/emulated/{user}/Android/obb\n' >>"$D/scv.conf"
run_sup
eq "explicit_fuse: missing waits" "$(state state)" WAITING
eq "explicit_fuse: missing reason" "$(state reason)" EXPLICIT_FUSE_PENDING
file_absent "explicit_fuse: missing not applied" "$D/applied"

new_case fuse_explicit_invalid
fixture_single
sed -i '\|/mnt/user/0/emulated/0/Android|d' "$D/world"
world /mnt/user/0/emulated/0/Android/data f2fs 254:55 100
world /mnt/user/0/emulated/0/Android/obb f2fs 254:55 101
printf 'fuse_root=/mnt/user/0/emulated/{user}\n' >>"$D/scv.conf"
run_sup
eq "explicit_fuse: non-FUSE refused" "$(state state)" CONFIG_REQUIRED
case "$(state reason)" in
NO_FUSE_VIEW*) ok "explicit_fuse: non-FUSE reason" ;;
*) bad "explicit_fuse: non-FUSE reason ($(state reason))" ;;
esac
file_absent "explicit_fuse: non-FUSE not applied" "$D/applied"

# -------------------------------------------------------------- permissions --
new_case perms
fixture_single
mkdir -p "$D/legacy-state"
printf 'old\n' >"$D/legacy-state/status"
printf 'old\n' >"$D/legacy-state/log"
chmod 755 "$D/legacy-state"
chmod 644 "$D/legacy-state/status" "$D/legacy-state/log"
run_sup
eq "perms: state dir 0700" "$(mode_of "$D/state")" 700
eq "perms: status 0600" "$(mode_of "$D/state/status")" 600
eq "perms: snapshot 0600" "$(mode_of "$D/state/snapshot")" 600
eq "perms: resolve 0600" "$(mode_of "$D/state/resolve")" 600
eq "perms: log 0600" "$(mode_of "$D/state/log")" 600
eq "perms: legacy dir tightened" "$(mode_of "$D/legacy-state")" 700
eq "perms: legacy status tightened" "$(mode_of "$D/legacy-state/status")" 600
eq "perms: legacy log tightened" "$(mode_of "$D/legacy-state/log")" 600

# ---------------------------------------------------------------- conflict --
new_case conflict
fixture_single
run_sup
eq "conflict: first publish" "$(state state)" PUBLISHED
echo 99 >"$D/gen"
run_sup
eq "conflict: foreign generation stops" "$RC" 4
eq "conflict: state" "$(state state)" CONFLICT
file_lacks "conflict: foreign policy not cleared" "$D/calls/all" "clear "

# ------------------------------------------------------- clear on failure --
new_case clear
fixture_single
export STUB_REMOVE_AFTER=1 STUB_REMOVE_PATH=/data/media/0/Android/data
export SCV_MAX_CYCLES=2
run_sup
eq "clear: released after object loss" "$(state count)" 0
case "$(state state)" in
WAITING) ok "clear: back to waiting" ;;
*) bad "clear: back to waiting ($(state state))" ;;
esac
file_has "clear: used own generation" "$D/calls/all" "clear 2"

new_case clear_jump
fixture_single
export STUB_REMOVE_AFTER=1 STUB_REMOVE_PATH=/data/media/0/Android/data STUB_CLEAR_JUMP=2
export SCV_MAX_CYCLES=2
run_sup
eq "clear_jump: unexpected readback stops" "$RC" 5
eq "clear_jump: state" "$(state state)" CLEAR_FAILED

# ------------------------------------------------------------ stop fallback --
new_case stop
fixture_single
run_sup
eq "stop: published first" "$(state state)" PUBLISHED
sh "$SCVCTL" stop >"$D/stop.out" 2>&1; rc=$?
eq "stop: own generation released" "$rc" 0
eq "stop: count cleared" "$(cat "$D/count")" 0
eq "stop: generation advanced" "$(cat "$D/gen")" 3
sed -i 's/^boot_id=.*/boot_id=old-boot/' "$D/state/status"
sh "$SCVCTL" stop >"$D/stop2.out" 2>&1; rc=$?
eq "stop: stale boot refused" "$rc" 4
eq "stop: unchanged after refusal" "$(cat "$D/gen")" 3

new_case stop_unpublished
fixture_single
sh "$SCVCTL" stop >"$D/stop.out" 2>&1; rc=$?
eq "stop: nothing published is a no-op" "$rc" 0

# ------------------------------------------------------------- post-fs-data --
postfs_case() {
	new_case "$1"
	: >"$D/resetprop.log"
	export SCV_RESETPROP=$STUBS/resetprop
}
postfs_case prop_set
: >"$D/prop"
export STUB_PROP_ABSENT=1
sh "$POSTFS" >"$D/post.out" 2>&1
eq "prop: absent key set" "$(cat "$D/prop" 2>/dev/null)" true
file_has "prop: resetprop -n used" "$D/resetprop.log" "-n persist.sys.vold_app_data_isolation_enabled true"
eq "prop: owned" "$(sed -n 's/^owned=//p' "$D/state/prop.state")" 1
eq "prop: recorded absence" "$(sed -n 's/^had=//p' "$D/state/prop.state")" 0
unset STUB_PROP_ABSENT

postfs_case prop_present
printf 'true' >"$D/prop"
sh "$POSTFS" >"$D/post.out" 2>&1
eq "prop: existing true left alone" "$(sed -n 's/^state=//p' "$D/state/prop.state")" present
eq "prop: not owned" "$(sed -n 's/^owned=//p' "$D/state/prop.state")" 0
[ ! -s "$D/resetprop.log" ] && ok "prop: no write when already true" || bad "prop: no write when already true"

postfs_case prop_foreign
printf '1' >"$D/prop"
sh "$POSTFS" >"$D/post.out" 2>&1
eq "prop: foreign value refused" "$(sed -n 's/^state=//p' "$D/state/prop.state")" foreign-value
eq "prop: foreign value untouched" "$(cat "$D/prop")" 1
[ ! -s "$D/resetprop.log" ] && ok "prop: no write on foreign value" || bad "prop: no write on foreign value"

postfs_case prop_false
printf 'false' >"$D/prop"
sh "$POSTFS" >"$D/post.out" 2>&1
eq "prop: explicit false taken over" "$(sed -n 's/^state=//p' "$D/state/prop.state")" set
eq "prop: false recorded as original" "$(sed -n 's/^had=//p' "$D/state/prop.state")" 1
eq "prop: false value recorded" "$(sed -n 's/^before=//p' "$D/state/prop.state")" false
eq "prop: false became true" "$(cat "$D/prop")" true
SCV_STATE_DIR="$D/state" SCV_GETPROP="$STUBS/getprop" SCV_RESETPROP="$STUBS/resetprop" sh "$REPO/module/bin/scv-prop.sh" restore >/dev/null 2>&1
eq "prop: cleanup restores false" "$(cat "$D/prop")" false

postfs_case prop_twice
: >"$D/prop"
export STUB_PROP_ABSENT=1
sh "$POSTFS" >"$D/post.out" 2>&1
sh "$POSTFS" >"$D/post2.out" 2>&1
eq "prop: repeat keeps ownership" "$(sed -n 's/^owned=//p' "$D/state/prop.state")" 1
eq "prop: repeat writes only once" "$(grep -c -- '-n persist' "$D/resetprop.log")" 1
unset STUB_PROP_ABSENT

postfs_case prop_empty_present
: >"$D/prop"
sh "$POSTFS" >"$D/post.out" 2>&1
eq "prop: present-empty refused" "$(sed -n 's/^state=//p' "$D/state/prop.state")" foreign-value

postfs_case prop_legacy
export STUB_PROP_ABSENT=1
mkdir -p "$D/legacy-module"
: >"$D/prop"
sh "$POSTFS" >"$D/post.out" 2>&1
eq "prop: legacy module blocks activation" "$(sed -n 's/^state=//p' "$D/state/prop.state")" legacy-module
eq "prop: legacy leaves key absent" "$(cat "$D/prop" 2>/dev/null)" ""
unset STUB_PROP_ABSENT

postfs_case prop_nocontrol
export STUB_PROP_ABSENT=1
rm -f "$D/control"
sh "$POSTFS" >"$D/post.out" 2>&1
eq "prop: absent control recorded" "$(sed -n 's/^state=//p' "$D/state/prop.state")" unsupported
[ -s "$D/resetprop.log" ] && bad "prop: no write without control" || ok "prop: no write without control"
unset STUB_PROP_ABSENT

# ---------------------------------------------------------------- uninstall --
new_case uninstall
fixture_single
run_sup
mkdir -p "$D/state/lock"
printf 'pid=1\nboot_id=%s\nmodule=scoped_storage_guard\n' "$(cat /proc/sys/kernel/random/boot_id)" >"$D/state/lock/owner"
SCV_STATE_DIR="$D/state" SCV_CONTROL="$D/control" SCV_SVCTL="$STUBS/svctl" sh "$UNINST" >"$D/uninst.out" 2>&1
file_absent "uninstall: state directory removed" "$D/state"
file_absent "uninstall: lock directory removed" "$D/state/lock"

# ---------------------------------------------------------------- installer --
new_case install
MOD=$D/modpath
mkdir -p "$MOD"
cp -a "$REPO/module/." "$MOD/"
mkdir -p "$MOD/bin" "$MOD/config"
cp -a "$REPO/config/scv.conf" "$MOD/config/scv.conf"
: >"$MOD/bin/svreg"
find "$MOD" -type f -exec chmod 0644 {} +
cat >"$MOD/bin/svctl" <<'EOS'
#!/bin/sh
echo called >>"$STUB_SVCTL_CALLS"
exit 0
EOS
chmod 0644 "$MOD/bin/svctl"
: >"$D/probe.log"
export STUB_SVCTL_CALLS=$D/probe.log
cat >"$D/inst.sh" <<'EOS'
ui_print() { :; }
abort() { echo "abort: $*" >&2; exit 1; }
# installer.sh contract: the optional SELinux context is read without a default,
# so a leaked "set -u" from the sourced hook would abort here.
set_perm() {
	chmod "$4" "$1" 2>/dev/null
	if [ -z "$5" ]; then SE_CONTEXT=; else SE_CONTEXT=$5; fi
}
opts_before=$-
. "$CUSTOMIZE"
opts_mid=$-
# installer.sh also installs permissions after the hook returns.
set_perm "$MODPATH/module.prop" 0 0 0644
opts_after=$-
printf 'OPTS before=%s mid=%s after=%s\n' "$opts_before" "$opts_mid" "$opts_after"
[ "$opts_before" = "$opts_mid" ] && [ "$opts_mid" = "$opts_after" ] || {
	echo "OPTION-LEAK: $opts_before -> $opts_mid -> $opts_after" >&2
	exit 7
}
EOS
[ -x "$MOD/bin/svctl" ] && bad "installer: helper starts non-executable" || ok "installer: helper starts non-executable"
CUSTOMIZE="$MOD/customize.sh" MODPATH="$MOD" ARCH=arm64 sh "$D/inst.sh" >"$D/inst.out" 2>&1; rc=$?
eq "installer: succeeds with 0644 staging" "$rc" 0
file_has "installer: probe executed" "$D/probe.log" "called"
file_has "installer: caller options preserved" "$D/inst.out" "OPTS before="
file_lacks "installer: no unbound optional parameter" "$D/inst.out" "parameter not set"
eq "installer: helper executable afterwards" "$(mode_of "$MOD/bin/svctl")" 755
rm -f "$D/control"
CUSTOMIZE="$MOD/customize.sh" MODPATH="$MOD" ARCH=arm64 sh "$D/inst.sh" >"$D/inst2.out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "installer: refuses without control node" || bad "installer: refuses without control node"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || printf 'failed:%s\n' "$FAILED"
[ "$FAIL" -eq 0 ]
