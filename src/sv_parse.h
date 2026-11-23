/* SPDX-License-Identifier: GPL-2.0 */
#ifndef SV_PARSE_H
#define SV_PARSE_H

#include <linux/scoped_visibility.h>
#include <stddef.h>
#include <stdint.h>

#define SV_CONTROL_PATH "/sys/kernel/security/scoped_visibility/control"
#define SV_DEFAULT_FS_ALLOW "fuse,f2fs,ext4"
/*
 * A 20 s healthy refresh must tolerate a slow PackageManager query, an APK
 * install or a storage remount without letting the lease lapse. The kernel
 * accepts up to SV_MAX_LEASE_MS.
 */
#define SV_DEFAULT_LEASE_MS 180000U
#define SV_LINE_LIMIT (PATH_MAX + SV_MAX_RANGES * 24)

int sv_parse_number(const char **text, uint64_t limit, uint64_t *result);
int sv_parse_ranges(const char *text, struct sv_entry *entry);
struct sv_policy_v2 {
	struct sv_snapshot_v2 header;
	struct sv_root_v2 roots[SV_MAX_ENTRIES];
	struct sv_package_v2 packages[SV_MAX_PACKAGES];
};
int sv_load_policy_v2(const char *path, struct sv_policy_v2 *policy,
		      char *err, size_t errlen);
void sv_close_policy_v2(struct sv_policy_v2 *policy);

int sv_load_snapshot(const char *config_path, struct sv_snapshot *snapshot,
		     char *err, size_t errlen);

#endif /* SV_PARSE_H */
