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
parser.add_argument("--appearance", choices=("light", "dark", "both"), default="both")
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
appearances = ("light", "dark") if args.appearance == "both" else (args.appearance,)
captures = [(language, appearance, f"workspace-{language}" + ("-dark" if appearance == "dark" else ""))
            for appearance in appearances for language in ("en", "ja")]
for language, appearance, name in captures:
    for extension in ("png", "json"):
        if (output / f"{name}.{extension}").exists():
            parser.error(f"Existing {name} export; choose a fresh --output directory.")

app = ROOT / "build/capture/Moooyooo Mac Explore.app"
environment = {**os.environ, "MACEXPLORE_APP_OUTPUT": str(app)}
subprocess.run(["scripts/build-app.sh", "debug"], cwd=ROOT, env=environment, check=True)
with tempfile.TemporaryDirectory(prefix="MacExplore-", dir="/tmp") as temporary:
    fixture = Path(temporary) / "Demo"
    subprocess.run(["python3", "scripts/create-demo.py", str(fixture)], cwd=ROOT, check=True)
    for language, appearance, name in captures:
        destination = output / f"{name}.png"
        # Only this newly spawned documentation process is waited on or terminated.
        process = subprocess.Popen([
            str(app / "Contents/MacOS/MacExplore"),
            "--language", language,
            "--project", str(fixture / "Development.mexplore"),
            "--support-directory", str(fixture / "AppState" / f"{language}-{appearance}"),
            "--capture-window", str(destination),
        ] + (["--capture-dark"] if appearance == "dark" else []), cwd=ROOT)
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
        assert metadata["appearance"] == ("darkAqua" if appearance == "dark" else "aqua")
        assert metadata["pixelWidth"] >= 760 and metadata["pixelHeight"] >= 480
        print(f"{language}/{appearance}: {metadata['pixelWidth']}×{metadata['pixelHeight']} → {destination}")
print("Review all PNGs visually before adding them to public documentation.")
