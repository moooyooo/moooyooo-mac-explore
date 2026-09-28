#!/usr/bin/env python3
"""Check the contents and signature of an already-built app (no network access)."""
import json
import base64
from pathlib import Path
import plistlib
import subprocess
import sys

app = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Moooyooo Mac Explore.app").resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == "io.github.moooyooo.MacExplore"
assert info["CFBundleDevelopmentRegion"] == "en"
assert set(info["CFBundleLocalizations"]) == {"en", "ja"}
assert info["LSMinimumSystemVersion"] == "14.0"
binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
assert binary.is_file()
assert {p.name for p in binary.parent.iterdir()} == {"MacExplore"}, "Unexpected bundled executable"
resources = app / "Contents/Resources"
for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
    assert (resources / name).is_file(), f"Missing {name}"
assert (resources / "Licenses/Sparkle.txt").is_file()
framework = app / "Contents/Frameworks/Sparkle.framework"
assert framework.is_dir()
assert info["SUFeedURL"] == "https://raw.githubusercontent.com/moooyooo/moooyooo-mac-explore/main/updates/appcast.xml"
assert len(base64.b64decode(info["SUPublicEDKey"], validate=True)) == 32
assert info["SUVerifyUpdateBeforeExtraction"] is True
assert info["SURequireSignedFeed"] is True
assert info["SUSignedFeedFailureExpirationInterval"] == 0
assert info["SUSendProfileInfo"] is False
assert info["SUEnableAutomaticChecks"] is False
assert info["SUAutomaticallyUpdate"] is False
assert "NSAppTransportSecurity" not in info, "Test HTTP exceptions must not ship"
assert int(info["CFBundleVersion"]) > 0
sparkle_info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
assert sparkle_info["CFBundleShortVersionString"] == "2.10.0"
libraries = subprocess.check_output(["otool", "-L", str(binary)], text=True)
assert "@rpath/Sparkle.framework/Versions/B/Sparkle" in libraries
load_commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
assert "@executable_path/../Frameworks" in load_commands
bundle = resources / "MacExplore_ExplorerCore.bundle"
for language in ("en", "ja"):
    for name in ("Localizable.strings", "Localizable.stringsdict"):
        path = bundle / (language + ".lproj") / name
        subprocess.run(["plutil", "-lint", str(path)], check=True, stdout=subprocess.DEVNULL)
    assert (resources / (language + ".lproj") / "InfoPlist.strings").is_file()
    catalog = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(bundle / (language + ".lproj/Localizable.strings"))
    ]))
    assert catalog["menuFile"] == {"en": "File", "ja": "ファイル"}[language]
# Avoid shipping the developer's home/build path (including SwiftPM's generated fallback).
strings = subprocess.check_output(["strings", str(binary)])
assert b"/Users/" not in strings and b"/home/" not in strings, "Developer path found in release executable"
assert all(flag not in strings for flag in (b"--capture-window", b"--capture-dark")), \
    "Documentation capture commands must not ship in a release executable"
subprocess.run(["codesign", "--verify", "--strict", "--deep", str(app)], check=True)
architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
print(f"App verified: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), {architectures}, en/ja, bundled licenses.")
