#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
configuration="${1:-release}"
case "$configuration" in
    debug|release) ;;
    *) echo "Usage: scripts/build-app.sh [debug|release]" >&2; exit 2 ;;
esac

swift build --configuration "$configuration" --product MacExplore
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
app_dir="$project_dir/build/Moooyooo Mac Explore.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/MacExplore" "$app_dir/Contents/MacOS/MacExplore.new"
mv -f "$app_dir/Contents/MacOS/MacExplore.new" "$app_dir/Contents/MacOS/MacExplore"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
plutil -lint "$app_dir/Contents/Info.plist"
# Local ad-hoc signing only. Developer ID signing/notarization belongs to the release workflow.
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
