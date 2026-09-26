#!/usr/bin/env python3
"""Policy checks for .github/workflows/*.yml.

Every workflow must parse, declare top-level `permissions` (read-only or
empty), never use `write-all`, run on pinned runners (no *-latest for macOS),
and pin third-party actions to a version. Write permissions are only allowed
on individual jobs.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
USES = re.compile(r"^[\w.-]+/[\w./-]+@[\w.-]+$")


def check(path: Path) -> list[str]:
    problems = []
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        return [f"{path.name}: YAML error: {exc}"]
    if not isinstance(doc, dict):
        return [f"{path.name}: not a mapping"]

    # PyYAML reads the bare key `on` as True.
    if "on" not in doc and True not in doc:
        problems.append(f"{path.name}: no triggers")

    perms = doc.get("permissions")
    if perms is None:
        problems.append(f"{path.name}: top-level permissions must be declared")
    elif perms == "write-all" or (isinstance(perms, dict) and "write" in perms.values()):
        problems.append(f"{path.name}: top-level permissions must be read-only; grant writes per job")

    for name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        if job.get("permissions") == "write-all":
            problems.append(f"{path.name}:{name}: write-all is not allowed")
        runs_on = str(job.get("runs-on", ""))
        if "macos-latest" in runs_on:
            problems.append(f"{path.name}:{name}: pin the macOS runner (not macos-latest)")
        if "timeout-minutes" not in job and "uses" not in job:
            problems.append(f"{path.name}:{name}: set timeout-minutes")
        for step in job.get("steps") or []:
            uses = step.get("uses") if isinstance(step, dict) else None
            if uses and not uses.startswith("./") and not USES.match(uses):
                problems.append(f"{path.name}:{name}: action not pinned: {uses}")
            run = step.get("run", "") if isinstance(step, dict) else ""
            if "secrets." in str(run) and "echo" in str(run):
                problems.append(f"{path.name}:{name}: do not echo secrets in run steps")
    return problems


def main() -> int:
    files = sorted(WORKFLOWS.glob("*.yml"))
    if not files:
        print("no workflows found", file=sys.stderr)
        return 1
    problems = [p for f in files for p in check(f)]
    for p in problems:
        print(p)
    if problems:
        return 1
    print(f"workflows OK: {', '.join(f.name for f in files)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
