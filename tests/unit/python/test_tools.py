"""Level A tests for the release tooling: lockfile, IPA verifier."""
from __future__ import annotations

import copy
import io
import json
import plistlib
import struct
import sys
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "deps"))
sys.path.insert(0, str(ROOT / "tools" / "ipa"))

import lockfile  # noqa: E402
import verify_ipa  # noqa: E402

ARM64_MACHO = struct.pack("<Ii", verify_ipa.MH_MAGIC_64, verify_ipa.CPU_TYPE_ARM64) + b"\0" * 64
X86_MACHO = struct.pack("<Ii", verify_ipa.MH_MAGIC_64, 0x01000007) + b"\0" * 64


def make_ipa(path: Path, *, info: dict | None = None, exe: bytes = ARM64_MACHO,
             extra: dict[str, bytes] | None = None, app: str = "VirtualPhone.app") -> Path:
    plist = {
        "CFBundleIdentifier": "dev.virtualphone.app",
        "CFBundleExecutable": "VirtualPhone",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "MinimumOSVersion": "16.0",
        "VPGitCommit": "abc1234",
    }
    if info is not None:
        plist.update(info)
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(f"Payload/{app}/Info.plist", plistlib.dumps(plist))
        zf.writestr(f"Payload/{app}/VirtualPhone", exe)
        zf.writestr(f"Payload/{app}/_CodeSignature/CodeResources", b"<plist/>")
        for name, blob in (extra or {}).items():
            zf.writestr(name, blob)
    return path


class LockfileTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads((ROOT / "deps.lock").read_text())

    def test_repository_lock_is_valid(self):
        lockfile.validate(self.data)

    def test_branch_instead_of_sha_is_rejected(self):
        bad = copy.deepcopy(self.data)
        bad["emulator"]["commit"] = "ios"
        with self.assertRaises(lockfile.LockError):
            lockfile.validate(bad)

    def test_latest_runner_is_rejected(self):
        bad = copy.deepcopy(self.data)
        bad["toolchain"]["runner"] = "macos-latest"
        with self.assertRaises(lockfile.LockError):
            lockfile.validate(bad)

    def test_bad_checksum_and_duplicates(self):
        bad = copy.deepcopy(self.data)
        bad["packages"][0]["sha256"] = "deadbeef"
        with self.assertRaises(lockfile.LockError):
            lockfile.validate(bad)
        dup = copy.deepcopy(self.data)
        dup["packages"].append(copy.deepcopy(dup["packages"][0]))
        with self.assertRaises(lockfile.LockError):
            lockfile.validate(dup)

    def test_plain_http_url_is_rejected(self):
        bad = copy.deepcopy(self.data)
        bad["packages"][0]["urls"] = ["http://example.com/x.tar.gz"]
        with self.assertRaises(lockfile.LockError):
            lockfile.validate(bad)

    def test_digest_is_stable_and_sensitive(self):
        a = lockfile.digest(self.data)
        self.assertEqual(a, lockfile.digest(copy.deepcopy(self.data)))
        changed = copy.deepcopy(self.data)
        changed["packages"][0]["version"] = "9.9.9"
        self.assertNotEqual(a, lockfile.digest(changed))
        cosmetic = copy.deepcopy(self.data)
        cosmetic["comment"] = "different"
        self.assertEqual(a, lockfile.digest(cosmetic))

    def test_get(self):
        self.assertEqual(lockfile.get(self.data, "toolchain.arch"), "arm64")
        with self.assertRaises(lockfile.LockError):
            lockfile.get(self.data, "toolchain.nope")


class VerifyIPATests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = Path(tempfile.mkdtemp())

    def test_valid_ipa(self):
        report = verify_ipa.inspect(str(make_ipa(self.tmp / "ok.ipa")), expect_version="0.1.0")
        self.assertEqual(report["executable"], "VirtualPhone")
        self.assertEqual(report["commit"], "abc1234")
        self.assertTrue(report["signed"])
        self.assertFalse(report["emulator"])

    def test_emulator_required(self):
        ipa = make_ipa(self.tmp / "noemu.ipa")
        with self.assertRaisesRegex(verify_ipa.IPAError, "missing"):
            verify_ipa.inspect(str(ipa), require_emulator=True)
        ok = make_ipa(self.tmp / "emu.ipa", extra={
            "Payload/VirtualPhone.app/Frameworks/libqemu-aarch64-softmmu.dylib": ARM64_MACHO})
        self.assertTrue(verify_ipa.inspect(str(ok), require_emulator=True)["emulator"])

    def test_wrong_arch(self):
        with self.assertRaisesRegex(verify_ipa.IPAError, "arm64"):
            verify_ipa.inspect(str(make_ipa(self.tmp / "x86.ipa", exe=X86_MACHO)))

    def test_fat_binary_with_arm64(self):
        fat = struct.pack(">II", verify_ipa.FAT_MAGIC, 1) + struct.pack(">IIIII", verify_ipa.CPU_TYPE_ARM64, 0, 0, 0, 0)
        verify_ipa.inspect(str(make_ipa(self.tmp / "fat.ipa", exe=fat)))

    def test_missing_executable_and_keys(self):
        with self.assertRaisesRegex(verify_ipa.IPAError, "lacks"):
            verify_ipa.inspect(str(make_ipa(self.tmp / "k.ipa", info={"CFBundleVersion": ""})))
        with self.assertRaisesRegex(verify_ipa.IPAError, "missing"):
            verify_ipa.inspect(str(make_ipa(self.tmp / "e.ipa", info={"CFBundleExecutable": "Nope"})))

    def test_version_mismatch(self):
        with self.assertRaisesRegex(verify_ipa.IPAError, "mismatch"):
            verify_ipa.inspect(str(make_ipa(self.tmp / "v.ipa")), expect_version="0.2.0")

    def test_unsafe_path_and_two_apps(self):
        with self.assertRaisesRegex(verify_ipa.IPAError, "unsafe"):
            verify_ipa.inspect(str(make_ipa(self.tmp / "u.ipa", extra={"../evil": b"x"})))
        with self.assertRaisesRegex(verify_ipa.IPAError, "exactly one"):
            verify_ipa.inspect(str(make_ipa(self.tmp / "two.ipa", extra={"Payload/Other.app/Info.plist": b"x"})))

    def test_not_a_zip(self):
        bad = self.tmp / "bad.ipa"
        bad.write_bytes(b"not a zip")
        with self.assertRaises(verify_ipa.IPAError):
            verify_ipa.inspect(str(bad))


if __name__ == "__main__":
    unittest.main()
