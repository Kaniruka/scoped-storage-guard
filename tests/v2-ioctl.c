// SPDX-License-Identifier: GPL-2.0
/* LD_PRELOAD kernel-boundary fixture; real helper and parser remain in use. */
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <linux/scoped_visibility.h>
static struct sv_info_v2 info = { .version = SV_VERSION_V2 };
int ioctl(int fd, unsigned long request, ...)
{
 va_list ap;
 void *arg;
 (void)fd;
 va_start(ap, request); arg = va_arg(ap, void *); va_end(ap);
 if (getenv("SCV_TEST_V1")) { errno = ENOTTY; return -1; }
 if (request == SV_IOC_GET_INFO_V2) { memcpy(arg, &info, sizeof(info)); return 0; }
 if (request == SV_IOC_REPLACE_V2) {
  struct sv_snapshot_v2 *s = arg;
  struct sv_root_v2 *roots = (void *)(uintptr_t)s->roots_ptr;
  if (s->version != 2 || s->lease_ms < SV_MIN_LEASE_MS ||
      s->lease_ms > SV_MAX_LEASE_MS || s->reserved || s->flags ||
      s->expected_generation != info.generation ||
      (!s->nr_roots && s->roots_ptr) || (!s->nr_packages && s->packages_ptr)) { errno = EINVAL; return -1; }
  info.nr_entries = s->nr_roots; info.nr_packages = s->nr_packages;
  info.flags = SV_INFO_F_CHILD_AWARE; info.generation++;
  info.lease_remaining_ms = s->lease_ms;
  for (unsigned int i = 0; i < s->nr_roots; i++) {
   struct stat st;
   if (fstat(roots[i].fd, &st)) return -1;
   info.objects[i].ino = st.st_ino;
   info.objects[i].dev_major = major(st.st_dev);
   info.objects[i].dev_minor = minor(st.st_dev);
  }
  return 0;
 }
 errno = ENOTTY; return -1;
}
