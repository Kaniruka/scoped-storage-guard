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
