# Scoped Storage Guard

A KernelSU module that activates the standard native app-data isolation key at
boot and publishes one verified `scoped_visibility` registry snapshot for the
Android users that are actually running. It is not a complete storage privacy
guarantee, not a FUSE-BPF implementation, and not a detection/integrity bypass.

Repository: <https://github.com/Kaniruka/scoped-storage-guard>

## Required kernel

* commit `881d7ebcd59d5736a1155e562da61367649322af`
  ([commit](https://github.com/Kaniruka/android_gki_kernel_5.10_common/commit/881d7ebcd59d5736a1155e562da61367649322af),
  [patch](https://github.com/Kaniruka/android_gki_kernel_5.10_common/commit/881d7ebcd59d5736a1155e562da61367649322af.patch))
* `CONFIG_SECURITY_SCOPED_VISIBILITY=y`
* `CONFIG_SECURITYFS=y` and a mounted securityfs (the control node lives at
  `/sys/kernel/security/scoped_visibility/control`)

Merged kernel pull requests:
[#2](https://github.com/Kaniruka/android_gki_kernel_5.10_common/pull/2) and
[#3](https://github.com/Kaniruka/android_gki_kernel_5.10_common/pull/3).

The ROM must also implement the native tmpfs own/shared-UID view for app data
(the behaviour behind `persist.sys.vold_app_data_isolation_enabled`). The
presence of that property alone does **not** prove the ROM implements it, and
this module does not claim support for every Android device or ROM.

## What it does

1. `post-fs-data.sh` checks this boot's control node and UAPI first. Only when
   both answer does it set the standard key
   `persist.sys.vold_app_data_isolation_enabled=true` in RAM (via
   `resetprop -n`, no persistent store), and records that it owns the value for
   this boot. An absent key is set; a key that already exists with any other
   value is left untouched.
2. `service.sh` starts the supervisor, which resolves every covered user,
   requires the whole set to be complete, publishes exactly one snapshot over
   an empty registry, and keeps it current.
3. Cleanup (stop/disable/uninstall) deletes only a value this module set in the
   same boot, and releases only a generation this module published.

No module-specific property is defined. No public temporary file, no SELinux
mode change, no mount/clone and no property write outside the standard key.

## Configuration

`config/scv.conf` (installed root-only at `<module>/config/scv.conf`):

```
# user=auto covers every running user; repeat "user=<id>" for explicit users.
user=auto
# Package whose real UID joins the allowlist; empty or off disables it.
provider_package=com.android.providers.media.module
# auto uses the reported UID; NUMBER must match it; off disables the lookup.
provider_uid=auto
allow_uid=0
allow_uid=1000
# Optional explicit per-kind FUSE mappings ({user} required); a configured
# mapping must be a real FUSE object or publishing is blocked.
# fuse_root=/mnt/user/v/emulated/{user}
# fuse_data=/mnt/user/v/emulated/{user}/Android/data
# fuse_obb=/mnt/user/v/emulated/{user}/Android/obb
fs_allow=fuse,f2fs,ext4
```

* `user=auto` covers every user `pm list users` reports as running (strict
  numeric parsing). Explicit users are verified against the same list.
* The provider package is queried with `pm list packages -U` for **every
  verified running user**, not only the coverage set. A central provider that
  serves several users is therefore found once: `rc=0` without the package
  for a user means "not installed for that user" and is skipped; a non-zero or
  malformed response waits or refuses. At least one exact UID must be verified,
  nothing is derived arithmetically, and an explicit `provider_uid=NUMBER`
  must be present in that verified set. All verified provider UIDs and the
  explicit `allow_uid` values form one sorted union applied to every object;
  DAC/SELinux still decides what those processes may reach.
* Completeness is tracked per `(user, Android/data|obb)`: each pair needs its
  raw lower object and a real FUSE object. The direct FUSE view is
  `/mnt/user/<user>/emulated/<user>/Android/<kind>`; if that one path is a
  whole-F2FS overmount, only that kind falls back to the other running users'
  namespaces (`/mnt/user/<v>/emulated/<u>/Android/<kind>`). Only real FUSE
  objects are accepted, deduplicated by dev+ino; a non-FUSE alias never counts.
* Explicit `fuse_root`/`fuse_data`/`fuse_obb` mappings (with `{user}`) name the
  FUSE object for a user/kind when discovery has none. A configured mapping
  must be real FUSE; missing blocks as `WAITING`, non-FUSE as
  `CONFIG_REQUIRED` instead of falling back to an alias.
* Every covered user must be complete for both kinds, otherwise nothing is
  published (`WAITING` or `CONFIG_REQUIRED`; no partial snapshot). At most 32
  objects.

## Install

Flash and boot a kernel with the required commit and configs **first**, then
install the module. The installer checks arm64, the control node and the UAPI;
it does not filter by device name. A still-enabled legacy module
`gki_scoped_visibility` must be disabled and rebooted first (single writer).

The install hook `customize.sh` is sourced into the KernelSU installer shell
(`userspace/ksud/src/android/module/installer.sh`), so it never changes shell
options: a `set -u` there leaks into the installer, whose own `set_perm` reads
its fifth argument (`"$5"`, the SELinux context) unconditionally, so the
install aborts with `5: parameter not set`. 1.1.1 fixed that; every variable in
the hook is defaulted explicitly instead.

## Status and controls

```
<module>/bin/scvctl.sh status              # concise: state, reason, generation, count
<module>/bin/scvctl.sh diagnostics show    # root only; per-path detail
<module>/bin/scvctl.sh diagnostics on|off  # root only; enable detail for this boot
<module>/bin/scvctl.sh stop                # release own generation + own RAM key
<module>/bin/scvctl.sh disable             # disable marker + stop; reboot to revert
```

State lives in `/data/adb/scoped-storage-guard` (0700, files 0600). Default
status and logs carry no path list and no UID table.

## Limits

* The securityfs node, the ioctl interface and the process/state files are
  observable. This project claims reduced exposure and restricted read
  permissions, not undetectability.
* The kernel keeps its pinned `struct path` references by design.
* Deeper bind mounts, already-open file descriptors, recreated inodes,
  `Android/media` public semantics and FUSE daemon rename paths are not
  covered.
* The UID upper bound is decided as a decimal string, not arithmetically:
  Android's `mksh` has 32-bit signed integers, so `[ 0 -ge 4294967295 ]` is
  true there (the constant wraps to -1). 1.1.1 replaced the numeric bound and
  rejects `4294967295` and above, plus non-canonical forms (`01000`, negatives).
  For the same reason, record fields are split with `cut -d'|'` rather than
  `${rec#*|}`: `mksh` treats a bare `|` in a pattern as alternation.
* Version 1.0.0 of the predecessor module was verified on one Android 17
  (API 37) / kernel 5.10.240 device. 1.1.1 was verified on the same device line
  without reflashing its kernel: automatic publication `generation=1 count=8`
  for two users, the 20-case joint matrix plus four core directions, owner-side
  read/write controls, root-only state permissions (0700/0600) and `Enforcing`
  SELinux. A still-locked secondary user keeps the supervisor in
  `WAITING STORAGE_PENDING` and nothing is published until that user unlocks
  and its raw lower objects exist -- that is the documented boundary, not a
  module failure.
* One device result does not generalize. The ROM must implement the native
  tmpfs own/shared-UID view behind
  `persist.sys.vold_app_data_isolation_enabled`; other devices and ROMs remain
  unverified, and no coverage claim is made beyond the limits listed here.

## Build and test

```
make host        # host helpers
make arm64       # static aarch64 helpers
make test        # offline stub suite + installer contract + host checks
make module      # build/scoped-storage-guard-<version>.zip + MANIFEST
KERNEL_IMAGE=/path/to/Image make smoke   # optional QEMU control-node smoke
```

CI runs the same steps on ubuntu-24.04 with
`gcc-aarch64-linux-gnu` and `shellcheck`. Sources are self-contained under
`src/` and `include/uapi/`; no personal checkout path is referenced.

The QEMU smoke test boots a caller-supplied kernel and checks only the control
node and empty-policy path: `svctl status` exits 0, `svreg apply 0` on an
empty snapshot exits 0 and reads back `generation=1 count=0`. FUSE/F2FS entry
acceptance, user discovery, provider UID resolution and the state machine are
covered by the offline stub suite, not by QEMU.

## License

GPL-2.0 (`LICENSE`), with the Linux syscall note for the vendored UAPI header
(`LICENSES/Linux-syscall-note`). Provenance is recorded in `NOTICE.md`.
