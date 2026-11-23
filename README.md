# Scoped Storage Guard

KernelSU module for `scoped_visibility` **v2 child-aware authorization**. It
publishes verified Android/data and Android/obb roots plus PackageManager's
package-name → complete UID mappings. It does not require a ROM's native tmpfs
own/shared-UID view or `persist.sys.vold_app_data_isolation_enabled`, and never
automatically activates that property.

Repository: <https://github.com/Kaniruka/scoped-storage-guard>

## Required kernel

* `CONFIG_SECURITY_SCOPED_VISIBILITY=y`, `CONFIG_SECURITYFS=y` and mounted
  securityfs at `/sys/kernel/security/scoped_visibility/control`.
* The matching v2 implementation: `SV_IOC_GET_INFO_V2`, `SV_IOC_REPLACE_V2`,
  child-aware roots/maps and kernel authorization leases. The vendored
  [UAPI](include/uapi/linux/scoped_visibility.h) defines the exact interface.
* The old v1 kernel commit `881d7ebcd59d5736a1155e562da61367649322af` alone is
  **insufficient**. Installer, supervisor and publication helpers reject v1
  instead of silently publishing an incompatible policy.

## Behavior

Root/system and every verified provider UID retain their explicit root ranges.
Other UIDs can stat/search a registered root, but cannot enumerate it. A lookup
of its immediate package child, including a nonexistent child, requires that
exact name and the caller's complete UID in that root's user map. Packages with
a shared UID can reach each other's package children. Cross-user identities
remain distinct. Normal DAC/SELinux permissions still apply.

The resolver requires all running covered users' lower and real FUSE objects
for both Android/data and Android/obb. It accepts no partial snapshot. All roots
for one user share that user's package map. It reads the complete trusted
`pm list packages -U --user ID` table twice, checks canonical UIDs and package
names, rejects empty/malformed/duplicate/conflicting responses, and requires the
running-user list and provider responses to stay unchanged across resolution.
No UID is invented from an appId. At most 32 roots and 4096 package rules.

Each healthy supervisor cycle resolves the complete snapshot again and renews
its 180000ms kernel lease, including when the table is unchanged. The default
healthy interval is 20 seconds, so a slow `pm` query, an APK install or a
storage remount does not let the lease lapse. Lease time uses monotonic time
and does not include suspend. A foreign generation is never adopted or
cleared.

Failures are never answered with a child-less policy. While a verified
snapshot exists, a transient PM/storage failure renews that snapshot for up to
`SCV_STALE_GRACE` seconds (default 300) and reports `STALE`. Past that window,
or after any hard configuration failure or abnormal supervisor exit, the
module **releases its own generation** and reports `RELEASED`: the kernel then
stops enforcing and ordinary DAC/SELinux behaviour applies. The same applies
when the kernel lease expires, so a dead, stopped or stalled supervisor can
never leave the device denying every application its own Android/data and
Android/obb. Losing protection is preferable to a device-wide storage outage;
the state and reason stay visible in `scvctl.sh status`.

`post-fs-data.sh` performs only compatibility cleanup of a previous release's
same-boot owned RAM property record. Stop/disable/uninstall explicitly release
only this module's recorded generation. No module-specific property, public
temporary file, SELinux mode change, mount or clone is introduced.

## Configuration

Installed root-only at `<module>/config/scv.conf`:

```ini
user=auto
provider_package=com.android.providers.media.module
provider_uid=auto
allow_uid=0
allow_uid=1000
# fuse_root=/mnt/user/0/emulated/{user}
# fuse_data=/mnt/user/0/emulated/{user}/Android/data
# fuse_obb=/mnt/user/0/emulated/{user}/Android/obb
fs_allow=fuse,f2fs,ext4
```

`user=auto` covers all users that `pm list users` reports as running. Repeated
numeric `user=ID` lines select explicit running users. The provider is checked
for every running user, including users outside the coverage set. A successful
empty provider response means it is not installed for that user; at least one
verified provider UID is required unless provider lookup is disabled.
`provider_uid=NUMBER` must match a reported UID; `off` disables provider lookup.
The sorted union of `allow_uid` and verified provider UIDs applies to every root.
These identities bypass child authorization and must be configured carefully.

Each covered `(user, data|obb)` needs its raw lower object and a real FUSE
object. Direct FUSE discovery uses
`/mnt/user/<user>/emulated/<user>/Android/<kind>`. Missing/non-FUSE pairs can use
another covered user's namespace
`/mnt/user/<view-user>/emulated/<user>/Android/<kind>`. Objects are deduplicated
by dev+ino. Explicit per-kind mappings require `{user}` and are authoritative:
a missing path waits; a non-FUSE path requires configuration correction.

## Install and controls

Flash and boot the matching v2 kernel first, then install this module. Static
helpers require arm64. An enabled legacy `gki_scoped_visibility` module must be
disabled and rebooted first. The installer is sourced by KernelSU and never
changes its caller's shell options.

```sh
<module>/bin/scvctl.sh status
<module>/bin/scvctl.sh diagnostics show
<module>/bin/scvctl.sh diagnostics on|off
<module>/bin/scvctl.sh stop
<module>/bin/scvctl.sh disable
```

State lives in `/data/adb/scoped-storage-guard` (0700; files 0600). Default
status/logs contain no path list or UID table. Control status reports
`lease_remaining_ms`; zero means expired or no active v2 policy. A nonzero
package count alone does not prove authorization is still live. `PUBLISHED` means a complete
snapshot was accepted. `STALE` means resolution failed and the last verified
snapshot is being renewed, so enforcement is still live but no longer matches
PackageManager. `RELEASED` means the module withdrew its own generation and
nothing is enforced. `WAITING` before the first publication does **not** mean
roots are protected. An expired lease stops enforcing entirely rather than
denying app children.

## Limits and lifecycle

* PM collection and kernel publication are bounded asynchronous polling, not an
  atomic PackageManager transaction. Uninstall/reinstall, UID reuse, install,
  user changes and provider changes can race a matching double snapshot. A new
  installation may temporarily lack access; a reused UID can temporarily inherit
  the old UID's authorization until refresh/revocation. A stopped or failed
  supervisor cannot renew child grants beyond the running-time lease; after it
  lapses the kernel stops enforcing instead of denying every app.
  Range-authorized identities are explicit exemptions and remain unaffected
  while a policy is live.
* Protection begins only after the first complete publication. Locked users,
  missing storage, unsupported kernels or PM failures can prevent it. Existing
  policy is not automatically adopted after supervisor restart; a foreign or
  unowned nonempty registry produces a conflict requiring operator attention.
* The kernel pins root paths. Recreated root inodes require rediscovery; deeper
  bind mounts, already-open file descriptors and a task already below a protected
  root are outside this boundary. Revocation does not revoke such descriptors.
* Android/media public semantics and FUSE daemon rename paths are not covered.
  Root enumeration is denied rather than filtered to an app's own names.
* The control node, ioctl interface, process and root-only state remain
  observable. This is not an integrity/detection bypass or a complete storage
  privacy guarantee. On 2026-11-15 the matching v2 kernel passed 236 QEMU
  native/compat checks across rootless and BakaSU configurations, then was
  deployed with this module on one mayfly Android 17 device. Automatic renewal
  covered two users, eight roots and 462 package records without the native
  isolation property. A zero-capability ordinary app on F2FS could read,
  create and rename within its own package while foreign and absent packages
  both returned ENOENT. Via started with APK-install permission restored, and
  MT opened a controlled ZIP and created its extraction cache successfully.
  Test packages and temporary files were removed. This does not establish
  all-ROM compatibility, secondary-user app operations, OBB writes, complete
  hardware coverage, long-term stability or performance.
* UID decimal bounds avoid wide integer arithmetic in Android mksh. Record
  splitting uses `cut`, because mksh interprets bare `|` patterns differently.

## Build and test

```sh
make host
make arm64
make test check
make module
KERNEL_IMAGE=/path/to/Image make smoke
# kernel-side lease contract (own access after expiry)
KERNEL_IMAGE=/path/to/Image make lease
```

The test suite covers resolution across dash/mksh/BusyBox, PM consistency and
shared UIDs, lease renewal, transient-failure renewal and stale-window
release instead of a child-less policy, installer contracts,
UID bounds, and the real helpers' parser/UAPI boundary using an ioctl fixture.
It does not substitute for a matching-kernel device test. Optional QEMU smoke
checks the control node and an empty v2 publication only.

## License

GPL-2.0 (`LICENSE`), with the Linux syscall note for the vendored UAPI header
(`LICENSES/Linux-syscall-note`). Provenance is recorded in `NOTICE.md`.
