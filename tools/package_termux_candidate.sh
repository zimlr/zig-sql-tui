#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
(cd .zig-cache/candidate && sha256sum -c SHA256SUMS)
bash tools/fetch_termux_packages.sh
package_dir=.zig-cache/termux-packages/packages/zig-sql-tui
mkdir -p "$package_dir" .zig-cache/packages .zig-cache/unpacked
cp tests/termux/build.sh "$package_dir/build.sh"
cp .zig-cache/candidate/zig-sql-tui "$package_dir/zig-sql-tui"
(cd .zig-cache/termux-packages && ./build-package.sh -f -s -a aarch64 -o "$root/.zig-cache/packages" zig-sql-tui)
shopt -s nullglob
package=(.zig-cache/packages/zig-sql-tui_*_aarch64.deb)
test "${#package[@]}" = 1
dpkg-deb -x "${package[0]}" .zig-cache/unpacked
packaged=.zig-cache/unpacked/bin/zig-sql-tui
cmp .zig-cache/candidate/zig-sql-tui "$packaged"
mkdir -p .zig-cache/packaged-binary
cp "$packaged" .zig-cache/packaged-binary/zig-sql-tui
(cd .zig-cache/packaged-binary && sha256sum zig-sql-tui > SHA256SUMS)
