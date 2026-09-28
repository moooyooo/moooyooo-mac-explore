#!/usr/bin/env python3
"""Real Sparkle replacement in unique synthetic .apps; no production key or user app."""
from functools import partial
import http.server
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / ".local/vendor/Sparkle-2.10.0/bin"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)


def run(*args, **kwargs):
    return subprocess.check_output([str(a) for a in args], cwd=ROOT, **kwargs)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def scenario(base, binary_dir, mode):
    root = base / mode
    root.mkdir()
    web = root / "web"
    web.mkdir()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(web)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_port
    key = root / "disposable-signing-key"
    public_key = run(binary_dir / "UpdateProbe", "--generate-key", key).decode().strip()
    identifier = "io.github.moooyooo.UpdateProbe." + uuid.uuid4().hex
    app = root / "Installed/UpdateProbe.app"
    newer = root / "New/UpdateProbe.app"
    for path, version in ((app, "1"), (newer, "2")):
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Resources").mkdir()
        shutil.copy2(binary_dir / "UpdateProbe", path / "Contents/MacOS/UpdateProbe")
        run("ditto", binary_dir / "Sparkle.framework", path / "Contents/Frameworks/Sparkle.framework")
        run("ditto", binary_dir / "MacExplore_ExplorerCore.bundle", path / "Contents/Resources/MacExplore_ExplorerCore.bundle")
        info = {
            "CFBundleIdentifier": identifier, "CFBundleName": "UpdateProbe", "CFBundleExecutable": "UpdateProbe",
            "CFBundlePackageType": "APPL", "CFBundleVersion": version, "CFBundleShortVersionString": version + ".0",
            "LSMinimumSystemVersion": "14.0", "NSPrincipalClass": "NSApplication",
            "SUFeedURL": f"http://127.0.0.1:{port}/appcast.xml", "SUPublicEDKey": public_key,
            "SUEnableAutomaticChecks": False, "SUSendProfileInfo": False,
            "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
            "SUSignedFeedFailureExpirationInterval": 0,
            # Loopback HTTP exists only in this disposable test host.
            "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
            "UpdateProbeRoot": str(root),
        }
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        run(ROOT / "scripts/sign-app.sh", path, stderr=subprocess.DEVNULL)
    archive = web / "update.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", newer, archive)
    attributes = run(TOOLS / "sign_update", "--ed-key-file", key, archive).decode()
    enclosure = ET.fromstring(f'<enclosure xmlns:sparkle="{NS}" ' + attributes + "/>")
    if mode == "bad-archive":
        with archive.open("ab") as stream:
            stream.write(b"changed after signing")
    enclosure.set("length", str(archive.stat().st_size))
    enclosure.set("url", f"http://127.0.0.1:{port}/update.zip")
    enclosure.set("type", "application/octet-stream")
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Synthetic update"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "2.0"
    ET.SubElement(item, f"{{{NS}}}version").text = "2"
    ET.SubElement(item, f"{{{NS}}}shortVersionString").text = "2.0"
    ET.SubElement(item, f"{{{NS}}}minimumSystemVersion").text = "14.0"
    item.append(enclosure)
    feed = web / "appcast.xml"
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
    run(TOOLS / "sign_update", "--ed-key-file", key, feed)
    run(binary_dir / "UpdateProbe", "--verify-feed", feed, public_key)
    if mode == "bad-feed":
        feed.write_bytes(feed.read_bytes().replace(b"Synthetic update", b"Untrusted update"))
        result = subprocess.run([str(binary_dir / "UpdateProbe"), "--verify-feed", str(feed), public_key])
        assert result.returncode != 0, "Tampered feed passed public-key validation"
    key.unlink()  # Fixture key is no longer needed; production Keychain is never read.
    log = (root / "probe.log").open("wb")
    process = subprocess.Popen([str(app / "Contents/MacOS/UpdateProbe")], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            if (root / "installed.json").exists() or (root / "failed.json").exists():
                break
            time.sleep(0.2)
        if mode == "valid":
            assert (root / "installed.json").exists(), (root / "probe.log").read_text(errors="replace")
            result = json.loads((root / "installed.json").read_text())
            assert result == {"build": "2", "restored": True}
            assert (root / "busy-deferred.json").exists()
        else:
            assert (root / "failed.json").exists(), (root / "probe.log").read_text(errors="replace")
            assert not (root / "installed.json").exists()
            assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "1"
            result = json.loads((root / "failed.json").read_text())
        process.wait(timeout=10)
        return {"scenario": mode, "passed": True, "result": result}
    finally:
        # Only the exact process this test launched; never terminate MacExplore.
        if process.poll() is None:
            process.kill()
            process.wait()
        log.close()
        server.shutdown()
        server.server_close()
        # The installed fixture exits on its own immediately after its report.
        # Leave helper cleanup to Sparkle; no process-name-wide termination.


def main():
    run(ROOT / "scripts/fetch-sparkle-tools.sh")
    run("swift", "build", "--product", "UpdateProbe")
    binary_dir = Path(run("swift", "build", "--show-bin-path").decode().strip())
    public_key = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["SUPublicEDKey"]
    run(binary_dir / "UpdateProbe", "--verify-feed", ROOT / "updates/appcast.xml", public_key)
    with tempfile.TemporaryDirectory(prefix="MacExplore-updates-") as temp:
        results = [scenario(Path(temp), binary_dir, mode) for mode in ("bad-feed", "bad-archive", "valid")]
    report = ROOT / ".local/update-verification.json"
    report.parent.mkdir(exist_ok=True)
    report.write_text(json.dumps(results, indent=2) + "\n")
    for result in results:
        print(f"{result['scenario']}: passed")
    print("Signed update replacement, busy termination retry, restoration, and tamper rejection passed.")


if __name__ == "__main__":
    main()
