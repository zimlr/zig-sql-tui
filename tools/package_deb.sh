#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo 'Usage: package_deb.sh SEMVER_TAG ARCH BINARY OUTPUT.deb' >&2
    exit 2
fi
tag=$1
arch=$2
binary=$3
output=$4
case "$arch" in
    amd64) machine='Advanced Micro Devices X86-64' ;;
    arm64) machine='AArch64' ;;
    *) echo 'Unsupported Debian architecture.' >&2; exit 1 ;;
esac
version_tool=${ZSQT_DEB_VERSION_TOOL:-zig-out/tools/deb-version}
version=$("$version_tool" "$tag")
if [ ! -f "$binary" ] || [ -L "$binary" ] || [ -e "$output" ] || [ -L "$output" ]; then
    echo 'Input must be a regular file and output must not exist.' >&2
    exit 1
fi
header=$(LC_ALL=C readelf -h "$binary")
programs=$(LC_ALL=C readelf -l "$binary")
dynamic=$(LC_ALL=C readelf -d "$binary")
grep -Eq "Machine:[[:space:]]+$machine$" <<< "$header"
grep -Eq 'Type:[[:space:]]+DYN' <<< "$header"
if grep -q INTERP <<< "$programs" || grep -q '(NEEDED)' <<< "$dynamic"; then
    echo 'The package requires a static PIE executable.' >&2
    exit 1
fi
mkdir -p .zig-cache/tmp
stage=$(mktemp -d .zig-cache/tmp/zsqt-deb-XXXXXXXX)
trap 'rm -rf -- "$stage"' EXIT
chmod 755 "$stage"
mkdir -p "$stage/DEBIAN" "$stage/usr/bin" "$stage/usr/share/bash-completion/completions" \
    "$stage/usr/share/zsh/site-functions" "$stage/usr/share/fish/vendor_completions.d" \
    "$stage/usr/share/doc/zsqt/docs" "$stage/usr/share/doc/zsqt/assets"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: zsqt
Version: $version
Architecture: $arch
Maintainer: zsqt maintainers
Section: utils
Priority: optional
Homepage: https://github.com/zimlr/zsqt
X-Zsqt-Release: $tag
Description: keyboard-first terminal interface for SQLite
 Browse and edit SQLite databases with a terminal user interface.
CONTROL
install -m 755 "$binary" "$stage/usr/bin/zsqt"
install -m 644 completions/zsqt.bash "$stage/usr/share/bash-completion/completions/zsqt"
install -m 644 completions/_zsqt "$stage/usr/share/zsh/site-functions/_zsqt"
install -m 644 completions/zsqt.fish "$stage/usr/share/fish/vendor_completions.d/zsqt.fish"
install -m 644 README.md RELEASING.md DEPENDENCIES.md TESTING.md SECURITY.md "$stage/usr/share/doc/zsqt/"
install -m 644 docs/building.md docs/limitations.md "$stage/usr/share/doc/zsqt/docs/"
install -m 644 assets/zsqt-logo.png "$stage/usr/share/doc/zsqt/assets/"
install -m 644 vendor/sqlite/LICENSE.md "$stage/usr/share/doc/zsqt/SQLITE-LICENSE.md"
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}
find "$stage" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --root-owner-group -Zxz --build "$stage" "$output"
