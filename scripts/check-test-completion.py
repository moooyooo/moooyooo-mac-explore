#!/usr/bin/env python3
"""Reject a Swift Testing process that exits successfully before its final total."""
import re
import sys
from pathlib import Path


def completed(output: str) -> bool:
    return re.search(r"Test run with \d+ tests?\b[^\n]* passed after [^\n]*\.", output) is not None


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-test-completion.py TEST_LOG")
    if not completed(Path(sys.argv[1]).read_text(errors="replace")):
        raise SystemExit(
            "Incomplete Swift Testing run: no successful final total was printed. "
            "Exit status 0 alone is insufficient. "
            "see docs/p5-verification.md."
        )
