#!/usr/bin/env python3
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("update_reality_sni", ROOT / "scripts/update-reality-sni.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RealitySniUpdateTests(unittest.TestCase):
    def fixture(self):
        return {
            "inbounds": [
                {"protocol": "vmess", "port": 8443, "streamSettings": {"security": "tls"}},
                {"protocol": "vless", "port": 443, "streamSettings": {
                    "security": "reality", "realitySettings": {"serverNames": ["origin.example"]}
                }},
            ],
            "outbounds": [{"protocol": "freedom"}],
        }

    def test_updates_only_reality_and_preserves_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(self.fixture()), encoding="utf-8")
            path.chmod(0o640)
            MODULE.update(str(path), "NEW.example.com")
            result = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(result["inbounds"][0]["streamSettings"]["security"], "tls")
            names = result["inbounds"][1]["streamSettings"]["realitySettings"]["serverNames"]
            self.assertEqual(names, ["origin.example", "new.example.com"])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
            self.assertTrue(path.read_text(encoding="utf-8").endswith("\n"))

    def test_duplicate_is_idempotent_case_insensitive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(self.fixture()), encoding="utf-8")
            MODULE.update(str(path), "ORIGIN.example")
            result = json.loads(path.read_text(encoding="utf-8"))
            names = result["inbounds"][1]["streamSettings"]["realitySettings"]["serverNames"]
            self.assertEqual(names, ["origin.example"])

    def test_rejects_invalid_hostname_without_modifying_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            original = json.dumps(self.fixture())
            path.write_text(original, encoding="utf-8")
            with self.assertRaises(ValueError):
                MODULE.update(str(path), "-bad.example")
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_rejects_overlong_dns_label(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            original = json.dumps(self.fixture())
            path.write_text(original, encoding="utf-8")
            with self.assertRaises(ValueError):
                MODULE.update(str(path), ("a" * 64) + ".example")
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_rejects_overlong_dns_name(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            original = json.dumps(self.fixture())
            path.write_text(original, encoding="utf-8")
            long_name = ".".join(["a" * 63] * 4)
            with self.assertRaises(ValueError):
                MODULE.update(str(path), long_name)
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_requires_exactly_one_reality_inbound(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            config = {"inbounds": []}
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaises(ValueError):
                MODULE.update(str(path), "new.example")
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), config)

    def test_rejects_symlink_config(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target.json"
            target.write_text(json.dumps(self.fixture()), encoding="utf-8")
            link = Path(directory) / "link.json"
            link.symlink_to(target)
            with self.assertRaises(ValueError):
                MODULE.update(str(link), "new.example")
            self.assertEqual(json.loads(target.read_text(encoding="utf-8")), self.fixture())


if __name__ == "__main__":
    unittest.main()
