// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal QEMU fixture init: mount the pseudo filesystems, then exercise the
 * real helpers against a real scoped_visibility control node.
 *
 * Expectations:
 *   svctl status            -> exit 0 (this is the success path the module's
 *                              installer and supervisor depend on)
 *   svreg apply 0 /empty    -> exit 0, PUBLISHED generation=1 count=0
 *   svctl status            -> exit 0, generation=1 count=0
 *
 * No FUSE/F2FS object exists in this guest, so per-entry acceptance is out of
 * scope here and remains covered by the host/offline tests.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define CONTROL "/sys/kernel/security/scoped_visibility/control"

static int failures;

static void mkdir_p(const char *path)
{
	if (mkdir(path, 0755) && errno != EEXIST)
		printf("SMOKE mkdir %s errno=%d\n", path, errno);
}

static int run_capture(char *const argv[], char *buf, size_t size)
{
	int fds[2];
	pid_t pid;
	int status;
	ssize_t n;
	size_t used = 0;

	buf[0] = 0;
	if (pipe(fds))
		return 127;
	pid = fork();
	if (pid < 0)
		return 127;
	if (!pid) {
		close(fds[0]);
		dup2(fds[1], 1);
		dup2(fds[1], 2);
		close(fds[1]);
		execv(argv[0], argv);
		_exit(126);
	}
	close(fds[1]);
	while ((n = read(fds[0], buf + used, size - 1 - used)) > 0) {
		used += (size_t)n;
		if (used >= size - 1)
			break;
	}
	buf[used] = 0;
	close(fds[0]);
	if (waitpid(pid, &status, 0) != pid)
		return 127;
	if (!WIFEXITED(status))
		return 128;
	return WEXITSTATUS(status);
}

static void expect(const char *name, char *const argv[], int want,
		   char *capture, const char *needle)
{
	int rc = run_capture(argv, capture, 4096);

	printf("SMOKE %s rc=%d want=%d %s\n", name, rc, want,
	       rc == want ? "ok" : "FAIL");
	printf("SMOKE %s output: %s\n", name, capture);
	if (rc != want)
		failures++;
	if (needle && !strstr(capture, needle)) {
		printf("SMOKE %s missing=[%s] FAIL\n", name, needle);
		failures++;
	}
}

int main(void)
{
	char capture[4096];
	static char empty[] = "/empty";
	int fd;
	char *status[] = { "/svctl", "status", NULL };
	char *apply[] = { "/svreg", "apply", "0", empty, NULL };

	mkdir_p("/proc");
	mkdir_p("/sys");
	mkdir_p("/sys/kernel");
	mkdir_p("/sys/kernel/security");
	if (mount("proc", "/proc", "proc", 0, NULL))
		printf("SMOKE mount proc errno=%d\n", errno);
	if (mount("sysfs", "/sys", "sysfs", 0, NULL))
		printf("SMOKE mount sysfs errno=%d\n", errno);
	if (mount("securityfs", "/sys/kernel/security", "securityfs", 0, NULL)) {
		printf("SMOKE mount securityfs errno=%d FAIL\n", errno);
		failures++;
	}
	if (access(CONTROL, R_OK | W_OK)) {
		printf("SMOKE control absent errno=%d FAIL\n", errno);
		failures++;
	} else {
		printf("SMOKE control present\n");
	}

	fd = open(empty, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) {
		printf("SMOKE create empty errno=%d FAIL\n", errno);
		failures++;
	} else {
		close(fd);
	}

	if (!failures) {
		expect("status_before", status, 0, capture, "generation=");
		expect("apply_empty", apply, 0, capture,
		       "PUBLISHED generation=1 count=0");
		expect("status_after", status, 0, capture,
		       "generation=1 count=0");
	}

	printf("SMOKE RESULT %s\n", failures ? "FAIL" : "PASS");
	fflush(stdout);
	sync();
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
	return failures ? 1 : 0;
}
