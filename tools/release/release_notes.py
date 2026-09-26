#!/usr/bin/env python3
"""Prints the release notes for VERSION: its CHANGELOG.md section plus the
standing notices every release carries.

    release_notes.py 0.1.0
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

FOOTER = """
---
**Requirements:** a JIT enabler (see docs/JIT.md) and your own guest files prepared from
your own IPSW (see docs/GUEST_IMAGE.md). This release contains **no** Apple firmware,
IPSW, kernelcache, DeviceTree, SEP firmware or keys.

**Assets:** the ad-hoc signed `.ipa` (re-sign it with your sideloading tool),
`SHA256SUMS`, and `SBOM.spdx.json`. Source for the GPL/AGPL components is in this
repository at the tagged commit and in the emulator repository at the commit
recorded in `deps.lock`.
"""


def section(changelog: str, version: str) -> str | None:
    pattern = re.compile(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", re.S | re.M)
    m = pattern.search(changelog)
    return m.group(1).strip() if m else None


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    body = section((ROOT / "CHANGELOG.md").read_text(), argv[0])
    if body is None:
        print(f"CHANGELOG.md has no section for {argv[0]}", file=sys.stderr)
        return 1
    print(body)
    print(FOOTER)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
