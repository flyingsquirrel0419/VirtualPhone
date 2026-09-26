#!/usr/bin/env python3
"""Check that an .ipa is structurally what a sideloading tool will accept.

    verify_ipa.py FILE.ipa [--expect-version X.Y.Z] [--require-emulator] [--json]

Verifies: a single Payload/<Name>.app, an Info.plist that parses and names an
executable which exists and is a thin or fat arm64 Mach-O, bundle metadata
(identifier, versions, minimum OS), the emulator dylib when required, and that
no path escapes the archive. Runs on Linux and macOS alike.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import PurePosixPath

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
EMULATOR_DYLIB = "Frameworks/libqemu-aarch64-softmmu.dylib"


class IPAError(Exception):
    pass


def macho_arches(blob: bytes) -> list[int]:
    if len(blob) < 8:
        raise IPAError("executable is truncated")
    (magic_le,) = struct.unpack_from("<I", blob, 0)
    if magic_le == MH_MAGIC_64:
        (cpu,) = struct.unpack_from("<i", blob, 4)
        return [cpu & 0xFFFFFFFF]
    (magic_be,) = struct.unpack_from(">I", blob, 0)
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        (count,) = struct.unpack_from(">I", blob, 4)
        step = 20 if magic_be == FAT_MAGIC else 32
        return [struct.unpack_from(">I", blob, 8 + i * step)[0] for i in range(min(count, 16))]
    raise IPAError(f"executable is not a 64-bit Mach-O (magic 0x{magic_le:08x})")


def inspect(path: str, expect_version: str | None = None, require_emulator: bool = False) -> dict:
    try:
        zf = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as exc:
        raise IPAError(f"not a zip archive: {exc}") from exc

    with zf:
        names = zf.namelist()
        for name in names:
            p = PurePosixPath(name)
            if p.is_absolute() or ".." in p.parts:
                raise IPAError(f"unsafe path in archive: {name}")

        apps = sorted({PurePosixPath(n).parts[1] for n in names
                       if n.startswith("Payload/") and len(PurePosixPath(n).parts) > 2
                       and PurePosixPath(n).parts[1].endswith(".app")})
        if len(apps) != 1:
            raise IPAError(f"expected exactly one Payload/*.app, found {apps or 'none'}")
        app = f"Payload/{apps[0]}"

        try:
            info = plistlib.loads(zf.read(f"{app}/Info.plist"))
        except KeyError as exc:
            raise IPAError("Info.plist missing") from exc
        except Exception as exc:  # plistlib raises several types
            raise IPAError(f"Info.plist does not parse: {exc}") from exc

        for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
                    "CFBundleVersion", "MinimumOSVersion"):
            if not info.get(key):
                raise IPAError(f"Info.plist lacks {key}")

        exe = f"{app}/{info['CFBundleExecutable']}"
        try:
            head = zf.read(exe)[:4096]
        except KeyError as exc:
            raise IPAError(f"executable {exe} missing") from exc
        arches = macho_arches(head)
        if CPU_TYPE_ARM64 not in arches:
            raise IPAError(f"executable has no arm64 slice (cpu types {arches})")

        emulator = f"{app}/{EMULATOR_DYLIB}"
        has_emulator = emulator in names
        if require_emulator:
            if not has_emulator:
                raise IPAError(f"{EMULATOR_DYLIB} missing")
            if CPU_TYPE_ARM64 not in macho_arches(zf.read(emulator)[:4096]):
                raise IPAError("emulator dylib has no arm64 slice")

        signed = any(n.startswith(f"{app}/_CodeSignature/") for n in names)
        version = info["CFBundleShortVersionString"]
        if expect_version and version != expect_version:
            raise IPAError(f"version mismatch: bundle {version}, expected {expect_version}")

        return {
            "app": apps[0],
            "bundle_id": info["CFBundleIdentifier"],
            "executable": info["CFBundleExecutable"],
            "version": version,
            "build": info["CFBundleVersion"],
            "commit": info.get("VPGitCommit", ""),
            "minimum_os": info["MinimumOSVersion"],
            "emulator": has_emulator,
            "signed": signed,
            "files": len(names),
        }


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("ipa")
    ap.add_argument("--expect-version")
    ap.add_argument("--require-emulator", action="store_true")
    ap.add_argument("--require-signature", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    try:
        report = inspect(args.ipa, args.expect_version, args.require_emulator)
        if args.require_signature and not report["signed"]:
            raise IPAError("bundle has no _CodeSignature")
    except IPAError as exc:
        print(f"verify-ipa: FAIL {args.ipa}: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"verify-ipa: OK {report['app']} {report['bundle_id']} "
              f"{report['version']} ({report['build']}) emulator={report['emulator']} signed={report['signed']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
