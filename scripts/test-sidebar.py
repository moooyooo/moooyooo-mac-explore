#!/usr/bin/env python3
"""Exercise native sidebar mouse events in a disposable debug app and synthetic folders."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    local = root / ".local"
    local.mkdir(exist_ok=True)
    app = local / "sidebar-probe/Mac Explore Sidebar Probe.app"
    if not args.skip_build:
        subprocess.run([str(root / "scripts/build-app.sh"), "debug"], cwd=root,
                       env={**os.environ, "MACEXPLORE_APP_OUTPUT": str(app)}, check=True)
    with tempfile.TemporaryDirectory(prefix="sidebar-", dir=local) as directory:
        fixture = Path(directory)
        report = fixture / "report.json"
        completed = subprocess.run([
            str(app / "Contents/MacOS/MacExplore"), "--language", "ja",
            "--folder", str(fixture), "--support-directory", str(fixture / "support"),
            "--verify-sidebar", str(report),
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=80)
        (local / "sidebar-probe.log").write_bytes(completed.stdout)
        if not report.is_file():
            raise SystemExit("Sidebar probe did not finish; inspect .local/sidebar-probe.log.")
        result = json.loads(report.read_text())
        shutil.copyfile(report, local / "sidebar-verification.json")
        if completed.returncode or not result["passed"]:
            print(json.dumps(result, indent=2))
            raise SystemExit("Sidebar probe failed; report saved under .local.")
        print(f"Sidebar native mouse-event checks passed: {len(result['cases'])} cases.")


if __name__ == "__main__":
    main()
