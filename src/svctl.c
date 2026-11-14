// SPDX-License-Identifier: GPL-2.0
/*
 * svctl - administrator interface to the experimental scoped_visibility
 * registry. It is not a coordinator, daemon or policy generator: status,
 * clear, and replace only, each with an explicit expected generation.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "sv_parse.h"

static void usage(const char *program)
{
	fprintf(stderr,
		"usage: %s [--control PATH] status\n"
		"       %s [--control PATH] clear EXPECTED_GENERATION\n"
		"       %s [--control PATH] replace EXPECTED_GENERATION CONFIG\n"
		"CONFIG: directory<TAB>min-max[,min-max...] per line.\n"
		"Ranges are operator input; nothing is inferred.\n",
		program, program, program);
}

static int valid_info(const struct sv_info *info)
{
	return info->version == SV_VERSION && !info->flags && !info->reserved &&
	       info->nr_entries <= SV_MAX_ENTRIES;
}

int main(int argc, char **argv)
{
	const char *control = SV_CONTROL_PATH;
	struct sv_snapshot snapshot;
	struct sv_info info;
	uint64_t generation;
	const char *end;
	int i = 1, control_fd, ret = 1, status, clear;
	unsigned int n;
	char err[512];

	memset(&snapshot, 0, sizeof(snapshot));
	snapshot.version = SV_VERSION;
	memset(&info, 0, sizeof(info));

	while (i < argc && argv[i][0] == '-') {
		if (!strcmp(argv[i], "--control") && i + 1 < argc) {
			control = argv[i + 1];
			i += 2;
			continue;
		}
		if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(argv[0]);
			return 0;
		}
		usage(argv[0]);
		return 1;
	}
	if (i >= argc)
		goto bad_usage;
	status = !strcmp(argv[i], "status");
	clear = !strcmp(argv[i], "clear");
	if (status) {
		if (i + 1 != argc)
			goto bad_usage;
	} else {
		int want = clear ? 2 : 3;

		if (i + want != argc)
			goto bad_usage;
		if (!clear && strcmp(argv[i], "replace"))
			goto bad_usage;
		if (clear && strcmp(argv[i], "clear"))
			goto bad_usage;
		end = argv[i + 1];
		if (sv_parse_number(&end, UINT64_MAX, &generation) || *end) {
			fprintf(stderr, "expected generation must be plain "
				"decimal\n");
			goto bad_usage;
		}
		snapshot.expected_generation = generation;
	}

	control_fd = open(control, status ? O_RDONLY : O_RDWR | O_CLOEXEC);
	if (control_fd < 0) {
		fprintf(stderr, "%s: %s\n", control, strerror(errno));
		return 1;
	}
	if (status) {
		if (ioctl(control_fd, SV_IOC_GET_INFO, &info)) {
			perror("GET_INFO");
			goto out;
		}
		if (!valid_info(&info)) {
			fprintf(stderr, "unsupported status response\n");
			goto out;
		}
		printf("generation=%llu count=%u\n",
		       (unsigned long long)info.generation, info.nr_entries);
		for (n = 0; n < info.nr_entries; n++)
			printf("%u %u:%u:%llu\n", n,
			       info.objects[n].dev_major,
			       info.objects[n].dev_minor,
			       (unsigned long long)info.objects[n].ino);
		ret = 0;
	} else {
		if (!clear) {
			if (sv_load_snapshot(argv[i + 2], &snapshot,
					    err, sizeof(err))) {
				fprintf(stderr, "%s\n", err);
				ret = 1;
				goto out;
			}
		}
		if (ioctl(control_fd, SV_IOC_REPLACE, &snapshot)) {
			if (errno == EAGAIN) {
				fprintf(stderr, "generation changed under us; "
					"not retried and no generation adopted\n");
				ret = 3;
			} else {
				perror("REPLACE (policy not accepted)");
			}
			goto out;
		}
		if (clear)
			printf("cleared generation=%llu\n",
			       (unsigned long long)generation);
		else
			printf("snapshot accepted\n");
		ret = 0;
	}
out:
	for (n = 0; n < snapshot.nr_entries; n++)
		close(snapshot.entries[n].fd);
	close(control_fd);
	return ret;
bad_usage:
	usage(argv[0]);
	return 2;
}
