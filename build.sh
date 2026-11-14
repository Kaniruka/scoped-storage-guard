#!/bin/bash
# Stage the KernelSU module and produce a reproducible zip from source.
# Requires aarch64-linux-gnu-gcc (helpers are static aarch64) and zip.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"
VER=$(sed -n 's/^version=//p' module/module.prop)
EPOCH=${SOURCE_DATE_EPOCH:-$(date -u -d 2026-11-14T00:00:00Z +%s 2>/dev/null || echo 1794614400)}
STAGE=build/stage
ZIP="$HERE/build/scoped-storage-guard-$VER.zip"

echo "== build helpers"
make -s arm64

echo "== stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/config" "$STAGE/src" \
	"$STAGE/include/uapi/linux" "$STAGE/LICENSES"

cp -a module/. "$STAGE/"
mkdir -p "$STAGE/config"
cp -a config/scv.conf "$STAGE/config/scv.conf"
cp -a "$HERE/out/svreg.arm64" "$STAGE/bin/svreg"
cp -a "$HERE/out/svctl.arm64" "$STAGE/bin/svctl"
cp -a src/sv_parse.c src/sv_parse.h src/svreg.c src/svctl.c "$STAGE/src/"
cp -a include/uapi/linux/scoped_visibility.h "$STAGE/include/uapi/linux/"
cp -a README.md NOTICE.md CHANGELOG.md LICENSE "$STAGE/"
cp -a LICENSES/Linux-syscall-note "$STAGE/LICENSES/Linux-syscall-note"

chmod 0755 "$STAGE/post-fs-data.sh" "$STAGE/service.sh" "$STAGE/action.sh" \
	"$STAGE/uninstall.sh" "$STAGE/customize.sh" \
	"$STAGE/bin/autostart.sh" "$STAGE/bin/scvctl.sh" \
	"$STAGE/bin/scv-resolve.sh" "$STAGE/bin/scv-prop.sh" \
	"$STAGE/bin/svreg" "$STAGE/bin/svctl"
chmod 0600 "$STAGE/config/scv.conf"
chmod 0644 "$STAGE/module.prop" "$STAGE/skip_mount" "$STAGE/README.md" \
	"$STAGE/NOTICE.md" "$STAGE/CHANGELOG.md" "$STAGE/LICENSE"

echo "== manifest"
(
	cd "$STAGE"
	printf '# Scoped Storage Guard %s\n' "$VER"
	printf '# kernel interface commit 881d7ebcd59d5736a1155e562da61367649322af\n'
	printf '# CONFIG_SECURITY_SCOPED_VISIBILITY=y CONFIG_SECURITYFS=y\n'
	find . -type f | LC_ALL=C sort | while IFS= read -r f; do
		printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
	done
) >build/MANIFEST.txt

echo "== zip"
find "$STAGE" -exec touch -h -d "@$EPOCH" {} +
rm -f "$ZIP"
( cd "$STAGE" && zip -X -q -r "$ZIP" . )
sha256sum "$ZIP" | tee build/ZIP.sha256
echo "   $(du -h "$ZIP" | cut -f1)  $ZIP"
