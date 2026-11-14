# Scoped Storage Guard - portable helper build.
#
# Sources are self-contained; nothing here refers to a personal checkout.
# KERNEL headers are vendored under include/uapi and never read from a tree.

CC ?= cc
AARCH64_CC ?= aarch64-linux-gnu-gcc
CFLAGS ?= -O2 -Wall -Wextra
CPPFLAGS ?= -Iinclude/uapi
REPRO := -Wl,--build-id=none -ffile-prefix-map=$(CURDIR)=.
OUT := out
HELPERS := src/svreg.c src/svctl.c src/sv_parse.c

.PHONY: all host arm64 test module clean check smoke

all: host

host: $(OUT)/svreg $(OUT)/svctl

arm64: $(OUT)/svreg.arm64 $(OUT)/svctl.arm64

$(OUT):
	mkdir -p $(OUT)

$(OUT)/svreg: $(HELPERS) src/sv_parse.h include/uapi/linux/scoped_visibility.h | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(REPRO) -o $@ src/svreg.c src/sv_parse.c

$(OUT)/svctl: $(HELPERS) src/sv_parse.h include/uapi/linux/scoped_visibility.h | $(OUT)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(REPRO) -o $@ src/svctl.c src/sv_parse.c

$(OUT)/svreg.arm64: $(HELPERS) src/sv_parse.h include/uapi/linux/scoped_visibility.h | $(OUT)
	$(AARCH64_CC) $(CPPFLAGS) $(CFLAGS) $(REPRO) -static -o $@ src/svreg.c src/sv_parse.c

$(OUT)/svctl.arm64: $(HELPERS) src/sv_parse.h include/uapi/linux/scoped_visibility.h | $(OUT)
	$(AARCH64_CC) $(CPPFLAGS) $(CFLAGS) $(REPRO) -static -o $@ src/svctl.c src/sv_parse.c

test: host
	bash tests/selftest.sh
	bash tests/installer.sh
	bash tests/u32.sh
	bash tests/resolver.sh
	bash tests/host-svreg.sh

module: arm64 host
	bash build.sh

check:
	@sh -n module/post-fs-data.sh && sh -n module/service.sh && sh -n module/action.sh
	@sh -n module/uninstall.sh && sh -n module/customize.sh
	@sh -n module/bin/autostart.sh && sh -n module/bin/scvctl.sh
	@sh -n module/bin/scv-resolve.sh && sh -n module/bin/scv-prop.sh
	@echo "shell syntax: ok"

clean:
	rm -rf $(OUT) build
smoke: arm64
	KERNEL_IMAGE="$(KERNEL_IMAGE)" bash tests/vm/run-qemu.sh
