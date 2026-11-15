// SPDX-License-Identifier: GPL-2.0
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sv_parse.h"
static void check(const char *path, const char *text, int good, unsigned int nr)
{
 struct sv_policy_v2 *p = calloc(1, sizeof(*p));
 char err[512];
 FILE *f = fopen(path, "w");
 assert(p && f);
 assert(fputs(text, f) >= 0);
 assert(!fclose(f));
 assert((sv_load_policy_v2(path, p, err, sizeof(err)) == 0) == good);
 if (good) {
  assert(p->header.nr_packages == nr);
  assert(p->header.nr_roots == 1);
  assert(!!p->header.packages_ptr == !!nr);
 }
 sv_close_policy_v2(p);
 free(p);
}
int main(int argc, char **argv)
{
 char path[4096], root[4096], text[8192];
 assert(argc == 2);
 _Static_assert(sizeof(struct sv_snapshot_v2) == 56, "v2 snapshot ABI");
 _Static_assert(sizeof(struct sv_root_v2) == 144, "v2 root ABI");
 _Static_assert(sizeof(struct sv_package_v2) == 264, "v2 package ABI");
 _Static_assert(sizeof(struct sv_info_v2) == 544, "v2 info ABI");
 snprintf(path, sizeof(path), "%s/policy", argv[1]);
 snprintf(root, sizeof(root), "root\t%s\t0\t0-0,1000-1000\n", argv[1]);
 check(path, root, 1, 0);
 snprintf(text, sizeof(text), "%spackage\t0\t10001\tcom.example.one\npackage\t0\t10001\tcom.example.two\n", root);
 check(path, text, 1, 2);
 const char *bad[] = {
  "package\t0\t10001\t../escape\n", "package\t0\t010001\tcom.example.one\n",
  "package\t0\t4294967295\tcom.example.one\n", "package\t1\t10001\tcom.example.one\n",
  "package\t0\t10001\tcom..example\n", "package\t0\t10001\tcom/example\n",
  "package\t0\t10001\tcom.example\npackage\t0\t10002\tcom.example\n"
 };
 for (unsigned int i = 0; i < sizeof(bad)/sizeof(bad[0]); i++) {
  snprintf(text, sizeof(text), "%s%s", root, bad[i]); check(path, text, 0, 0);
 }
 puts("v2 parser: 10 cases and ABI sizes passed");
 return 0;
}
