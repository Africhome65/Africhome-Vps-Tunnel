#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("render_reality_backend", ROOT / "scripts/render-reality-backend.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def sample_config():
    return {
        "inbounds": [
            {"listen": "0.0.0.0", "port": 8443, "protocol": "vmess",
             "streamSettings": {"network": "ws", "security": "tls"}},
            {"listen": "0.0.0.0", "port": 443, "protocol": "vless",
             "settings": {"clients": [{"id": "test-uuid", "flow": "xtls-rprx-vision"}]},
             "streamSettings": {"network": "raw", "security": "reality",
                                "realitySettings": {"dest": "origin.example:443",
                                                    "serverNames": ["origin.example"],
                                                    "privateKey": "test-private",
                                                    "shortIds": ["12345678"]}}},
        ],
        "outbounds": [{"protocol": "freedom", "tag": "direct"}],
    }


class RealityBackendRendererTests(unittest.TestCase):
    def test_changes_only_reality_listener_and_preserves_protocol_settings(self):
        source = sample_config()
        rendered = MODULE.render(source)
        self.assertEqual(rendered["inbounds"][0], source["inbounds"][0])
        self.assertEqual(rendered["inbounds"][1]["listen"], "127.0.0.1")
        self.assertEqual(rendered["inbounds"][1]["port"], 1443)
        self.assertEqual(rendered["inbounds"][1]["settings"], source["inbounds"][1]["settings"])
        self.assertEqual(rendered["inbounds"][1]["streamSettings"], source["inbounds"][1]["streamSettings"])
        self.assertEqual(rendered["outbounds"], source["outbounds"])
        self.assertEqual(source["inbounds"][1]["port"], 443)

    def test_custom_backend_port(self):
        rendered = MODULE.render(sample_config(), 2443)
        self.assertEqual(rendered["inbounds"][1]["port"], 2443)

    def test_rejects_existing_backend_port_collision(self):
        source = sample_config()
        source["inbounds"][0]["port"] = 1443
        with self.assertRaisesRegex(ValueError, "already used"):
            MODULE.render(source)

    def test_requires_exactly_one_vless_reality_inbound(self):
        source = sample_config()
        source["inbounds"].pop()
        with self.assertRaisesRegex(ValueError, "found 0"):
            MODULE.render(source)
        source = sample_config()
        source["inbounds"].append(dict(source["inbounds"][1]))
        with self.assertRaisesRegex(ValueError, "found 2"):
            MODULE.render(source)

    def test_rejects_invalid_backend_ports(self):
        for port in (True, 0, 80, 65536, "1443"):
            with self.subTest(port=port), self.assertRaises(ValueError):
                MODULE.render(sample_config(), port)

    def test_source_file_is_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            original = json.dumps(sample_config())
            path.write_text(original, encoding="utf-8")
            MODULE.load_config(str(path))
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_rejects_symlink_source(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target.json"
            target.write_text(json.dumps(sample_config()), encoding="utf-8")
            link = Path(directory) / "link.json"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                MODULE.load_config(str(link))


if __name__ == "__main__":
    unittest.main()
