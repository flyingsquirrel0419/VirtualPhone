"""Level A tests for the forbidden-file scanner."""
from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "release"))

import forbidden_scan as fs  # noqa: E402

ALLOW = fs.load_allowlist()


class NameRules(unittest.TestCase):
    def test_apple_files_are_caught(self):
        for name in ("iPhone12,1_14.0_Restore.ipsw", "kernelcache.release.iphone12b",
                     "DeviceTree.n104ap.im4p", "sep-firmware.n104.RELEASE.new.img4",
                     "AppleSEPROM-Cebu-B1", "038-44135-124.dmg.trustcache", "root_ticket.der",
                     "dev.mobileprovision", "cert.p12", "root.qcow2", "InfernoData/sep_nvram",
                     "ABCD-1234.mobiledevicepairing", ".env", "CKQEMUBootSplash@2x.png"):
            with self.subTest(name=name):
                self.assertIsNotNone(fs.check_name(name), name)

    def test_ordinary_files_pass(self):
        for name in ("README.md", "app/Sources/App/VirtualPhoneApp.swift", "deps.lock",
                     "docs/GUEST_IMAGE.md", "tools/release/forbidden_scan.py"):
            with self.subTest(name=name):
                self.assertIsNone(fs.check_name(name))


class ContentRules(unittest.TestCase):
    def test_signatures(self):
        cases = {
            b"-----BEGIN PRIVATE KEY-----\nMII": "private key",
            b"0\x82\x10\x00\x16\x04IM4P\x16\x04krnl": "IMG4 payload",
            b"<plist><dict><key>HostPrivateKey</key>": "pairing record",
            b"token=ghp_" + b"a" * 36: "GitHub token",
            b"AKIA" + b"B" * 16: "AWS access key",
        }
        for blob, reason in cases.items():
            with self.subTest(reason=reason):
                self.assertEqual(fs.check_content("some/file", blob), reason)

    def test_clean_text(self):
        self.assertIsNone(fs.check_content("x.swift", b"let x = 1\n"))


class TreeAndArchive(unittest.TestCase):
    def test_tree_scan_finds_disguised_blob(self):
        with tempfile.TemporaryDirectory() as d:
            top = Path(d)
            (top / "ok.txt").write_text("hello")
            (top / "data.bin").write_bytes(b"\x00" * (fs.TREE_SIZE_LIMIT + 1))
            found = fs.scan_tree(top, [])
            self.assertEqual([f.path for f in found], ["data.bin"])
            self.assertEqual(fs.scan_tree(top, ["data.bin"]), [])

    def test_archive_scan(self):
        with tempfile.TemporaryDirectory() as d:
            ipa = Path(d) / "a.ipa"
            with zipfile.ZipFile(ipa, "w") as zf:
                zf.writestr("Payload/VirtualPhone.app/VirtualPhone", b"\x00" * (fs.ARCHIVE_SIZE_LIMIT + 1))
                zf.writestr("Payload/VirtualPhone.app/Info.plist", b"<plist/>")
            self.assertEqual(fs.scan_archive(ipa, ALLOW), [])
            with zipfile.ZipFile(ipa, "a") as zf:
                zf.writestr("Payload/VirtualPhone.app/guest/kernelcache.release.iphone12b", b"x")
                zf.writestr("Payload/VirtualPhone.app/embedded.mobileprovision", b"x")
            reasons = sorted(f.reason for f in fs.scan_archive(ipa, ALLOW))
            self.assertEqual(reasons, ["kernelcache", "provisioning profile"])

    def test_repository_is_clean(self):
        self.assertEqual(fs.scan_tree(ROOT, ALLOW), [])


if __name__ == "__main__":
    unittest.main()
