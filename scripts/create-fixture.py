#!/usr/bin/env python3
"""Create synthetic browsing data without touching an existing directory."""

import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
parser.add_argument("--count", type=int, default=1000)
args = parser.parse_args()
if args.count < 10:
    parser.error("--count must be at least 10")
destination = args.destination.resolve()
if destination.exists():
    parser.error("destination already exists; choose a new directory")
destination.mkdir(parents=True)
for name in ["資料", "画像", "出力", "Sources", "Archive", "Notes", "Shared", "Review", "Drafts", "Examples"]:
    folder = destination / name
    folder.mkdir()
    (folder / "example.txt").write_text("Synthetic browsing fixture.\n", encoding="utf-8")
for index in range(args.count - 10):
    (destination / f"Sample {index + 1:05d}.txt").write_text("Synthetic browsing fixture.\n", encoding="utf-8")
(destination / ".hidden-example").write_text("Hidden fixture.\n", encoding="utf-8")
print(f"Created {args.count} visible items and one hidden item in {destination}")
