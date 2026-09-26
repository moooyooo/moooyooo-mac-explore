#!/usr/bin/env python3
"""Export English/Japanese windows from the debug app's own AppKit views."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=ROOT / ".local/screenshots",
                    help="fresh output directory; existing PNG/JSON files are never overwritten")
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
for language in ("en", "ja"):
    for extension in ("png", "json"):
        if (output / f"workspace-{language}.{extension}").exists():
            parser.error(f"Existing {language} export; choose a fresh --output directory.")

app = ROOT / "build/capture/Moooyooo Mac Explore.app"
environment = {**os.environ, "MACEXPLORE_APP_OUTPUT": str(app)}
subprocess.run(["scripts/build-app.sh", "debug"], cwd=ROOT, env=environment, check=True)
with tempfile.TemporaryDirectory(prefix="MacExplore-", dir="/tmp") as temporary:
    fixture = Path(temporary) / "Demo"
    subprocess.run(["python3", "scripts/create-demo.py", str(fixture)], cwd=ROOT, check=True)
    for language in ("en", "ja"):
        destination = output / f"workspace-{language}.png"
        # Only this newly spawned documentation process is waited on or terminated.
        process = subprocess.Popen([
            str(app / "Contents/MacOS/MacExplore"),
            "--language", language,
            "--project", str(fixture / "Development.mexplore"),
            "--support-directory", str(fixture / "AppState" / language),
            "--capture-window", str(destination),
        ], cwd=ROOT)
        try:
            result = process.wait(timeout=45)
            if result != 0:
                raise RuntimeError(f"{language} capture process failed ({result})")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        metadata = json.loads(destination.with_suffix(".json").read_text())
        assert metadata["language"] == language and metadata["paneCount"] == 2
        assert metadata["pixelWidth"] >= 760 and metadata["pixelHeight"] >= 480
        print(f"{language}: {metadata['pixelWidth']}×{metadata['pixelHeight']} → {destination}")
print("Review both PNGs visually before adding them to public documentation.")
