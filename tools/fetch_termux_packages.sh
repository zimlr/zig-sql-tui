#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
archive="$root/.zig-cache/termux-packages.tar.gz"
destination="$root/.zig-cache/termux-packages"
mkdir -p "$root/.zig-cache"
rm -rf "$destination"
mkdir -p "$destination"
curl --fail --location --silent --show-error \
  https://codeload.github.com/termux/termux-packages/tar.gz/d51f6edc0aa165feb9e13de6b6bbe0d483a4fa7e \
  --output "$archive"
printf '%s  %s\n' 47e80a0cf47daad7e10d657ad2ed18a6d75e4b558b32e5581851508a48076763 "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$destination" --strip-components=1
