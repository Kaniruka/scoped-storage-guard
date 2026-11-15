// SPDX-License-Identifier: GPL-2.0
/*
 * Shared CONFIG parser for the scoped_visibility helpers.
 *
 * CONFIG is one record per line: DIRECTORY, a literal TAB, then comma
 * separated inclusive decimal UID ranges. Blank lines and lines starting
 * with '#' are ignored. The parser never invents, infers or defaults a
 * range; ranges are always operator input.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "sv_parse.h"

int sv_parse_number(const char **text, uint64_t limit, uint64_t *result)
{
	const char *p = *text;
	uint64_t value = 0;

	if (*p < '0' || *p > '9')
		return -1;
	while (*p >= '0' && *p <= '9') {
		unsigned int digit = (unsigned int)(*p++ - '0');

		if (value > (limit - digit) / 10)
			return -1;
		value = value * 10 + digit;
	}
	*result = value;
	*text = p;
	return 0;
}

int sv_parse_ranges(const char *p, struct sv_entry *entry)
{
	uint64_t lo, hi;

	for (;;) {
		if (entry->nr_ranges == SV_MAX_RANGES ||
		    sv_parse_number(&p, UINT32_MAX - 1ULL, &lo) ||
		    *p++ != '-' ||
		    sv_parse_number(&p, UINT32_MAX - 1ULL, &hi) || lo > hi)
			return -1;
		if (entry->nr_ranges &&
		    lo <= entry->ranges[entry->nr_ranges - 1].max)
			return -1;
		entry->ranges[entry->nr_ranges].min = (uint32_t)lo;
		entry->ranges[entry->nr_ranges].max = (uint32_t)hi;
		entry->nr_ranges++;
		if (!*p)
			return 0;
		if (*p++ != ',')
			return -1;
	}
}

static void set_error(char *err, size_t errlen, const char *what,
		      unsigned int lineno, const char *detail)
{
	if (!err || !errlen)
		return;
	if (detail)
		snprintf(err, errlen, "%s:%u: %s", what, lineno, detail);
	else
		snprintf(err, errlen, "%s:%u: invalid record", what, lineno);
}

int sv_load_snapshot(const char *config_path, struct sv_snapshot *snapshot,
		     char *err, size_t errlen)
{
	FILE *input;
	char *line = NULL;
	size_t capacity = 0;
	ssize_t length;
	unsigned int lineno = 0;
	int ret = -1;

	if (err && errlen)
		err[0] = 0;
	input = fopen(config_path, "r");
	if (!input) {
		if (err && errlen)
			snprintf(err, errlen, "%s: %s", config_path,
				 strerror(errno));
		return -1;
	}
	while ((length = getline(&line, &capacity, input)) >= 0) {
		struct sv_entry *entry;
		char *tab;

		lineno++;
		if (memchr(line, 0, (size_t)length) ||
		    length > SV_LINE_LIMIT) {
			set_error(err, errlen, config_path, lineno,
				  "embedded NUL or oversized record");
			goto out;
		}
		if (length && line[length - 1] == '\n')
			line[--length] = 0;
		if (length && line[length - 1] == '\r')
			line[--length] = 0;
		if (!length || line[0] == '#')
			continue;
		tab = strchr(line, '\t');
		if (!tab || tab == line || strchr(tab + 1, '\t')) {
			set_error(err, errlen, config_path, lineno,
				  "expected exactly one TAB separator");
			goto out;
		}
		if (snapshot->nr_entries >= SV_MAX_ENTRIES) {
			set_error(err, errlen, config_path, lineno,
				  "more than SV_MAX_ENTRIES records");
			goto out;
		}
		*tab++ = 0;
		entry = &snapshot->entries[snapshot->nr_entries];
		memset(entry, 0, sizeof(*entry));
		if (sv_parse_ranges(tab, entry)) {
			set_error(err, errlen, config_path, lineno,
				  "invalid UID range list");
			goto out;
		}
		entry->fd = open(line,
				 O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
		if (entry->fd < 0) {
			if (err && errlen)
				snprintf(err, errlen, "%s:%u: open %s: %s",
					 config_path, lineno, line,
					 strerror(errno));
			goto out;
		}
		snapshot->nr_entries++;
	}
	if (ferror(input)) {
		if (err && errlen)
			snprintf(err, errlen, "%s: read error", config_path);
		goto out;
	}
	ret = 0;
out:
	free(line);
	if (fclose(input))
		ret = -1;
	return ret;
}

/* V2 records: root<TAB>directory<TAB>map_id<TAB>ranges, or
 * package<TAB>map_id<TAB>full_uid<TAB>package.name. No inferred identities. */
static int v2_u32(const char *text, uint32_t *out)
{
	const char *end = text;
	uint64_t n;

	if (!*text || (text[0] == '0' && text[1]) ||
	    sv_parse_number(&end, UINT32_MAX - 1ULL, &n) || *end)
		return -1;
	*out = (uint32_t)n;
	return 0;
}

static int package_name(const char *s)
{
	size_t i, len = strlen(s);

	if (!len || len >= SV_PACKAGE_NAME_SIZE || s[0] == '.' ||
	    s[len - 1] == '.')
		return 0;
	for (i = 0; i < len; i++) {
		char c = s[i];

		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		      (c >= '0' && c <= '9') || c == '_' || c == '.'))
			return 0;
		if (c == '.' && i && s[i - 1] == '.')
			return 0;
	}
	return 1;
}

void sv_close_policy_v2(struct sv_policy_v2 *policy)
{
	unsigned int i;

	for (i = 0; i < policy->header.nr_roots; i++)
		close(policy->roots[i].fd);
	policy->header.nr_roots = 0;
}

int sv_load_policy_v2(const char *path, struct sv_policy_v2 *policy,
		      char *err, size_t errlen)
{
	FILE *f = fopen(path, "r");
	char *line = NULL;
	size_t cap = 0;
	ssize_t len;
	unsigned int lineno = 0, i;
	int ret = -1;

	if (!f) {
		snprintf(err, errlen, "%s: %s", path, strerror(errno));
		return -1;
	}
	while ((len = getline(&line, &cap, f)) >= 0) {
		char *fields[4], *rest, *token;
		int n = 0;
		uint32_t map, uid;

		lineno++;
		if (memchr(line, 0, (size_t)len) || len > SV_LINE_LIMIT)
			goto bad;
		while (len && (line[len - 1] == '\n' || line[len - 1] == '\r'))
			line[--len] = 0;
		if (!len || line[0] == '#')
			continue;
		rest = line;
		while ((token = strsep(&rest, "\t")) != NULL) {
			if (n == 4 || !*token)
				goto bad;
			fields[n++] = token;
		}
		if (n != 4)
			goto bad;
		if (!strcmp(fields[0], "root")) {
			struct sv_root_v2 *root;
			struct sv_entry entry;

			if (policy->header.nr_roots == SV_MAX_ENTRIES ||
			    v2_u32(fields[2], &map))
				goto bad;
			memset(&entry, 0, sizeof(entry));
			if (sv_parse_ranges(fields[3], &entry))
				goto bad;
			root = &policy->roots[policy->header.nr_roots];
			root->fd = open(fields[1], O_PATH | O_DIRECTORY |
					O_NOFOLLOW | O_CLOEXEC);
			if (root->fd < 0)
				goto bad;
			root->map_id = map;
			root->nr_ranges = entry.nr_ranges;
			memcpy(root->ranges, entry.ranges, sizeof(root->ranges));
			policy->header.nr_roots++;
		} else if (!strcmp(fields[0], "package")) {
			struct sv_package_v2 *pkg;

			if (policy->header.nr_packages == SV_MAX_PACKAGES ||
			    v2_u32(fields[1], &map) ||
			    v2_u32(fields[2], &uid) || !package_name(fields[3]))
				goto bad;
			for (i = 0; i < policy->header.nr_packages; i++) {
				if (policy->packages[i].map_id == map &&
				    !strcmp(policy->packages[i].name, fields[3]))
					goto bad;
			}
			pkg = &policy->packages[policy->header.nr_packages++];
			pkg->map_id = map;
			pkg->uid = uid;
			memcpy(pkg->name, fields[3], strlen(fields[3]) + 1);
		} else {
			goto bad;
		}
	}
	if (ferror(f))
		goto bad;
	for (i = 0; i < policy->header.nr_packages; i++) {
		unsigned int j;

		for (j = 0; j < policy->header.nr_roots; j++) {
			if (policy->packages[i].map_id == policy->roots[j].map_id)
				break;
		}
		if (j == policy->header.nr_roots)
			goto bad;
	}
	policy->header.roots_ptr = policy->header.nr_roots ?
		(uintptr_t)policy->roots : 0;
	policy->header.packages_ptr = policy->header.nr_packages ?
		(uintptr_t)policy->packages : 0;
	ret = 0;
	goto out;
bad:
	set_error(err, errlen, path, lineno, "invalid v2 policy record");
out:
	free(line);
	fclose(f);
	return ret;
}
