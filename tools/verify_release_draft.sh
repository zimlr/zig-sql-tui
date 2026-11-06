#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 3 ]; then
    echo 'Usage: verify_release_draft.sh TAG ASSET_DIRECTORY DRAFT_JSON' >&2
    exit 2
fi
tag=$1
dir=$2
json=$3
[[ "$tag" =~ ^v[0-9A-Za-z.+-]+$ ]] || { echo 'Invalid release tag.' >&2; exit 1; }
assets=("zsqt-$tag-x86_64-linux-musl.tar.gz" "zsqt-$tag-aarch64-linux-musl.tar.gz" "zsqt-$tag-amd64.deb" "zsqt-$tag-arm64.deb" "zsqt-$tag-aarch64-termux.deb")
jq -e --arg tag "$tag" '.draft == true and .tag_name == $tag and (.assets | length == 6)' "$json" >/dev/null
for name in "${assets[@]}" SHA256SUMS; do
    file="$dir/$name"
    [ -f "$file" ] && [ ! -L "$file" ] || { echo "Missing regular release asset: $name" >&2; exit 1; }
    sum=$(sha256sum -- "$file")
    digest="sha256:${sum%% *}"
    jq -e --arg name "$name" --arg digest "$digest" '[.assets[] | select(.name == $name and .state == "uploaded" and .digest == $digest)] | length == 1' "$json" >/dev/null
done
cmp "$dir/SHA256SUMS" <(cd "$dir" && sha256sum -- "${assets[@]}")
