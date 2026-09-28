#!/bin/bash
# Resize the reviewed artwork with macOS tools; image generation is not a build dependency.
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
mkdir -p build
icon_stage="$(mktemp -d "$project_dir/build/icon.XXXXXX")"
trap 'rm -rf -- "$icon_stage"' EXIT
iconset="$icon_stage/AppIcon.iconset"
mkdir "$iconset"
for points in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((points * scale))
        suffix=""
        if [[ "$scale" == 2 ]]; then suffix="@2x"; fi
        sips -s format png -z "$pixels" "$pixels" Resources/AppIcon.png \
            --out "$iconset/icon_${points}x${points}${suffix}.png" >/dev/null
    done
done
iconutil -c icns "$iconset" -o "$icon_stage/AppIcon.icns"
mv "$icon_stage/AppIcon.icns" Resources/AppIcon.icns
printf 'Created Resources/AppIcon.icns (16–1024 px, including Retina sizes).\n'
