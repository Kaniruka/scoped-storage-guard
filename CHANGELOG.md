# Changelog

## 1.1.1 — 2026-11-14

Two device-blocking fixes found on the first real installation: an installer
shell-option leak and a 32-bit integer overflow in the UID bound check. The
1.1.0 preview release and its assets stay as published and are not replaced.

* Fixed (installer): `customize.sh` runs sourced inside the KernelSU installer
  shell (`userspace/ksud/src/android/module/installer.sh`). It no longer sets
  shell options. The previous `set -u` leaked into the installer, whose own
  `set_perm` reads its fifth argument (`"$5"`, the SELinux context)
  unconditionally, so a real `ksud module install` of 1.1.0 stopped with
  `5: parameter not set` before any gate completed. Every variable in the hook
  is now defaulted explicitly (`${MODPATH:-}`, `${ARCH:-}`,
  `${SCV_CONTROL:-}`, `${SCV_LEGACY_MODULE:-}`), plus a guard that refuses to
  run with an unset `MODPATH`.
* Fixed (resolver): the UID upper bound was `[ "$id" -ge 4294967295 ]`. Android
  `mksh` has 32-bit signed integers, so that constant wraps to -1 and the test
  is true for every value: a device boot reported `CONFIG_REQUIRED`
  `UID_INVALID:0` and published nothing. `u32_bound_ok()` now decides
  `0..4294967294` as a strict canonical decimal string (digit count plus
  lexicographic patterns), with no arithmetic and no dependence on the shell's
  integer width. `4294967295`, `4294967296`, longer tokens, negatives and
  leading-zero forms (`01000`) are refused, with `UID_INVALID` versus
  `UID_NOT_CANONICAL` preserved. The canonical check for `allow_uid` moved into
  config parsing so `sort -n -u` can no longer fold a leading-zero token into
  its numeric neighbour before it is validated.
* Fixed (resolver, mksh field parsing): the `fs` field was taken with
  `${rec#*|}` + `${fs%%|*}`. Android `mksh` treats a bare `|` inside a
  pattern as alternation, so the record survived `#` and the following `%%`
  produced an empty `fs`; the boot then reported `CONFIG_REQUIRED`
  `FS_NOT_ALLOWED:0` with zero objects. All four sites now use
  `cut -d'|' -f2`, the same way `dev`/`ino` were already parsed. No other
  module shell code uses a bare `|` inside a parameter pattern.
* Changed: `version=1.1.1`, `versionCode=1101`. Module id, name and author are
  unchanged.
* Fixed (tests): the offline stub did not reproduce the installer contract.
  `tests/installer.sh` now sources the hook in a shell whose `set_perm` reads
  `"$5"` without a default (exactly as installer.sh does), stages the module
  0644, calls `set_perm` before and after the hook, and asserts the caller's
  shell options are unchanged. It also covers the success gates (arm64, control
  node, UAPI probe, legacy writer disabled, new `MODPATH` guard) and the
  resulting permissions (helpers 0755, config 0600, `module.prop` 0644).
  `tests/u32.sh` extracts the bound predicate and pins the accepted/rejected
  table, running it under `dash` and, when installed, `mksh`/`busybox`;
  `tests/selftest.sh` adds end-to-end cases for `0`, `1000`, `4294967294`
  (accepted) and `4294967295`, `4294967296`, a 20-digit token, `01000` and
  `-1` (refused). `tests/resolver.sh` runs the real resolver end to end on the
  dual-user fixture (8 objects) under `dash`, `mksh` and `busybox sh` (argv
  selectable, `SCV_RESOLVER_UNDER_TEST` overrides the script), which is what
  catches the mksh `|` pattern difference; restoring the old extraction makes
  it fail with `config_required`/`FS_NOT_ALLOWED` again.

## 1.1.0 — 2026-11-14

First generalized public preview (repo `Kaniruka/scoped-storage-guard`),
derived from the device-trial prototype after the merged kernel pull requests
#2 and #3.

* Boot-time RAM-only activation of `persist.sys.vold_app_data_isolation_enabled`
  behind the control-node/UAPI gate, with same-boot ownership tracking.
* One verified `scoped_visibility` registry snapshot over an empty registry for
  every running covered user; per-`(user, kind)` completeness, exact provider
  UID union, FUSE-only objects, `WAITING`/`CONFIG_REQUIRED` instead of partial
  publication.
* Root-only state under `/data/adb/scoped-storage-guard` (0700, files 0600);
  `scvctl.sh status|diagnostics|stop|disable`.
* Published preview asset: `scoped-storage-guard-1.1.0.zip`, sha256
  `7907ed0ecab010a398144ccd0c04e1572d764ced4d2adc554839b36d3c47f439`
  (immutable; superseded by 1.1.1 for installation).
