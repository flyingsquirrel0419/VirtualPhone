#!/usr/bin/env python3
"""Prints an SPDX 2.3 JSON SBOM for the IPA, from deps.lock and VERSION.

Lists what goes into the shipped binary: the app itself, the emulator at its
pinned commit, and every dependency tarball with its checksum and licence.
"""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "deps"))
import lockfile  # noqa: E402


def spdx_id(name: str) -> str:
    return "SPDXRef-" + "".join(c if c.isalnum() or c in ".-" else "-" for c in name)


def build(lock: dict, version: str, commit: str, created: str) -> dict:
    emu = lock["emulator"]
    packages = [
        {
            "SPDXID": spdx_id("VirtualPhone"),
            "name": "VirtualPhone",
            "versionInfo": version,
            "downloadLocation": "NOASSERTION",
            "licenseConcluded": "GPL-3.0-or-later",
            "licenseDeclared": "GPL-3.0-or-later",
            "copyrightText": "NOASSERTION",
            "externalRefs": [{"referenceCategory": "OTHER", "referenceType": "git-commit", "referenceLocator": commit}],
        },
        {
            "SPDXID": spdx_id(emu["name"]),
            "name": emu["name"],
            "versionInfo": emu["commit"],
            "downloadLocation": f"git+{emu['repository']}@{emu['commit']}",
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "GPL-3.0-only AND AGPL-3.0-or-later",
            "licenseComments": emu.get("license", ""),
            "copyrightText": "NOASSERTION",
        },
    ]
    for pkg in lock["packages"]:
        packages.append({
            "SPDXID": spdx_id(pkg["name"]),
            "name": pkg["name"],
            "versionInfo": pkg["version"],
            "downloadLocation": pkg["urls"][0],
            "checksums": [{"algorithm": "SHA256", "checksumValue": pkg["sha256"]}],
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": pkg["license"],
            "copyrightText": "NOASSERTION",
        })
    root = packages[0]["SPDXID"]
    relationships = [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": root}]
    relationships += [{"spdxElementId": root, "relationshipType": "CONTAINS", "relatedSpdxElement": p["SPDXID"]}
                      for p in packages[1:]]
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"VirtualPhone-{version}",
        "documentNamespace": f"https://github.com/virtualphone/sbom/{version}/{commit}",
        "creationInfo": {"created": created, "creators": ["Tool: tools/release/sbom.py"]},
        "packages": packages,
        "relationships": relationships,
    }


def main() -> int:
    lock = lockfile.load()
    version = (ROOT / "VERSION").read_text().strip()
    try:
        commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True,
                                text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        commit = "unknown"
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    json.dump(build(lock, version, commit, created), sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
