#!/bin/bash
# Sign nested Sparkle components inside-out. Never use --deep for signing.
set -euo pipefail
app_dir="${1:?Usage: scripts/sign-app.sh APP [IDENTITY]}"
identity="${2:--}"
framework="$app_dir/Contents/Frameworks/Sparkle.framework"
flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then flags+=(--options runtime --timestamp); fi
codesign "${flags[@]}" "$framework/Versions/B/XPCServices/Installer.xpc"
codesign "${flags[@]}" --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
codesign "${flags[@]}" "$framework/Versions/B/Autoupdate"
codesign "${flags[@]}" "$framework/Versions/B/Updater.app"
codesign "${flags[@]}" "$framework"
codesign "${flags[@]}" "$app_dir"
codesign --verify --strict --deep "$app_dir"
