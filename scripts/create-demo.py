#!/usr/bin/env python3
"""Create a fresh synthetic workspace; never overwrite an existing directory."""
import argparse
import json
from pathlib import Path
import uuid
import os
from datetime import datetime, timezone

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path, help="new directory, e.g. /tmp/MacExplore-Demo")
args = parser.parse_args()
root = args.destination.expanduser().absolute()
root.mkdir(parents=True, exist_ok=False)
files = {
    "Source/App/main.swift": '// Synthetic demo file\nprint("Hello, Explorer")\n',
    "Source/Tests/README.md": "# Example tests\n\nSynthetic files for the demo.\n",
    "Source/Package.swift": "// Example package; not a buildable project.\n",
    "Source/README.md": "# Example Project\n\nAll contents are synthetic.\n",
    "Documents/Design.md": "# Workspace design\n\nTwo Explorer panes, one saved project.\n",
    "Documents/Release Notes.md": "# Release notes\n\nEnglish and Japanese interface.\n",
    "Documents/Checklist.txt": "Browse\nArrange\nSave project\n",
    "Output/summary.csv": "category,count\nsource,4\ndocuments,3\n",
}
for relative, contents in files.items():
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)

panes = []
for index, folder in enumerate(("Source", "Documents")):
    identifier = str(uuid.uuid4()).upper()
    panes.append({
        "id": identifier,
        "folder": {"url": (root / folder).as_uri() + "/"},
        "normalFrame": {"x": index * 0.5, "y": 0, "width": 0.5, "height": 1},
        "presentation": "normal",
        "settings": {
            "columns": [{"column": key, "width": width} for key, width in
                        (("name", 162), ("modified", 140), ("kind", 98), ("size", 80))],
            "sortColumn": "name", "ascending": True, "showHidden": False, "filter": "",
            "treeWidth": 140, "expandedDirectories": [],
            "favorites": [(root / folder).as_uri() + "/"],
        },
    })
document = {
    "schemaVersion": 1, "projectID": str(uuid.uuid4()).upper(), "revision": str(uuid.uuid4()).upper(),
    "name": "Development", "windowFrame": {"x": 80, "y": 100, "width": 1440, "height": 820},
    "panes": panes, "zOrder": [pane["id"] for pane in reversed(panes)], "activePaneID": panes[0]["id"],
}
project = root / "Development.mexplore"
project.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
# Stable, synthetic dates keep language comparisons and documentation repeatable.
timestamp = datetime(2026, 9, 25, 9, 0, tzinfo=timezone.utc).timestamp()
for path in sorted(root.rglob("*"), key=lambda value: len(value.parts), reverse=True):
    os.utime(path, (timestamp, timestamp))
print(project)
