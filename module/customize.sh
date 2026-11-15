#!/system/bin/sh
# KernelSU install hook: capability gates only, never a device-name filter.
#
# KernelSU SOURCES this file into the installer shell
# (userspace/ksud/src/android/module/installer.sh), so it runs in the caller's
# shell and must not change shell options. A `set -u` here leaks into the
# installer: installer.sh's own `set_perm` reads its 5th argument ("$5", the
# SELinux context) unconditionally while building the chcon call, so under
# unbound-name checking that line aborts the whole install -- even for the
# four-argument calls below that never pass a context -- with
# "5: parameter not set" -- reported at the sourcing script, i.e. this file.
# Never add `set -u` or a global `set +u` (the latter would silently weaken
# the caller instead). Every name is defaulted explicitly below.
#
# KernelSU applies set_perm_recursive(0755/0644) to the staged module before
# this file runs, so helpers can still be 0644 here. Every file the UAPI probe
# executes is made executable first; otherwise the probe fails with EACCES on
# every device.

MODPATH=${MODPATH:-}
if [ -z "$MODPATH" ] || [ ! -d "$MODPATH" ]; then
	abort "! MODPATH is unset: this hook must be sourced by the KernelSU installer"
fi

ui_print "- Scoped Storage Guard: checking package, architecture and kernel interface"

REQUIRED="bin/svreg bin/svctl bin/autostart.sh bin/scvctl.sh bin/scv-resolve.sh bin/scv-prop.sh config/scv.conf post-fs-data.sh service.sh action.sh uninstall.sh"
for f in $REQUIRED; do
	[ -f "$MODPATH/$f" ] || abort "! package is missing $f"
done

# Order matters: the probe binary must be executable before it is invoked.
set_perm "$MODPATH/bin/svreg" 0 0 0755
set_perm "$MODPATH/bin/svctl" 0 0 0755
[ -x "$MODPATH/bin/svctl" ] || abort "! could not make $MODPATH/bin/svctl executable"

case "${ARCH:-}" in
arm64) ;;
*) abort "! arm64 only: the bundled helpers are static aarch64" ;;
esac

CONTROL=${SCV_CONTROL:-/sys/kernel/security/scoped_visibility/control}
[ -r "$CONTROL" ] || abort "! scoped_visibility control node is absent: flash the required patched kernel and boot it before installing this module"
"$MODPATH/bin/svctl" --control "$CONTROL" status >/dev/null 2>&1 || abort "! control node does not answer the expected UAPI (SV_VERSION_V2 2); install only with the matching kernel"

LEGACY=${SCV_LEGACY_MODULE:-/data/adb/modules/gki_scoped_visibility}
if [ -d "$LEGACY" ] && [ ! -e "$LEGACY/disable" ] && [ ! -e "$LEGACY/remove" ]; then
	ui_print "! legacy module gki_scoped_visibility is still active"
	abort "! disable the legacy module, reboot, then install this one (single registry writer)"
fi

set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/bin/autostart.sh" 0 0 0755
set_perm "$MODPATH/bin/scvctl.sh" 0 0 0755
set_perm "$MODPATH/bin/scv-resolve.sh" 0 0 0755
set_perm "$MODPATH/bin/scv-prop.sh" 0 0 0755
set_perm "$MODPATH/config/scv.conf" 0 0 0600
set_perm "$MODPATH/module.prop" 0 0 0644
set_perm "$MODPATH/skip_mount" 0 0 0644

ui_print "- interface verified; kernel v2 child authorization is required; no ROM property is activated"
ui_print "- policy: config/scv.conf (root-only); status: bin/scvctl.sh status"
