#!/bin/bash
# Local packaging is the default. --notarize explicitly uploads a signed copy to Apple.
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
mode="${1:---development}"
case "$mode" in
    --development) suffix="-dev" ;;
    --notarize)
        : "${MACEXPLORE_SIGN_IDENTITY:?Set a Developer ID Application identity}"
        : "${MACEXPLORE_NOTARY_PROFILE:?Set a notarytool Keychain profile name}"
        case "$MACEXPLORE_SIGN_IDENTITY" in
            "Developer ID Application: "*) ;;
            *) echo "A Developer ID Application identity is required." >&2; exit 2 ;;
        esac
        if [[ -n "$(git status --porcelain)" ]]; then
            echo "Commit reviewed changes before creating a notarized release." >&2
            exit 2
        fi
        suffix=""
        ;;
    *) echo "Usage: scripts/package-release.sh [--development|--notarize]" >&2; exit 2 ;;
esac

python3 scripts/check-localizations.py
MACEXPLORE_APP_OUTPUT="$project_dir/build/Moooyooo Mac Explore.app" scripts/build-app.sh release
app_dir="$project_dir/build/Moooyooo Mac Explore.app"
python3 scripts/verify-app.py "$app_dir"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
architecture="$(lipo -archs "$app_dir/Contents/MacOS/MacExplore")"
case "$architecture" in arm64|x86_64) ;; *) echo "Expected a native, single-architecture build." >&2; exit 2 ;; esac
name="Moooyooo-Mac-Explore-$version-$architecture$suffix"
mkdir -p dist
if [[ -e "dist/$name.zip" || -e "dist/$name.sha256" || -e "dist/$name.build.txt" ]]; then
    echo "dist/$name already exists. Move the previous artifacts before packaging again." >&2
    exit 2
fi
stage="$(mktemp -d "$project_dir/build/release-stage.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
staged_app="$stage/Moooyooo Mac Explore.app"
ditto "$app_dir" "$staged_app"

if [[ "$mode" == "--notarize" ]]; then
    # No nested executables or external frameworks are bundled; do not use --deep signing.
    codesign --force --options runtime --timestamp --sign "$MACEXPLORE_SIGN_IDENTITY" "$staged_app"
    codesign --verify --strict --verbose=2 "$staged_app"
    ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$stage/submission.zip"
    mkdir -p .local/notarization
    report="$project_dir/.local/notarization/$name.json"
    xcrun notarytool submit "$stage/submission.zip" --keychain-profile "$MACEXPLORE_NOTARY_PROFILE" \
        --wait --timeout 20m --output-format json > "$report"
    python3 - "$report" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get("status") != "Accepted":
    raise SystemExit("Notarization was not accepted. Review the report in .local/notarization.")
PY
    xcrun stapler staple "$staged_app"
    xcrun stapler validate "$staged_app"
    spctl --assess --type execute --verbose=2 "$staged_app"
fi

# Repackage after stapling, then verify the exact archived copy.
ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$stage/$name.zip"
mkdir "$stage/extracted"
ditto -x -k "$stage/$name.zip" "$stage/extracted"
python3 scripts/verify-app.py "$stage/extracted/Moooyooo Mac Explore.app"
if [[ "$mode" == "--notarize" ]]; then
    xcrun stapler validate "$stage/extracted/Moooyooo Mac Explore.app"
fi
mv "$stage/$name.zip" "dist/$name.zip"
(
    cd dist
    shasum -a 256 "$name.zip" > "$name.sha256"
)
{
    printf 'version=%s\narchitecture=%s\nmode=%s\ncommit=%s\n' "$version" "$architecture" "$mode" "$(git rev-parse HEAD)"
    if [[ -n "$(git status --porcelain)" ]]; then printf 'source_state=dirty\n'; else printf 'source_state=clean\n'; fi
    swift --version
    sw_vers
} > "dist/$name.build.txt"
printf 'Created dist/%s.zip and SHA-256/build metadata.\n' "$name"
