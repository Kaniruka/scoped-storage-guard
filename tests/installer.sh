#!/bin/bash
# Simulated KernelSU installer contract for module/customize.sh.
#
# KernelSU userspace/ksud sources the hook into its own shell
# (userspace/ksud/src/android/module/installer.sh), so the hook runs in the
# caller's shell. Two properties therefore have to hold, and both were missing
# from the 1.1.0 test stub:
#
#   1. the hook must not change the caller's shell options (a leaked `set -u`
#      makes installer.sh's own set_perm abort on its optional "$5" with
#      "5: parameter not set");
#   2. the hook must still gate a real install: arm64, control node, UAPI, and
#      no enabled legacy writer.
#
# The stub below mirrors installer.sh: set_perm reads "$5" without a default,
# the module is staged 0644, and a set_perm call is made both before and after
# the hook is sourced.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
HOOK=$REPO/module/customize.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
FAILED=

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED | $1"; printf 'FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" ;; esac; }
lacks() { case "$1" in *"$2"*) bad "$3" ;; *) ok "$3" ;; esac; }

[ -f "$HOOK" ] || { echo "missing $HOOK" >&2; exit 1; }

# Regression guard: no shell-option mutation of any kind in the hook.
if grep -Eq '^[[:space:]]*set[[:space:]]+[-+][A-Za-z]*u' "$HOOK"; then
	bad "hook never touches shell options"
else
	ok "hook never touches shell options"
fi

cat >"$WORK/driver.sh" <<'EOS'
ui_print() { printf 'ui_print %s\n' "$*"; }
abort() { printf 'ABORT %s\n' "$*" >&2; exit 1; }
# installer.sh contract: the SELinux context is optional and read without a
# default, so a leaked set -u aborts here with "5: parameter not set".
set_perm() {
	chmod "$4" "$1" 2>/dev/null
	if [ -z "$5" ]; then
		SE_CONTEXT=
	else
		SE_CONTEXT=$5
	fi
}
set_perm "$MODPATH/pre-install.marker" 0 0 0644
opts_before=$-
. "$CUSTOMIZE"
opts_mid=$-
printf 'opts_before=%s\n' "$opts_before" >"$OPTS_LOG"
printf 'opts_mid=%s\n' "$opts_mid" >>"$OPTS_LOG"
set_perm "$MODPATH/module.prop" 0 0 0644
printf 'opts_after=%s\n' "$-" >>"$OPTS_LOG"
printf 'post_source_set_perm=ok\n'
EOS

stage() {
	D=$1
	mkdir -p "$D"
	cp -a "$REPO/module/." "$D/mod/"
	# KernelSU stages the tree as 0755 dirs / 0644 files before the hook runs.
	mkdir -p "$D/mod/config"
	cp -a "$REPO/config/scv.conf" "$D/mod/config/scv.conf"
	find "$D/mod" -type d -exec chmod 0755 {} +
	find "$D/mod" -type f -exec chmod 0644 {} +
	printf 'marker\n' >"$D/mod/pre-install.marker"
	cat >"$D/mod/bin/svctl" <<'EOSV'
#!/bin/sh
printf 'svctl-called\n' >>"$PROBE_LOG"
if [ -n "$STUB_SVCTL_RC" ]; then exit "$STUB_SVCTL_RC"; fi
exit 0
EOSV
	printf 'placeholder svreg\n' >"$D/mod/bin/svreg"
	chmod 0644 "$D/mod/bin/svctl" "$D/mod/bin/svreg" "$D/mod/pre-install.marker" \
		"$D/mod/config/scv.conf" "$D/mod/module.prop" "$D/mod/skip_mount"
	: >"$D/control"
	: >"$D/probe.log"
	: >"$D/opts.log"
}

run() {
	NAME=$1
	shift
	D=$WORK/$NAME
	stage "$D"
	if [ -x "$D/mod/bin/svctl" ]; then STAGED_EXEC=yes; else STAGED_EXEC=no; fi
	OUT=$(env CUSTOMIZE="$HOOK" MODPATH="$D/mod" PROBE_LOG="$D/probe.log" \
		OPTS_LOG="$D/opts.log" "$@" sh "$WORK/driver.sh" 2>"$D/err")
	RC=$?
	ERR=$(cat "$D/err")
}

opts_unchanged() {
	before=$(sed -n 's/^opts_before=//p' "$D/opts.log" 2>/dev/null)
	mid=$(sed -n 's/^opts_mid=//p' "$D/opts.log" 2>/dev/null)
	after=$(sed -n 's/^opts_after=//p' "$D/opts.log" 2>/dev/null)
	eq "$1: caller options unchanged after sourcing" "$mid$after" "$before$before"
}

# 1. success path
run ok ARCH=arm64 SCV_CONTROL="$WORK/ok/control" SCV_LEGACY_MODULE="$WORK/ok/legacy" \
	STUB_SVCTL_RC=0
eq "install ok: exit status" "$RC" 0
opts_unchanged "install ok"
has "$OUT" "interface verified" "install ok: gate message"
has "$OUT" "post_source_set_perm=ok" "install ok: installer set_perm still works"
lacks "$OUT$ERR" "parameter not set" "install ok: no unbound optional parameter"
has "$(cat "$WORK/ok/probe.log" 2>/dev/null)" "svctl-called" "install ok: UAPI probe executed"
eq "install ok: svreg 0755" "$(mode_of "$WORK/ok/mod/bin/svreg")" 755
eq "install ok: svctl 0755" "$(mode_of "$WORK/ok/mod/bin/svctl")" 755
eq "install ok: config 0600" "$(mode_of "$WORK/ok/mod/config/scv.conf")" 600
eq "install ok: module.prop 0644" "$(mode_of "$WORK/ok/mod/module.prop")" 644
# 2. the staging contract the hook has to repair
eq "install ok: helper staged non-executable" "$STAGED_EXEC" no

# 3. wrong architecture
run arch ARCH=arm SCV_CONTROL="$WORK/arch/control" SCV_LEGACY_MODULE="$WORK/arch/legacy" \
	STUB_SVCTL_RC=0
[ "$RC" -ne 0 ] && ok "arch: refused" || bad "arch: refused"
has "$ERR" "arm64 only" "arch: reason"

# 4. missing required file
D=$WORK/missing
stage "$D"
rm -f "$D/mod/bin/svreg"
OUT=$(env CUSTOMIZE="$HOOK" MODPATH="$D/mod" PROBE_LOG="$D/probe.log" \
	OPTS_LOG="$D/opts.log" ARCH=arm64 SCV_CONTROL="$D/control" \
	SCV_LEGACY_MODULE="$D/legacy" sh "$WORK/driver.sh" 2>"$D/err")
RC=$?
ERR=$(cat "$D/err")
[ "$RC" -ne 0 ] && ok "missing file: refused" || bad "missing file: refused"
has "$ERR" "missing bin/svreg" "missing file: reason"

# 5. control node absent
run nocontrol ARCH=arm64 SCV_CONTROL="$WORK/nocontrol/absent" \
	SCV_LEGACY_MODULE="$WORK/nocontrol/legacy" STUB_SVCTL_RC=0
[ "$RC" -ne 0 ] && ok "control absent: refused" || bad "control absent: refused"
has "$ERR" "control node is absent" "control absent: reason"

# 6. control node answers but the UAPI probe fails
run baduapi ARCH=arm64 SCV_CONTROL="$WORK/baduapi/control" \
	SCV_LEGACY_MODULE="$WORK/baduapi/legacy" STUB_SVCTL_RC=1
[ "$RC" -ne 0 ] && ok "bad UAPI: refused" || bad "bad UAPI: refused"
has "$ERR" "does not answer the expected UAPI" "bad UAPI: reason"

# 7. legacy module enabled
D=$WORK/legacy
stage "$D"
mkdir -p "$D/legacy"
OUT=$(env CUSTOMIZE="$HOOK" MODPATH="$D/mod" PROBE_LOG="$D/probe.log" \
	OPTS_LOG="$D/opts.log" ARCH=arm64 SCV_CONTROL="$D/control" \
	SCV_LEGACY_MODULE="$D/legacy" sh "$WORK/driver.sh" 2>"$D/err")
RC=$?
ERR=$(cat "$D/err")
[ "$RC" -ne 0 ] && ok "legacy enabled: refused" || bad "legacy enabled: refused"
has "$ERR" "single registry writer" "legacy enabled: reason"

# 8. legacy present but disabled (the upgrade path)
D=$WORK/legacyoff
stage "$D"
mkdir -p "$D/legacy"
: >"$D/legacy/disable"
OUT=$(env CUSTOMIZE="$HOOK" MODPATH="$D/mod" PROBE_LOG="$D/probe.log" \
	OPTS_LOG="$D/opts.log" ARCH=arm64 SCV_CONTROL="$D/control" \
	SCV_LEGACY_MODULE="$D/legacy" sh "$WORK/driver.sh" 2>"$D/err")
RC=$?
eq "legacy disabled: install proceeds" "$RC" 0
opts_unchanged "legacy disabled"

# 9. MODPATH missing: refuse instead of probing an empty path
D=$WORK/nomodpath
stage "$D"
OUT=$(env CUSTOMIZE="$HOOK" ARCH=arm64 PROBE_LOG="$D/probe.log" OPTS_LOG="$D/opts.log" \
	sh "$WORK/driver.sh" 2>"$D/err")
RC=$?
ERR=$(cat "$D/err")
[ "$RC" -ne 0 ] && ok "MODPATH unset: refused" || bad "MODPATH unset: refused"
has "$ERR" "MODPATH is unset" "MODPATH unset: reason"

# 10. caller already runs with -e: the hook must not clear it either
cat >"$WORK/driver-e.sh" <<'EOS'
set -e
. "$WORK/driver.sh"
EOS
D=$WORK/caller_e
stage "$D"
OUT=$(env WORK="$WORK" CUSTOMIZE="$HOOK" MODPATH="$D/mod" PROBE_LOG="$D/probe.log" \
	OPTS_LOG="$D/opts.log" ARCH=arm64 SCV_CONTROL="$D/control" \
	SCV_LEGACY_MODULE="$D/legacy" sh "$WORK/driver-e.sh" 2>"$D/err")
RC=$?
eq "caller -e: install succeeds" "$RC" 0
opts_unchanged "caller -e"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || printf 'failed:%s\n' "$FAILED"
[ "$FAIL" -eq 0 ]
