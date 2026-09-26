#!/usr/bin/env python3
"""Regenerates the synthetic IPA fixtures for IPAInspectorTests.

    python3 tests/fixtures/ipa/make_fixtures.py

Every file is made up: fake Mach-O headers with a few load commands and filler,
no real app code. Compressed with zlib, so the Swift inflater is tested against
a real DEFLATE encoder (fixed, dynamic and stored blocks).
"""
import plistlib
import struct
import zipfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARM64, X86_64 = 0x0100000C, 0x01000007


def macho(cpu, minos=(14, 0), cryptid=0, filler=40000):
    def ver(v):
        return v[0] << 16 | v[1] << 8
    cmds = struct.pack("<IIIIII", 0x32, 24, 2, ver(minos), ver((14, 5)), 0)   # LC_BUILD_VERSION
    cmds += struct.pack("<IIIIII", 0x2C, 24, 16384, 4096, cryptid, 0)        # LC_ENCRYPTION_INFO_64
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cpu, 0, 2, 2, len(cmds), 0, 0)
    body = bytes((i * 7 + i // 97) % 251 for i in range(filler))              # compressible filler
    return header + cmds + body


def fat(slices, align=0x20000):
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    offsets, blob = [], b""
    offset = align
    for cpu, data in slices:
        offsets.append((cpu, offset, len(data)))
        offset += (len(data) + align - 1) // align * align
    for cpu, off, size in offsets:
        header += struct.pack(">IIIII", cpu, 0, off, size, 14)
    out = bytearray(header.ljust(align, b"\0"))
    for (cpu, data), (_, off, _) in zip(slices, offsets):
        out[len(out):off] = b"\0" * (off - len(out))
        out += data
    return bytes(out)


def info(exe="Demo", minimum="13.0", binary=False):
    d = {"CFBundleIdentifier": "dev.virtualphone.fixture", "CFBundleExecutable": exe,
         "CFBundleShortVersionString": "1.2.3", "CFBundleName": "Fixture"}
    if minimum:
        d["MinimumOSVersion"] = minimum
    return plistlib.dumps(d, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML)


def ipa(name, files, stored=()):
    with zipfile.ZipFile(HERE / name, "w") as z:
        for path, data in files.items():
            method = zipfile.ZIP_STORED if path in stored else zipfile.ZIP_DEFLATED
            z.writestr(zipfile.ZipInfo(path, (2026, 9, 26, 0, 0, 0)), data, compress_type=method, compresslevel=9)


app = "Payload/Demo.app/"
ipa("ok.ipa.zip", {app + "Info.plist": info(), app + "Demo": macho(ARM64), app + "README": b"hello\n"},
    stored={app + "README"})
ipa("encrypted.ipa.zip", {app + "Info.plist": info(binary=True), app + "Demo": macho(ARM64, cryptid=1)})
ipa("x86.ipa.zip", {app + "Info.plist": info(), app + "Demo": macho(X86_64)})
ipa("newer.ipa.zip", {app + "Info.plist": info(minimum="15.0"), app + "Demo": macho(ARM64, (15, 0))})
ipa("fat.ipa.zip", {app + "Info.plist": info(minimum=""),
                    app + "Demo": fat([(X86_64, macho(X86_64)), (ARM64, macho(ARM64, (12, 0)))])})
ipa("twoapps.ipa.zip", {app + "Info.plist": info(), "Payload/Other.app/Info.plist": info()})
ipa("noplist.ipa.zip", {app + "Demo": macho(ARM64)})
ipa("badexe.ipa.zip", {app + "Info.plist": info(), app + "Demo": b"#!/bin/sh\necho not mach-o\n"})
(HERE / "not-a-zip.bin").write_bytes(b"this is not a zip archive at all" * 4)

# Raw DEFLATE vectors: level 0 (stored blocks), level 1 on short text (fixed Huffman).
text = b"VirtualPhone inflate vector. " * 40
for level, name in ((0, "stored"), (1, "fixed")):
    c = zlib.compressobj(level, zlib.DEFLATED, -15)
    (HERE / f"deflate-{name}.bin").write_bytes(c.compress(text if level == 0 else b"abcabcabc hello") + c.flush())
print("fixtures written to", HERE)
