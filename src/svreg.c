// SPDX-License-Identifier: GPL-2.0
/*
 * svreg - prepare and publish ONE complete scoped_visibility snapshot.
 *
 *   inspect  resolve explicit paths into O_PATH directory descriptors,
 *            record dev/ino and the filesystem type, and report eligibility
 *            against an explicit filesystem allowlist. Never opens control.
 *   apply    publish exactly one complete snapshot against an explicitly
 *            supplied expected generation, then verify the readback.
 *
 * There is no default range, no inferred allowlist and no automatic retry.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

#include "sv_parse.h"

#define FUSE_MAGIC  0x65735546L
#define F2FS_MAGIC  0xF2F52010L
#define TMPFS_MAGIC 0x01021994L
#define EXT4_MAGIC  0xEF53L
#define EROFS_MAGIC 0xE0F5E1E2L

enum {
	FSB_FUSE = 1u << 0,
	FSB_F2FS = 1u << 1,
	FSB_TMPFS = 1u << 2,
	FSB_EXT4 = 1u << 3,
	FSB_EROFS = 1u << 4,
};

struct fs_kind {
	long magic;
	const char *name;
	unsigned int bit;
};

static const struct fs_kind fs_table[] = {
	{ FUSE_MAGIC, "fuse", FSB_FUSE },
	{ F2FS_MAGIC, "f2fs", FSB_F2FS },
	{ TMPFS_MAGIC, "tmpfs", FSB_TMPFS },
	{ EXT4_MAGIC, "ext4", FSB_EXT4 },
	{ EROFS_MAGIC, "erofs", FSB_EROFS },
};

static unsigned int fs_allow = FSB_FUSE | FSB_F2FS | FSB_EXT4;

enum svreg_exit {
	SVREG_OK = 0,
	SVREG_USAGE = 2,
	SVREG_STALE = 3,
	SVREG_REJECTED = 4,
	SVREG_CONTROL = 5,
	SVREG_READBACK = 6,
};

struct object {
	const char *path;
	int fd;
	dev_t dev;
	ino_t ino;
	mode_t mode;
	uid_t uid;
	gid_t gid;
	long fstype;
	int known;
	unsigned int bit;
	int duplicate_of;
};

static const struct fs_kind *fs_lookup(long magic)
{
	unsigned int i;

	for (i = 0; i < sizeof(fs_table) / sizeof(fs_table[0]); i++)
		if (fs_table[i].magic == magic)
			return &fs_table[i];
	return NULL;
}

static const char *fs_name(long magic)
{
	const struct fs_kind *k = fs_lookup(magic);

	return k ? k->name : "other";
}

static int fs_allowed(long magic)
{
	const struct fs_kind *k = fs_lookup(magic);

	if (!k || k->bit == FSB_TMPFS)
		return 0;
	return (fs_allow & k->bit) != 0;
}

static int parse_fs_allow(const char *list)
{
	unsigned int mask = 0;
	const char *p = list;

	if (!list || !*list)
		return -1;
	for (;;) {
		const char *comma = strchr(p, ',');
		size_t len = comma ? (size_t)(comma - p) : strlen(p);
		const struct fs_kind *k;
		unsigned int i;
		int found = 0;

		if (!len)
			return -1;
		for (i = 0; i < sizeof(fs_table) / sizeof(fs_table[0]); i++) {
			k = &fs_table[i];
			if (strlen(k->name) == len && !strncmp(k->name, p, len)) {
				if (k->bit != FSB_TMPFS)
					mask |= k->bit;
				found = 1;
				break;
			}
		}
		if (!found)
			return -1;
		if (!comma)
			break;
		p = comma + 1;
	}
	if (!mask)
		return -1;
	fs_allow = mask;
	return 0;
}

static void svreg_usage(const char *program)
{
	fprintf(stderr,
		"usage: %s [--control PATH] [--fs-allow LIST] inspect DIRECTORY...\n"
		"       %s [--control PATH] [--fs-allow LIST] apply EXPECTED_GENERATION CONFIG\n"
		"       %s DIRECTORY...            (same as inspect)\n"
		"\n"
		"CONFIG v2: root<TAB>directory<TAB>map_id<TAB>ranges; package<TAB>map_id<TAB>uid<TAB>name. Ranges are always\n"
		"operator input. inspect never opens the control node. apply sends exactly\n"
		"one REPLACE with the caller's expected generation and never adopts a\n"
		"newer one; exit 3 means the generation moved.\n",
		program, program, program);
}

static void print_object(const struct object *o)
{
	printf("OBJECT path=%s dev=%u:%u ino=%llu mode=%04o uid=%u gid=%u "
	       "fstype=0x%lx fs=%s\n",
	       o->path, major(o->dev), minor(o->dev),
	       (unsigned long long)o->ino, (unsigned int)o->mode & 07777,
	       (unsigned int)o->uid, (unsigned int)o->gid, o->fstype,
	       fs_name(o->fstype));
}

static int probe(const char *path, struct object *o)
{
	struct stat st;
	struct statfs sf;
	int fd, err;

	memset(o, 0, sizeof(*o));
	o->path = path;
	o->fd = -1;
	o->duplicate_of = -1;
	fd = open(path, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0)
		return -1;
	if (fstat(fd, &st)) {
		err = errno;
		close(fd);
		errno = err;
		return -1;
	}
	if (!S_ISDIR(st.st_mode)) {
		close(fd);
		errno = ENOTDIR;
		return -1;
	}
	if (fstatfs(fd, &sf)) {
		err = errno;
		close(fd);
		errno = err;
		return -1;
	}
	o->fd = fd;
	o->dev = st.st_dev;
	o->ino = st.st_ino;
	o->mode = st.st_mode;
	o->uid = st.st_uid;
	o->gid = st.st_gid;
	o->fstype = (long)sf.f_type;
	return 0;
}

static const char *open_reason(int err)
{
	if (err == ENOTDIR)
		return "not-dir";
	if (err == ENOENT)
		return "missing";
	if (err == ELOOP)
		return "symlink";
	if (err == EACCES)
		return "denied";
	return "open-error";
}

static int inspect_paths(int count, char **paths)
{
	struct object objects[SV_MAX_ENTRIES];
	int i, j, rejected = 0, err;

	if (count < 1) {
		fprintf(stderr, "inspect needs at least one directory path\n");
		return SVREG_USAGE;
	}
	if (count > SV_MAX_ENTRIES) {
		fprintf(stderr, "inspect accepts at most %d paths (got %d)\n",
			SV_MAX_ENTRIES, count);
		return SVREG_USAGE;
	}
	for (i = 0; i < count; i++) {
		struct object *o = &objects[i];

		if (probe(paths[i], o)) {
			err = errno;
			printf("REJECT path=%s reason=%s errno=%d (%s)\n",
			       paths[i], open_reason(err), err, strerror(err));
			rejected = 1;
			continue;
		}
		for (j = 0; j < i; j++) {
			if (objects[j].fd >= 0 &&
			    objects[j].dev == o->dev &&
			    objects[j].ino == o->ino) {
				o->duplicate_of = j;
				break;
			}
		}
		print_object(o);
		if (o->fstype == TMPFS_MAGIC) {
			printf("REJECT path=%s reason=tmpfs fstype=0x%lx\n",
			       o->path, o->fstype);
			rejected = 1;
		} else if (!fs_allowed(o->fstype)) {
			printf("WARN path=%s reason=fs-not-allowed fstype=0x%lx "
			       "fs=%s eligible=no\n", o->path, o->fstype,
			       fs_name(o->fstype));
		}
		if (o->duplicate_of >= 0)
			printf("NOTE path=%s duplicate-of=%s (same dev/ino in "
			       "this listing; apply would reject it)\n",
			       o->path, objects[o->duplicate_of].path);
		printf("VERDICT path=%s fs=%s eligible=%s\n", o->path,
		       fs_name(o->fstype),
		       (o->fstype != TMPFS_MAGIC && fs_allowed(o->fstype)) ?
		       "yes" : "no");
	}
	for (i = 0; i < count; i++)
		if (objects[i].fd >= 0)
			close(objects[i].fd);
	return rejected ? SVREG_REJECTED : SVREG_OK;
}

static int valid_info(const struct sv_info_v2 *info)
{
	return info->version == SV_VERSION_V2 &&
	       !(info->flags & ~SV_INFO_F_CHILD_AWARE) &&
	       info->nr_entries <= SV_MAX_ENTRIES &&
	       info->nr_packages <= SV_MAX_PACKAGES;
}

static int apply_snapshot(const char *control_path, const char *config_path,
			  uint64_t generation)
{
	struct sv_policy_v2 *policy;
	struct sv_snapshot_v2 *snapshot;
	struct sv_info_v2 before, after;
	dev_t dev[SV_MAX_ENTRIES];
	ino_t ino[SV_MAX_ENTRIES];
	char err[512];
	int control = -1, rc, i, j, count;

	policy = calloc(1, sizeof(*policy));
	if (!policy)
		return SVREG_CONTROL;
	snapshot = &policy->header;
	snapshot->version = SV_VERSION_V2;
	snapshot->expected_generation = generation;
	snapshot->lease_ms = 60000;

	control = open(control_path, O_RDWR | O_CLOEXEC);
	if (control < 0) {
		fprintf(stderr, "control %s: %s\n", control_path,
			strerror(errno));
		free(policy);
		return SVREG_CONTROL;
	}
	if (ioctl(control, SV_IOC_GET_INFO_V2, &before)) {
		perror("GET_INFO");
		rc = SVREG_CONTROL;
		goto out;
	}
	if (!valid_info(&before)) {
		fprintf(stderr, "unsupported status response\n");
		rc = SVREG_CONTROL;
		goto out;
	}
	printf("current generation=%llu count=%u expected=%llu\n",
	       (unsigned long long)before.generation, before.nr_entries,
	       (unsigned long long)generation);
	if (before.generation != generation) {
		fprintf(stderr, "stale expected generation %llu; registry "
			"reports %llu; not retried and no new generation "
			"adopted\n", (unsigned long long)generation,
			(unsigned long long)before.generation);
		rc = SVREG_STALE;
		goto out;
	}
	if (sv_load_policy_v2(config_path, policy, err, sizeof(err))) {
		fprintf(stderr, "%s\n", err);
		rc = SVREG_REJECTED;
		goto out;
	}
	count = (int)snapshot->nr_roots;
	if (!count)
		printf("note: empty snapshot publishes an empty policy\n");
	for (i = 0; i < count; i++) {
		struct stat st;
		struct statfs sf;

		if (fstat(policy->roots[i].fd, &st)) {
			fprintf(stderr, "entry %d: fstat: %s\n", i,
				strerror(errno));
			rc = SVREG_REJECTED;
			goto out;
		}
		if (!S_ISDIR(st.st_mode)) {
			fprintf(stderr, "REJECT entry=%d reason=not-dir\n", i);
			rc = SVREG_REJECTED;
			goto out;
		}
		if (fstatfs(policy->roots[i].fd, &sf)) {
			fprintf(stderr, "entry %d: fstatfs: %s\n", i,
				strerror(errno));
			rc = SVREG_REJECTED;
			goto out;
		}
		if (sf.f_type == TMPFS_MAGIC || !fs_allowed((long)sf.f_type)) {
			fprintf(stderr, "REJECT entry=%d reason=fs-not-allowed "
				"fstype=0x%lx fs=%s\n", i, (long)sf.f_type,
				fs_name((long)sf.f_type));
			rc = SVREG_REJECTED;
			goto out;
		}
		dev[i] = st.st_dev;
		ino[i] = st.st_ino;
		for (j = 0; j < i; j++) {
			if (dev[j] == dev[i] && ino[j] == ino[i]) {
				fprintf(stderr, "REJECT entry=%d reason=duplicate "
					"of entry=%d (same dev/ino)\n", i, j);
				rc = SVREG_REJECTED;
				goto out;
			}
		}
		printf("ACCEPT entry=%d dev=%u:%u ino=%llu fs=%s ranges=%u\n",
		       i, major(dev[i]), minor(dev[i]),
		       (unsigned long long)ino[i],
		       fs_name((long)sf.f_type),
		       policy->roots[i].nr_ranges);
	}
	if (ioctl(control, SV_IOC_REPLACE_V2, snapshot)) {
		if (errno == EAGAIN) {
			fprintf(stderr, "REPLACE: generation changed under us; "
				"not retried, re-inspect and decide again\n");
			rc = SVREG_STALE;
		} else {
			perror("REPLACE (policy not accepted)");
			rc = SVREG_CONTROL;
		}
		goto out;
	}
	if (ioctl(control, SV_IOC_GET_INFO_V2, &after)) {
		perror("GET_INFO readback");
		rc = SVREG_CONTROL;
		goto out;
	}
	if (!valid_info(&after) || !(after.flags & SV_INFO_F_CHILD_AWARE) ||
	    after.nr_packages != snapshot->nr_packages ||
	    (int)after.nr_entries != count) {
		fprintf(stderr, "readback mismatch: count %u != %d\n",
			after.nr_entries, count);
		rc = SVREG_READBACK;
		goto out;
	}
	for (i = 0; i < count; i++) {
		if (after.objects[i].dev_major != (uint32_t)major(dev[i]) ||
		    after.objects[i].dev_minor != (uint32_t)minor(dev[i]) ||
		    after.objects[i].ino != (uint64_t)ino[i]) {
			fprintf(stderr, "readback mismatch: entry %d\n", i);
			rc = SVREG_READBACK;
			goto out;
		}
	}
	if (after.generation != generation + 1) {
		fprintf(stderr, "readback generation=%llu, expected %llu: this "
			"REPLACE succeeded but the snapshot was superseded; "
			"current policy NOT confirmed\n",
			(unsigned long long)after.generation,
			(unsigned long long)(generation + 1));
		rc = SVREG_READBACK;
		goto out;
	}
	printf("PUBLISHED generation=%llu count=%u\n",
	       (unsigned long long)after.generation, after.nr_entries);
	rc = SVREG_OK;
out:
	for (i = 0; i < (int)snapshot->nr_roots; i++)
		close(policy->roots[i].fd);
	if (control >= 0)
		close(control);
	free(policy);
	return rc;
}

int main(int argc, char **argv)
{
	const char *control = SV_CONTROL_PATH;
	const char *allow = SV_DEFAULT_FS_ALLOW;
	int i = 1, rc;
	uint64_t generation;
	const char *end;

	while (i < argc && argv[i][0] == '-') {
		if (!strcmp(argv[i], "--control") && i + 1 < argc) {
			control = argv[i + 1];
			i += 2;
			continue;
		}
		if (!strcmp(argv[i], "--fs-allow") && i + 1 < argc) {
			allow = argv[i + 1];
			i += 2;
			continue;
		}
		if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			svreg_usage(argv[0]);
			return SVREG_OK;
		}
		fprintf(stderr, "unknown option: %s\n", argv[i]);
		svreg_usage(argv[0]);
		return SVREG_USAGE;
	}
	if (parse_fs_allow(allow)) {
		fprintf(stderr, "invalid --fs-allow list: %s\n", allow);
		return SVREG_USAGE;
	}
	if (i >= argc) {
		svreg_usage(argv[0]);
		return SVREG_USAGE;
	}
	if (!strcmp(argv[i], "apply")) {
		if (i + 3 != argc) {
			svreg_usage(argv[0]);
			return SVREG_USAGE;
		}
		end = argv[i + 1];
		if (sv_parse_number(&end, UINT64_MAX, &generation) || *end) {
			fprintf(stderr, "expected generation must be plain "
				"decimal\n");
			return SVREG_USAGE;
		}
		rc = apply_snapshot(control, argv[i + 2], generation);
	} else if (!strcmp(argv[i], "inspect")) {
		rc = inspect_paths(argc - i - 1, argv + i + 1);
	} else {
		rc = inspect_paths(argc - i, argv + i);
	}
	return rc;
}
