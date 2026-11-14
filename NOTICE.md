# Provenance and attribution

Scoped Storage Guard is derived from the earlier `gki_scoped_visibility`
module and the scoped_visibility prototype work. Module metadata author and
maintainer: **Rukani (Kaniruka)**, the same author as that earlier work.
Original kernel-side authorship and GPL-2.0 licensing are preserved.

| Component | Origin |
|---|---|
| module layout, supervisor design, status machine | the earlier `gki_scoped_visibility` module, rewritten for this repository |
| `src/svreg.c` | the earlier registry activation helper, refactored to share the parser and take a filesystem allowlist (GPL-2.0) |
| `src/svctl.c` | kernel `tools/testing/selftests/scoped_visibility/svctl.c` at commit `881d7ebcd59d5736a1155e562da61367649322af` (GPL-2.0) |
| `include/uapi/linux/scoped_visibility.h` | same commit, GPL-2.0 WITH Linux-syscall-note; copied verbatim |
| kernel-side interface | commit `881d7ebcd59d5736a1155e562da61367649322af`, pull requests [#2](https://github.com/Kaniruka/android_gki_kernel_5.10_common/pull/2) and [#3](https://github.com/Kaniruka/android_gki_kernel_5.10_common/pull/3) |

Module metadata author: **Rukani (Kaniruka)**.
License: GPL-2.0 (`LICENSE`); syscall note: `LICENSES/Linux-syscall-note`.
