#!/usr/bin/env python3
"""Prepare a reviewed, notarized archive and signed appcast. Does not publish."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "moooyooo/moooyooo-mac-explore"
ACCOUNT = REPOSITORY
TOOLS = ROOT / ".local/vendor/Sparkle-2.10.0/bin"
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(*args, **kwargs):
    return subprocess.check_output([str(a) for a in args], cwd=ROOT, **kwargs)


def check_zip(path):
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or ".." in name.parts:
                raise ValueError("Archive contains a path outside its app.")
            if entry.external_attr >> 16 & 0o170000 == 0o120000:
                target = archive.read(entry).decode("utf-8")
                resolved = posixpath.normpath(str(name.parent / target))
                if target.startswith("/") or not resolved.startswith(name.parts[0] + "/"):
                    raise ValueError("Archive contains an escaping symlink.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="The ZIP produced by package-release.sh --notarize")
    args = parser.parse_args()
    archive = args.archive.resolve()
    if "-dev" in archive.name or archive.suffix != ".zip":
        raise SystemExit("Only a notarized release ZIP may enter the public update feed.")
    if run("git", "status", "--porcelain").strip():
        raise SystemExit("Commit reviewed changes before preparing a public update.")
    remote = run("git", "remote", "get-url", "origin").decode().strip()
    if remote not in (f"https://github.com/{REPOSITORY}.git", f"git@github.com:{REPOSITORY}.git"):
        raise SystemExit("The release repository must be moooyooo/moooyooo-mac-explore.")
    check_zip(archive)
    run(ROOT / "scripts/fetch-sparkle-tools.sh")
    source_info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    public_key = run(TOOLS / "generate_keys", "--account", ACCOUNT, "-p").decode().strip()
    if public_key != source_info["SUPublicEDKey"]:
        raise SystemExit("The moooyooo signing account does not match SUPublicEDKey.")
    # Uses a public-key verifier; signing material never enters the repository.
    run("swift", "build", "--product", "UpdateProbe")
    run(ROOT / ".build/debug/UpdateProbe", "--verify-feed", ROOT / "updates/appcast.xml", public_key)
    with tempfile.TemporaryDirectory(prefix="macexplore-release-") as temporary:
        stage = Path(temporary)
        run("ditto", "-x", "-k", archive, stage)
        apps = list(stage.glob("*.app"))
        if len(apps) != 1:
            raise SystemExit("Expected exactly one application.")
        app = apps[0]
        run("python3", ROOT / "scripts/verify-app.py", app)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if any(info[key] != source_info[key] for key in
               ("CFBundleVersion", "CFBundleShortVersionString", "SUPublicEDKey", "SUFeedURL")):
            raise SystemExit("The archive does not match this release checkout.")
        identity = run("codesign", "-d", "--verbose=4", app, stderr=subprocess.STDOUT).decode()
        if "Authority=Developer ID Application:" not in identity or "flags=0x10000(runtime)" not in identity:
            raise SystemExit("Developer ID signing and Hardened Runtime are required.")
        run("xcrun", "stapler", "validate", app)
        run("spctl", "--assess", "--type", "execute", app)
        version = info["CFBundleShortVersionString"]
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise SystemExit("Use a stable numeric semantic version.")
        build = int(info["CFBundleVersion"])
        old = ET.parse(ROOT / "updates/appcast.xml")
        if any(build <= int(item.findtext(NS + "version", default="0"))
               for item in old.findall("./channel/item")):
            raise SystemExit("CFBundleVersion must increase beyond every published update.")
        output = ROOT / "dist" / ("update-v" + version)
        output.mkdir(parents=True, exist_ok=False)
        shutil.copy2(archive, output / archive.name)
        shutil.copy2(ROOT / "updates/appcast.xml", output / "appcast.xml")
        prefix = f"https://github.com/{REPOSITORY}/releases/download/v{version}/"
        run(TOOLS / "generate_appcast", "--account", ACCOUNT, "--maximum-deltas", "0",
            "--download-url-prefix", prefix, "--link", f"https://github.com/{REPOSITORY}", output)
        run(TOOLS / "sign_update", "--account", ACCOUNT, output / "appcast.xml")
        run(ROOT / ".build/debug/UpdateProbe", "--verify-feed", output / "appcast.xml", public_key)
        items = ET.parse(output / "appcast.xml").findall("./channel/item")
        latest = [item for item in items if item.findtext(NS + "version") == str(build)]
        if len(latest) != 1 or latest[0].find("enclosure").get("url") != prefix + archive.name:
            raise SystemExit("Generated feed does not point at the intended GitHub release asset.")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (output / (archive.stem + ".sha256")).write_text(f"{digest}  {archive.name}\n")
        print(f"Prepared dist/update-v{version}. Nothing has been published.")
        print("Publish and verify the release asset first; commit the signed appcast afterward.")


if __name__ == "__main__":
    main()
