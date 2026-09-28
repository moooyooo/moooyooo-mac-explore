#!/bin/bash
# Pinned official tools. Private signing keys never come from this download.
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
version=2.10.0
digest=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
folder=".local/vendor/Sparkle-$version"
archive="$folder.tar.xz"
if [[ ! -f "$archive" ]]; then
    mkdir -p .local/vendor
    curl --fail --location --proto '=https' --tlsv1.2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$archive"
fi
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c -
mkdir -p "$folder"
tar -xJf "$archive" -C "$folder" ./bin ./LICENSE
printf 'Tools: %s/bin\n' "$folder"
