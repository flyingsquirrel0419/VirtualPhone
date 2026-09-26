#!/usr/bin/env python3
"""Read and validate deps.lock.

    lockfile.py validate [PATH]          exit non-zero on a malformed lock
    lockfile.py get KEY [PATH]           print one dotted value (emulator.commit)
    lockfile.py packages [PATH]          one line per package: name file sha256 url...
    lockfile.py subprojects [PATH]       one line per meson subproject: name commit
    lockfile.py hash [PATH]              stable digest of all pinned inputs (cache key)
    lockfile.py deps-hash [PATH]         digest of what the iOS dependency prefix depends on

Shell scripts use this instead of parsing JSON themselves.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT = ROOT / "deps.lock"

SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
NAME = re.compile(r"^[a-z0-9][a-z0-9._+-]*$")


class LockError(ValueError):
    pass


def load(path: Path = DEFAULT) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise LockError(f"{path}: {exc}") from exc
    validate(data)
    return data


def validate(data: dict) -> None:
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise LockError("schema must be 1")

    emu = data.get("emulator")
    if not isinstance(emu, dict):
        raise LockError("missing emulator section")
    for key in ("repository", "branch", "commit"):
        if not isinstance(emu.get(key), str) or not emu[key]:
            raise LockError(f"emulator.{key} is required")
    if not SHA1.match(emu["commit"]):
        raise LockError("emulator.commit must be a full 40-char SHA, not a branch")
    if not emu["repository"].startswith("https://"):
        raise LockError("emulator.repository must be an https URL")

    names = set()
    for sub in data.get("subprojects", []):
        if not NAME.match(sub.get("name", "")) or sub["name"] in names:
            raise LockError(f"bad or duplicate subproject: {sub.get('name')!r}")
        names.add(sub["name"])
        if not SHA1.match(sub.get("commit", "")):
            raise LockError(f"subproject {sub['name']}: commit must be a full SHA")
        if not sub.get("repository", "").startswith("https://") or not sub.get("license"):
            raise LockError(f"subproject {sub['name']}: https repository and license are required")

    for ref in data.get("references", []):
        if not SHA1.match(ref.get("commit", "")):
            raise LockError(f"reference {ref.get('name')}: commit must be a full SHA")

    tool = data.get("toolchain", {})
    for key in ("runner", "xcode", "ios_deployment_target", "arch"):
        if not tool.get(key):
            raise LockError(f"toolchain.{key} is required")
    if tool["runner"] in ("macos-latest", "latest"):
        raise LockError("toolchain.runner must be pinned, not latest")

    pkgs = data.get("packages")
    if not isinstance(pkgs, list) or not pkgs:
        raise LockError("packages must be a non-empty list")
    seen = set()
    for pkg in pkgs:
        name = pkg.get("name", "")
        if not NAME.match(name):
            raise LockError(f"bad package name: {name!r}")
        if name in seen:
            raise LockError(f"duplicate package: {name}")
        seen.add(name)
        if not SHA256.match(pkg.get("sha256", "")):
            raise LockError(f"{name}: sha256 must be 64 lowercase hex chars")
        for key in ("version", "license", "file"):
            if not pkg.get(key):
                raise LockError(f"{name}: {key} is required")
        if "/" in pkg["file"] or pkg["file"].startswith("."):
            raise LockError(f"{name}: file must be a bare file name")
        urls = pkg.get("urls")
        if not urls or not all(isinstance(u, str) and u.startswith("https://") for u in urls):
            raise LockError(f"{name}: urls must be a non-empty list of https URLs")


def get(data: dict, dotted: str):
    node = data
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            raise LockError(f"no such key: {dotted}")
        node = node[part]
    return node


def digest(data: dict, keys: tuple[str, ...] = ("emulator", "subprojects", "toolchain", "packages")) -> str:
    pinned = {k: data.get(k) for k in keys}
    blob = json.dumps(pinned, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest()


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "get":
            if not rest:
                raise LockError("get needs a key")
            data = load(Path(rest[1]) if len(rest) > 1 else DEFAULT)
            print(get(data, rest[0]))
            return 0
        data = load(Path(rest[0]) if rest else DEFAULT)
        if cmd == "validate":
            print(f"deps.lock OK: {len(data['packages'])} packages, emulator {data['emulator']['commit'][:12]}")
        elif cmd == "packages":
            for pkg in data["packages"]:
                print(" ".join([pkg["name"], pkg["file"], pkg["sha256"], *pkg["urls"]]))
        elif cmd == "subprojects":
            for sub in data.get("subprojects", []):
                print(sub["name"], sub["commit"])
        elif cmd == "hash":
            print(digest(data))
        elif cmd == "deps-hash":
            print(digest(data, ("toolchain", "packages")))
        else:
            print(f"unknown command: {cmd}", file=sys.stderr)
            return 2
    except LockError as exc:
        print(f"deps.lock: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
