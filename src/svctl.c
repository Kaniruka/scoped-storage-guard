// SPDX-License-Identifier: GPL-2.0
/* V2-only administrative helper: never silently falls back to v1. */
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

static void usage(void)
{
	fprintf(stderr, "usage: svctl [--control PATH] [--lease-ms N] "
		"status|clear GENERATION|replace GENERATION CONFIG\n");
}

static int show_status(int fd)
{
	struct sv_info_v2 info = {0};

	if (ioctl(fd, SV_IOC_GET_INFO_V2, &info)) {
		perror("GET_INFO_V2");
		return 1;
	}
	if (info.version != SV_VERSION_V2 ||
	    (info.flags & ~SV_INFO_F_CHILD_AWARE) ||
	    info.nr_entries > SV_MAX_ENTRIES ||
	    info.nr_packages > SV_MAX_PACKAGES) {
		fprintf(stderr, "unsupported v2 status response\n");
		return 1;
	}
	printf("generation=%llu count=%u version=2 child_aware=%u packages=%u "
	       "lease_remaining_ms=%llu\n",
	       (unsigned long long)info.generation, info.nr_entries,
	       !!(info.flags & SV_INFO_F_CHILD_AWARE), info.nr_packages,
	       (unsigned long long)info.lease_remaining_ms);
	return 0;
}

int main(int argc, char **argv)
{
	const char *control = SV_CONTROL_PATH, *end;
	struct sv_policy_v2 *policy = NULL;
	uint64_t generation;
	uint64_t lease_ms = SV_DEFAULT_LEASE_MS;
	int i = 1, fd, ret = 1, clear;
	char err[512];

	if (i + 1 < argc && !strcmp(argv[i], "--control")) {
		control = argv[i + 1];
		i += 2;
	}
	if (i + 1 < argc && !strcmp(argv[i], "--lease-ms")) {
		end = argv[i + 1];
		if (sv_parse_number(&end, SV_MAX_LEASE_MS, &lease_ms) || *end ||
		    lease_ms < SV_MIN_LEASE_MS) {
			fprintf(stderr, "lease must be %u..%u ms\n",
				SV_MIN_LEASE_MS, SV_MAX_LEASE_MS);
			return 2;
		}
		i += 2;
	}
	if (i >= argc)
		goto bad_usage;
	clear = !strcmp(argv[i], "clear");
	if (!strcmp(argv[i], "status")) {
		if (i + 1 != argc)
			goto bad_usage;
		fd = open(control, O_RDONLY | O_CLOEXEC);
		if (fd < 0) {
			perror(control);
			return 1;
		}
		ret = show_status(fd);
		close(fd);
		return ret;
	}
	if ((!clear && strcmp(argv[i], "replace")) ||
	    argc != i + (clear ? 2 : 3))
		goto bad_usage;
	end = argv[i + 1];
	if (sv_parse_number(&end, UINT64_MAX, &generation) || *end)
		goto bad_usage;

	policy = calloc(1, sizeof(*policy));
	if (!policy)
		return 1;
	policy->header.version = SV_VERSION_V2;
	policy->header.expected_generation = generation;
	policy->header.lease_ms = lease_ms;
	if (!clear && sv_load_policy_v2(argv[i + 2], policy, err, sizeof(err))) {
		fprintf(stderr, "%s\n", err);
		goto out;
	}
	fd = open(control, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror(control);
		goto out;
	}
	if (ioctl(fd, SV_IOC_REPLACE_V2, &policy->header)) {
		ret = errno == EAGAIN ? 3 : 1;
		perror("REPLACE_V2");
	} else {
		printf("snapshot accepted\n");
		ret = 0;
	}
	close(fd);
out:
	sv_close_policy_v2(policy);
	free(policy);
	return ret;
bad_usage:
	usage();
	return 2;
}
