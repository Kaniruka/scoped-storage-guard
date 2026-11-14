/* SPDX-License-Identifier: GPL-2.0 */
#ifndef SV_PARSE_H
#define SV_PARSE_H

#include <linux/scoped_visibility.h>
#include <stddef.h>
#include <stdint.h>

#define SV_CONTROL_PATH "/sys/kernel/security/scoped_visibility/control"
#define SV_DEFAULT_FS_ALLOW "fuse,f2fs,ext4"
#define SV_LINE_LIMIT (PATH_MAX + SV_MAX_RANGES * 24)

int sv_parse_number(const char **text, uint64_t limit, uint64_t *result);
int sv_parse_ranges(const char *text, struct sv_entry *entry);
int sv_load_snapshot(const char *config_path, struct sv_snapshot *snapshot,
		     char *err, size_t errlen);

#endif /* SV_PARSE_H */
