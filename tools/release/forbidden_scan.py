#!/usr/bin/env python3
"""Refuse Apple proprietary files, signing material and secrets.

    forbidden_scan.py tree [DIR]     scan a working tree (git-tracked files when DIR is a repo)
    forbidden_scan.py archive FILE   scan every member of a .zip/.ipa

Exit status 1 when anything is found. Checks names, content signatures, and
size (large binaries that are not on the allowlist are treated as suspect: a
guest image or firmware blob does not have to be named honestly to be one).
"""
from __future__ import annotations

import fnmatch
import re
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = Path(__file__).with_name("forbidden-allowlist.txt")

# Name patterns, matched case-insensitively against the base name.
NAME_RULES: list[tuple[str, str]] = [
    ("*.ipsw", "Apple IPSW"),
    ("kernelcache*", "kernelcache"),
    ("*.kernelcache", "kernelcache"),
    ("devicetree*.im4p", "DeviceTree"),
    ("devicetree*.img4", "DeviceTree"),
    ("devicetree.*ap*", "DeviceTree"),
    ("sep-firmware*", "SEP firmware"),
    ("applesep*", "AppleSEPROM"),
    ("*seprom*", "AppleSEPROM"),
    ("*.im4p", "IMG4 payload"),
    ("*.img4", "IMG4 container"),
    ("*.im4m", "IMG4 manifest"),
    ("*.trustcache", "trust cache"),
    ("root_ticket.der", "APTicket"),
    ("*.shsh*", "SHSH blob"),
    ("*.mobileprovision", "provisioning profile"),
    ("*.provisionprofile", "provisioning profile"),
    ("*.p12", "PKCS#12 bundle"),
    ("*.pfx", "PKCS#12 bundle"),
    ("*.mobiledevicepairing", "pairing record"),
    ("*.pairing", "pairing record"),
    ("*.qcow2", "guest disk image"),
    ("*.vmdk", "guest disk image"),
    ("*.dmg", "disk image"),
    ("*.img", "disk image"),
    ("*.aea", "Apple encrypted archive"),
    ("sep_nvram", "guest SEP state"),
    ("sep_ssc", "guest SEP state"),
    ("effaceable", "guest effaceable storage"),
    ("syscfg", "guest syscfg"),
    ("ctrl_bits", "guest ctrl_bits"),
    (".env", "environment file"),
    ("*.env", "environment file"),
    ("id_rsa", "SSH private key"),
    ("id_ed25519", "SSH private key"),
    # Not redistributable in derivative builds (ui/icons/CKBrandingNotice.md upstream).
    ("ckqemubootsplash*", "ChefKiss branding artwork"),
]

# Byte signatures looked for in the first 64 KiB.
CONTENT_RULES: list[tuple[re.Pattern[bytes], str]] = [
    (re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"), "private key"),
    (re.compile(rb"\x16\x04IM4P"), "IMG4 payload"),
    (re.compile(rb"\x16\x04IMG4"), "IMG4 container"),
    (re.compile(rb"\x16\x04IM4M"), "IMG4 manifest"),
    (re.compile(rb"<key>HostPrivateKey</key>"), "pairing record"),
    (re.compile(rb"<key>EscrowBag</key>"), "pairing record"),
    (re.compile(rb"<key>ProvisionedDevices</key>"), "provisioning profile"),
    (re.compile(rb"__PRELINK_INFO"), "kernelcache"),
    (re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{36,}\b"), "GitHub token"),
    (re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{60,}\b"), "GitHub token"),
    (re.compile(rb"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "Slack token"),
]

# Files that are allowed to mention the signatures above (this scanner, its tests).
CONTENT_EXEMPT = {
    "tools/release/forbidden_scan.py",
    "tests/unit/python/test_forbidden_scan.py",
}

TREE_SIZE_LIMIT = 1 * 1024 * 1024
ARCHIVE_SIZE_LIMIT = 4 * 1024 * 1024
HEAD = 64 * 1024


@dataclass(frozen=True)
class Finding:
    path: str
    reason: str

    def __str__(self) -> str:
        return f"FORBIDDEN {self.path}: {self.reason}"


def load_allowlist(path: Path = ALLOWLIST) -> list[str]:
    if not path.exists():
        return []
    lines = (line.split("#", 1)[0].strip() for line in path.read_text().splitlines())
    return [line for line in lines if line]


def allowed(rel: str, allow: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(rel, pat) for pat in allow)


def check_name(rel: str) -> str | None:
    base = rel.rsplit("/", 1)[-1].lower()
    for pattern, reason in NAME_RULES:
        if fnmatch.fnmatchcase(base, pattern):
            return reason
    return None


def check_content(rel: str, head: bytes) -> str | None:
    if rel in CONTENT_EXEMPT:
        return None
    for pattern, reason in CONTENT_RULES:
        if pattern.search(head):
            return reason
    return None


def is_binary(head: bytes) -> bool:
    return b"\x00" in head[:8192]


def scan_entry(rel: str, size: int, head: bytes, limit: int, allow: list[str]) -> list[Finding]:
    if allowed(rel, allow):
        return []
    found = []
    reason = check_name(rel)
    if reason:
        found.append(Finding(rel, reason))
    reason = check_content(rel, head)
    if reason:
        found.append(Finding(rel, reason))
    if size > limit and (is_binary(head) or not head):
        found.append(Finding(rel, f"large unknown binary ({size} bytes); allowlist it if legitimate"))
    return found


def tree_files(top: Path) -> list[Path]:
    try:
        out = subprocess.run(
            ["git", "-C", str(top), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            check=True, capture_output=True,
        ).stdout
        return [top / p for p in out.decode().split("\0") if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return [p for p in top.rglob("*") if p.is_file() and ".git" not in p.parts]


def scan_tree(top: Path, allow: list[str]) -> list[Finding]:
    found: list[Finding] = []
    for path in tree_files(top):
        if not path.is_file():
            continue
        rel = path.relative_to(top).as_posix()
        with path.open("rb") as fh:
            head = fh.read(HEAD)
        found += scan_entry(rel, path.stat().st_size, head, TREE_SIZE_LIMIT, allow)
    return found


def scan_archive(archive: Path, allow: list[str]) -> list[Finding]:
    found: list[Finding] = []
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            with zf.open(info) as fh:
                head = fh.read(HEAD)
            found += scan_entry(info.filename, info.file_size, head, ARCHIVE_SIZE_LIMIT, allow)
    return found


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("tree", "archive"):
        print(__doc__, file=sys.stderr)
        return 2
    allow = load_allowlist()
    if argv[0] == "tree":
        top = Path(argv[1]) if len(argv) > 1 else ROOT
        found = scan_tree(top.resolve(), allow)
        what = str(top)
    else:
        if len(argv) < 2:
            print("archive needs a file", file=sys.stderr)
            return 2
        found = scan_archive(Path(argv[1]), allow)
        what = argv[1]
    for item in found:
        print(item)
    if found:
        print(f"forbidden-scan: {len(found)} finding(s) in {what}", file=sys.stderr)
        return 1
    print(f"forbidden-scan: clean ({what})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
