#!/bin/bash
# Owns a disposable 128 MiB APFS image. Never fills or unmounts an existing volume.
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
volume="/private/tmp/MacExplore-Transfer-Test"
if [[ -e "$volume" ]]; then
    echo "Refusing to reuse $volume. Unmount the prior test image first." >&2
    exit 2
fi
mkdir -p .local
image_dir="$(mktemp -d "$project_dir/.local/volume-test.XXXXXX")"
image="$image_dir/test.dmg"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        if ! hdiutil detach "$volume" -quiet; then
            echo "Test image remains mounted at $volume; retained $image" >&2
            return
        fi
    fi
    echo "Test image retained at $image"
}
trap cleanup EXIT
hdiutil create -size 128m -fs APFS -volname MacExplore-Transfer-Test "$image"
hdiutil attach -nobrowse -mountpoint "$volume" "$image"
mounted=true
MACEXPLORE_TEST_VOLUME="$volume" scripts/test.sh --filter VolumeOperationTests
