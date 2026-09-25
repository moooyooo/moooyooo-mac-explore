#!/usr/bin/env python3
"""Measure a running process's CPU-time delta; one logical core is 100%."""

import argparse
import json
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("pid", type=int)
parser.add_argument("--seconds", type=float, default=60)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if args.pid <= 0 or args.seconds <= 0:
    parser.error("pid and seconds must be positive")


def cpu_seconds():
    value = subprocess.check_output(["ps", "-p", str(args.pid), "-o", "time="], text=True).strip()
    parts = value.split(":")
    result = 0.0
    for part in parts:
        result = result * 60 + float(part)
    return result


start = time.monotonic()
before = cpu_seconds()
time.sleep(args.seconds)
after = cpu_seconds()
elapsed = time.monotonic() - start
result = {
    "pid": args.pid,
    "elapsedSeconds": elapsed,
    "cpuSeconds": after - before,
    "cpuPercent": (after - before) / elapsed * 100,
}
args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result))
