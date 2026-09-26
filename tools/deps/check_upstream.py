#!/usr/bin/env python3
"""Checks pinned inputs against the outside world. Never modifies deps.lock.

    check_upstream.py tarballs   download every pinned tarball, verify SHA-256
    check_upstream.py drift      Markdown report: pinned commit vs branch head
"""
from __future__ import annotations

import hashlib
import subprocess
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lockfile  # noqa: E402


def sha256_url(url: str) -> str:
    h = hashlib.sha256()
    req = urllib.request.Request(url, headers={"User-Agent": "virtualphone-dependency-check"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        for chunk in iter(lambda: resp.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def tarballs(lock: dict) -> int:
    bad = 0
    for pkg in lock["packages"]:
        ok_url = None
        for url in pkg["urls"]:
            try:
                got = sha256_url(url)
            except Exception as exc:  # network errors of every kind
                print(f"  {pkg['name']}: {url} unreachable: {exc}")
                continue
            if got != pkg["sha256"]:
                print(f"  {pkg['name']}: {url} CHECKSUM MISMATCH {got}")
                bad += 1
                continue
            ok_url = url
            break
        if ok_url:
            print(f"ok   {pkg['name']} {pkg['version']} ({ok_url})")
        else:
            print(f"FAIL {pkg['name']} {pkg['version']}: no mirror served the pinned file")
            bad += 1
    return 1 if bad else 0


def branch_head(repo: str, branch: str) -> str:
    out = subprocess.run(["git", "ls-remote", repo, f"refs/heads/{branch}"],
                         capture_output=True, text=True, timeout=60, check=True).stdout
    return out.split()[0] if out.strip() else "?"


def drift(lock: dict) -> int:
    print("### Upstream drift\n")
    print("| Repository | Branch | Pinned | Head | Status |")
    print("|---|---|---|---|---|")
    for entry in [lock["emulator"], *lock.get("references", [])]:
        try:
            head = branch_head(entry["repository"], entry["branch"])
        except (subprocess.SubprocessError, OSError) as exc:
            head = f"error: {exc}"
        status = "current" if head == entry["commit"] else "upstream moved (update in a dedicated PR)"
        print(f"| {entry['repository']} | {entry['branch']} | `{entry['commit'][:12]}` | `{head[:12]}` | {status} |")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("tarballs", "drift"):
        print(__doc__, file=sys.stderr)
        return 2
    lock = lockfile.load()
    return tarballs(lock) if argv[0] == "tarballs" else drift(lock)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
