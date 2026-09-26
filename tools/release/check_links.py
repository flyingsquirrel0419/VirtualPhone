#!/usr/bin/env python3
"""Checks that relative links in tracked Markdown files point at files that exist.

External (http/https/mailto) links are not fetched: CI stays offline-safe and
fast. Anchors are stripped; only the file part is checked.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
FENCE = re.compile(r"```.*?```", re.S)


def markdown_files() -> list[Path]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--cached", "--others",
                          "--exclude-standard", "*.md"], capture_output=True, text=True, check=True)
    return [ROOT / p for p in out.stdout.split() if p]


def main() -> int:
    broken = []
    for md in markdown_files():
        text = FENCE.sub("", md.read_text(encoding="utf-8"))
        for target in LINK.findall(text):
            if re.match(r"^[a-z]+:", target) or target.startswith("#"):
                continue
            path = target.split("#", 1)[0]
            if not path:
                continue
            resolved = (md.parent / path).resolve()
            if not resolved.exists():
                broken.append(f"{md.relative_to(ROOT)}: {target}")
    for b in broken:
        print(f"broken link: {b}")
    if broken:
        return 1
    print("links OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
