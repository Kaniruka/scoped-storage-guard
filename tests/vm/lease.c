// SPDX-License-Identifier: GPL-2.0
/*
 * Kernel-side regression fixture for the failure modes that break ordinary
 * apps when the supervisor is unhealthy:
 *
 *   T1 live child-aware policy, package table present -> own dir works
 *   T2 roots-only publication (explicit deny-all)      -> own dir ENOENT
 *   T3 package table present, kernel lease expired     -> own dir must still work
 *
 * T3 is the fail-open contract: an expired lease means "the controller is not
 * renewing", not "deny every app its own Android/data". Before that contract
 * existed, a dead or stalled supervisor turned into a device-wide storage
 * outage for every installed application.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <linux/scoped_visibility.h>

#define CONTROL "/sys/kernel/security/scoped_visibility/control"
#define ROOT "/fixture/android-data"
#define OWN ROOT "/com.example.own"
#define OWN_FILE OWN "/known"
#define FOREIGN ROOT "/com.example.other"

#define APP_UID 10064
#define OTHER_UID 10065

static int ctl = -1;
static int root_fd = -1;
static int failures;
static unsigned long long generation;

static void mkdir_p(const char *path, mode_t mode)
{
	if (mkdir(path, mode) && errno != EEXIST)
		printf("LEASE mkdir %s errno=%d\n", path, errno);
}

static int touch(const char *path)
{
	int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0666);

	if (fd < 0)
		return -1;
	return close(fd);
}

static void report(const char *what, int ok)
{
	printf("LEASE %-52s %s\n", what, ok ? "ok" : "FAIL");
	if (!ok)
		failures++;
}

struct probe_result {
	int own_stat;
	int own_open;
	int own_open_errno;
	int own_mkdir;
	int foreign_stat;
	int root_list;
	int root_list_errno;
};

static void run_probe(struct probe_result *r)
{
	char buf[4096];
	struct stat st;
	int fd;

	memset(r, 0, sizeof(*r));
	if (setgroups(0, NULL) || setgid(APP_UID) || setuid(APP_UID))
		_exit(3);
	r->own_stat = stat(OWN_FILE, &st) == 0;
	errno = 0;
	fd = open(OWN, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	r->own_open = fd >= 0;
	r->own_open_errno = fd >= 0 ? 0 : errno;
	if (fd >= 0)
		close(fd);
	r->own_mkdir = mkdir(OWN "/lease-dir", 0777) == 0 ||
		       (errno == EEXIST && 1);
	errno = 0;
	r->foreign_stat = stat(FOREIGN, &st) == 0;
	errno = 0;
	fd = open(ROOT, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0) {
		r->root_list = errno == ENOENT ? ENOENT : -1;
		r->root_list_errno = errno;
	} else {
		errno = 0;
		r->root_list = getdents64(fd, buf, sizeof(buf)) < 0 ? errno : 0;
		close(fd);
	}
	_exit(0);
}

static int probe(struct probe_result *out)
{
	struct probe_result *shared;
	pid_t pid;
	int status;

	/* The probe must be a different UID, so results cross the fork through
	 * a MAP_SHARED page rather than the child's private copy. */
	shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE,
		      MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (shared == MAP_FAILED)
		return -1;
	memset(shared, 0, sizeof(*shared));
	pid = fork();
	if (pid < 0)
		return -1;
	if (!pid)
		run_probe(shared);
	if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status))
		return -1;
	*out = *shared;
	munmap(shared, sizeof(*shared));
	return WEXITSTATUS(status);
}

static int publish(unsigned int nr_packages, unsigned long long lease_ms)
{
	struct sv_root_v2 root;
	struct sv_package_v2 pkgs[2];
	struct sv_snapshot_v2 snapshot;

	memset(&root, 0, sizeof(root));
	root.fd = root_fd;
	root.map_id = 0;
	root.nr_ranges = 2;
	root.ranges[0].min = 0;
	root.ranges[0].max = 0;
	root.ranges[1].min = 1000;
	root.ranges[1].max = 1000;

	memset(pkgs, 0, sizeof(pkgs));
	pkgs[0].map_id = 0;
	pkgs[0].uid = APP_UID;
	snprintf(pkgs[0].name, sizeof(pkgs[0].name), "com.example.own");
	pkgs[1].map_id = 0;
	pkgs[1].uid = OTHER_UID;
	snprintf(pkgs[1].name, sizeof(pkgs[1].name), "com.example.other");

	memset(&snapshot, 0, sizeof(snapshot));
	snapshot.version = SV_VERSION_V2;
	snapshot.expected_generation = generation;
	snapshot.nr_roots = 1;
	snapshot.nr_packages = nr_packages;
	snapshot.roots_ptr = (__u64)(uintptr_t)&root;
	snapshot.packages_ptr = nr_packages ? (__u64)(uintptr_t)pkgs : 0;
	snapshot.lease_ms = lease_ms;
	if (ioctl(ctl, SV_IOC_REPLACE_V2, &snapshot)) {
		printf("LEASE publish packages=%u errno=%d (%s)\n", nr_packages,
		       errno, strerror(errno));
		return -1;
	}
	generation++;
	return 0;
}

static void setup(void)
{
	mkdir_p("/proc", 0755);
	mkdir_p("/sys", 0755);
	mkdir_p("/sys/kernel", 0755);
	mkdir_p("/sys/kernel/security", 0755);
	mkdir_p("/fixture", 0755);
	mkdir_p("/dev", 0755);
	if (mount("proc", "/proc", "proc", 0, NULL))
		printf("LEASE mount proc errno=%d\n", errno);
	if (mount("sysfs", "/sys", "sysfs", 0, NULL))
		printf("LEASE mount sysfs errno=%d\n", errno);
	if (mount("securityfs", "/sys/kernel/security", "securityfs", 0, NULL))
		printf("LEASE mount securityfs errno=%d\n", errno);
	if (mount("tmpfs", "/fixture", "tmpfs", MS_NOSUID | MS_NODEV,
		  "mode=0777,size=4m"))
		printf("LEASE mount fixture errno=%d\n", errno);
	mkdir_p(ROOT, 0777);
	chmod(ROOT, 0777);
	mkdir_p(OWN, 0777);
	chmod(OWN, 0777);
	mkdir_p(FOREIGN, 0777);
	chmod(FOREIGN, 0777);
	if (touch(OWN_FILE))
		printf("LEASE touch own errno=%d\n", errno);
	chmod(OWN_FILE, 0666);
	root_fd = open(ROOT, O_PATH | O_DIRECTORY | O_CLOEXEC);
	ctl = open(CONTROL, O_RDWR | O_CLOEXEC);
}

int main(void)
{
	struct probe_result r;

	setup();
	if (ctl < 0 || root_fd < 0) {
		printf("LEASE setup failed ctl=%d root=%d errno=%d\n", ctl, root_fd,
		       errno);
		printf("LEASE RESULT FAIL\n");
		goto out;
	}

	/* T1: healthy policy and healthy lease. */
	if (publish(2, 60000))
		goto out;
	if (probe(&r)) {
		report("T1 probe ran", 0);
		goto out;
	}
	report("T1 own stat", r.own_stat);
	report("T1 own directory open", r.own_open);
	report("T1 own mkdir", r.own_mkdir);
	report("T1 foreign stat is ENOENT", r.foreign_stat == 0);
	report("T1 root listing is denied", r.root_list == ENOENT);
	printf("LEASE T1 detail own_open_errno=%d root_list_errno=%d\n",
	       r.own_open_errno, r.root_list_errno);
	printf("LEASE T1 detail own_open_errno=%d root_list_errno=%d\n",
	       r.own_open_errno, r.root_list_errno);

	/* T2: an explicit roots-only publication still means deny-all. */
	if (publish(0, 60000))
		goto out;
	if (probe(&r))
		goto out;
	report("T2 package-less policy denies own stat", r.own_stat == 0);
	report("T2 package-less policy denies own mkdir", r.own_mkdir == 0);

	/* T3: the controller published, then stopped renewing. */
	if (publish(2, 1000))
		goto out;
	usleep(1500 * 1000);
	if (probe(&r))
		goto out;
	report("T3 expired lease keeps own stat", r.own_stat);
	report("T3 expired lease keeps own open", r.own_open);
	report("T3 expired lease keeps own mkdir", r.own_mkdir);
	report("T3 expired lease stops denying listing", r.root_list == 0);

out:
	printf("LEASE RESULT %s\n", failures ? "FAIL" : "PASS");
	fflush(stdout);
	sync();
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
	return failures ? 1 : 0;
}
