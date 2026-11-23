#!/bin/bash
# Regression: the supervisor must never answer a transient PackageManager
# failure with a child-less publication.
#
# Device symptom this reproduces: after the module is installed, the app store
# cannot finish downloads and networked system apps report "no network",
# because every app's own Android/data and Android/obb child starts returning
# ENOENT for a cycle, or forever if the supervisor then dies.
#
# Scenario 1: one transient pm query failure after a healthy publication.
#   Expectation: the verified snapshot (roots AND packages) is renewed.
# Scenario 2: the same failure past the stale window.
#   Expectation: enforcement is released; no deny-all policy is left behind.
# Scenario 3: a failure before the first publication.
#   Expectation: nothing is published; ordinary apps keep full access.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
STUBS=$REPO/tests/stubs
AUTOSTART=$REPO/module/bin/autostart.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
state() { sed -n "s/^$1=//p" "$D/state/status" 2>/dev/null | head -n1; }
count_in() { if [ -f "$2" ]; then grep -c "$1" "$2" 2>/dev/null; else echo 0; fi; }

new_case() {
	D=$WORK/$1
	mkdir -p "$D/state" "$D/calls"
	: >"$D/world"; echo 1 >"$D/gen"; echo 0 >"$D/count"; : >"$D/control"
	: >"$D/users"; : >"$D/pkgs"; : >"$D/calls/all"; echo 0 >"$D/calls/inspect.n"
	printf 'UserInfo{0:Owner:c13} running\n' >>"$D/users"
	printf '0:com.android.providers.media.module:10055\n' >>"$D/pkgs"
	printf '0:com.xiaomi.market:10071\n0:com.miui.voiceassist:10112\n' >"$D/children"
	printf '/data/media/0/Android/data|f2fs|254:55|100\n' >>"$D/world"
	printf '/data/media/0/Android/obb|f2fs|254:55|101\n' >>"$D/world"
	printf '/mnt/user/0/emulated/0/Android/data|fuse|0:220|100\n' >>"$D/world"
	printf '/mnt/user/0/emulated/0/Android/obb|fuse|0:220|101\n' >>"$D/world"
	printf 'user=auto\nprovider_package=com.android.providers.media.module\nprovider_uid=auto\nallow_uid=0\nallow_uid=1000\nfs_allow=fuse,f2fs,ext4\n' >"$D/scv.conf"
	export STUB_WORLD=$D/world STUB_GEN=$D/gen STUB_COUNT=$D/count STUB_CONTROL=$D/control
	export STUB_USERS=$D/users STUB_PKGS=$D/pkgs STUB_CALLS=$D/calls STUB_APPLIED=$D/applied
	export STUB_CHILD_PKGS=$D/children
	export SCV_STATE_DIR=$D/state SCV_CONFIG=$D/scv.conf SCV_CONTROL=$D/control
	export SCV_LEGACY_STATE=$D/legacy-state SCV_LEGACY_MODULE=$D/legacy-module
	export SCV_SVREG=$STUBS/svreg SCV_SVCTL=$STUBS/svctl SCV_PM=$STUBS/pm
	export SCV_NS_MODE=direct SCV_WAIT_INTERVAL=0 SCV_STEADY_INTERVAL=0
	export SCV_SLOW_INTERVAL=0 SCV_MAX_WAIT=1 SCV_CONTROL_TRIES=1
	export SCV_MAX_CYCLES=2 SCV_MAX_APPLY_FAIL=2
	unset STUB_CHILD_FAIL_AFTER STUB_CHILD_CHANGE_AFTER STUB_APPLY_FAIL_AFTER SCV_STALE_GRACE
}

run_sup() { sh "$AUTOSTART" >"$D/out" 2>&1; }

# 1. transient failure: renew the verified snapshot
new_case renew
export STUB_CHILD_FAIL_AFTER=2
run_sup
eq "transient: roots stay registered" "$(cat "$D/count")" 4
eq "transient: app package rules stay authorized" "$(count_in '^package' "$D/applied")" 2
eq "transient: state" "$(state state)" STALE

# 2. same failure past the stale window: release, never a deny-all publication
new_case release
export STUB_CHILD_FAIL_AFTER=2 SCV_STALE_GRACE=-1
run_sup
eq "stale window: enforcement released" "$(cat "$D/count")" 0
eq "stale window: no child-less policy published" "$(count_in '^package' "$D/applied")" 2
eq "stale window: state" "$(state state)" RELEASED

# 3. failure before the first publication: nothing is published at all
new_case before_first
export STUB_CHILD_FAIL_AFTER=0
run_sup
eq "first cycle: nothing applied" "$(count_in '^root' "$D/applied")" 0
eq "first cycle: state" "$(state state)" WAITING

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
