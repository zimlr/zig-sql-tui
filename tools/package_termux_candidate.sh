#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p "${TMPDIR:-$root/.zig-cache/tmp}"
(cd .zig-cache/candidate && sha256sum -c SHA256SUMS)
bash tools/fetch_termux_packages.sh
package_dir=.zig-cache/termux-packages/packages/zsqt
mkdir -p "$package_dir" .zig-cache/packages .zig-cache/unpacked
cp tests/termux/build.sh "$package_dir/build.sh"
if [ -n "${ZSQT_TERMUX_VERSION:-}" ]; then
    version="${ZSQT_TERMUX_VERSION#v}"
    sed -i "s/^TERMUX_PKG_VERSION=.*/TERMUX_PKG_VERSION=\"$version\"/" "$package_dir/build.sh"
fi
cp .zig-cache/candidate/zsqt "$package_dir/zsqt"
(cd .zig-cache/termux-packages && ./build-package.sh -f -s -a aarch64 -o "$root/.zig-cache/packages" zsqt)
shopt -s nullglob
package=(.zig-cache/packages/zsqt_*_aarch64.deb)
test "${#package[@]}" = 1
test "$(dpkg-deb -f "${package[0]}" Architecture)" = aarch64
if [ -n "${ZSQT_TERMUX_DEB_OUT:-}" ]; then
    mkdir -p "$(dirname "$ZSQT_TERMUX_DEB_OUT")"
    cp "${package[0]}" "$ZSQT_TERMUX_DEB_OUT"
fi
dpkg-deb -x "${package[0]}" .zig-cache/unpacked
packaged=.zig-cache/unpacked/data/data/com.termux/files/usr/bin/zsqt
cmp .zig-cache/candidate/zsqt "$packaged"
mkdir -p .zig-cache/packaged-binary
cp "$packaged" .zig-cache/packaged-binary/zsqt
(cd .zig-cache/packaged-binary && sha256sum zsqt > SHA256SUMS)
