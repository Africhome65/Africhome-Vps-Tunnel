#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "render-vmess-shared-443.py"
SPEC = importlib.util.spec_from_file_location("vmess_shared_443", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class VmessShared443Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.cert = self.root / "fullchain.pem"
        self.key = self.root / "privkey.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(self.key), "-out", str(self.cert),
            "-subj", "/CN=vmess.example.com",
            "-addext", "subjectAltName=DNS:vmess.example.com",
            "-days", "1",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.config = {
            "inbounds": [
                {
                    "tag": "vless-reality",
                    "listen": "0.0.0.0",
                    "port": 443,
                    "protocol": "vless",
                    "settings": {"clients": []},
                    "streamSettings": {
                        "network": "tcp",
                        "security": "reality",
                        "realitySettings": {
                            "serverNames": ["reality.example.net", "www.example.org"],
                            "privateKey": "not-a-real-test-key",
                        },
                    },
                },
                {"tag": "other", "listen": "127.0.0.1", "port": 7443, "protocol": "dokodemo-door"},
            ],
        }

    def tearDown(self):
        self.tmp.cleanup()

    def render(self, config=None, **kwargs):
        return MODULE.render_candidates(
            config or self.config,
            kwargs.get("vmess_domain", "vmess.example.com"),
            kwargs.get("vmess_uuid", "11111111-2222-4333-8444-555555555555"),
            kwargs.get("certificate", str(self.cert)),
            kwargs.get("private_key", str(self.key)),
            kwargs.get("ws_path", "/vmess"),
            kwargs.get("vmess_backend_port", 8443),
            kwargs.get("reality_backend_port", 1443),
        )

    def test_renders_loopback_xray_backends_and_sni_routes(self):
        candidate, manifest, haproxy = self.render()
        reality = next(x for x in candidate["inbounds"] if x["protocol"] == "vless")
        vmess = next(x for x in candidate["inbounds"] if x.get("tag") == MODULE.TAG)
        self.assertEqual((reality["listen"], reality["port"]), ("127.0.0.1", 1443))
        self.assertEqual((vmess["listen"], vmess["port"]), ("127.0.0.1", 8443))
        self.assertEqual(vmess["settings"]["clients"][0]["id"], "11111111-2222-4333-8444-555555555555")
        self.assertEqual(vmess["streamSettings"]["wsSettings"]["path"], "/vmess")
        self.assertEqual([r["sni"] for r in manifest["routes"]], [
            "reality.example.net", "www.example.org", "vmess.example.com"
        ])
        self.assertIn("bind 0.0.0.0:443", haproxy)
        self.assertIn("req.ssl_sni -i vmess.example.com", haproxy)
        self.assertIn("server srv_vmess_ws 127.0.0.1:8443", haproxy)
        self.assertIn("server srv_vless_reality_1 127.0.0.1:1443", haproxy)
        # Source object must remain untouched.
        self.assertEqual(self.config["inbounds"][0]["listen"], "0.0.0.0")
        self.assertEqual(self.config["inbounds"][0]["port"], 443)

    def test_rejects_invalid_uuid_and_path(self):
        with self.assertRaises(MODULE.CandidateError):
            self.render(vmess_uuid="not-a-uuid")
        with self.assertRaises(MODULE.CandidateError):
            self.render(ws_path="bad path")

    def test_rejects_duplicate_or_invalid_sni(self):
        config = json.loads(json.dumps(self.config))
        config["inbounds"][0]["streamSettings"]["realitySettings"]["serverNames"] = [
            "same.example.net", "same.example.net"
        ]
        with self.assertRaises(MODULE.CandidateError):
            self.render(config=config)
        with self.assertRaises(MODULE.CandidateError):
            self.render(vmess_domain="reality.example.net")

    def test_rejects_backend_port_conflict_and_other_public_443_listener(self):
        with self.assertRaises(MODULE.CandidateError):
            self.render(vmess_backend_port=7443)
        config = json.loads(json.dumps(self.config))
        config["inbounds"].append({"tag": "other-443", "port": 443, "protocol": "vmess"})
        with self.assertRaises(MODULE.CandidateError):
            self.render(config=config)

    def test_rejects_missing_reality_and_duplicate_vmess_tag(self):
        config = {"inbounds": [{"tag": "plain", "protocol": "vless", "port": 1234}]}
        with self.assertRaises(MODULE.CandidateError):
            self.render(config=config)
        config = json.loads(json.dumps(self.config))
        config["inbounds"].append({"tag": MODULE.TAG, "port": 12345, "protocol": "vmess"})
        with self.assertRaises(MODULE.CandidateError):
            self.render(config=config)

    def test_rejects_certificate_domain_mismatch_and_key_mismatch(self):
        with self.assertRaises(MODULE.CandidateError):
            self.render(vmess_domain="other.example.com")
        other_key = self.root / "other-key.pem"
        other_cert = self.root / "other-cert.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(other_key), "-out", str(other_cert),
            "-subj", "/CN=vmess.example.com",
            "-addext", "subjectAltName=DNS:vmess.example.com",
            "-days", "1",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with self.assertRaises(MODULE.CandidateError):
            self.render(private_key=str(other_key))

    def test_accepts_valid_letsencrypt_style_symlinks_without_resolving_config_paths(self):
        live = self.root / "live"
        live.mkdir()
        cert_link = live / "fullchain.pem"
        key_link = live / "privkey.pem"
        cert_link.symlink_to(self.cert)
        key_link.symlink_to(self.key)
        candidate, _, _ = self.render(certificate=str(cert_link), private_key=str(key_link))
        vmess = next(x for x in candidate["inbounds"] if x.get("tag") == MODULE.TAG)
        cert_entry = vmess["streamSettings"]["tlsSettings"]["certificates"][0]
        self.assertEqual(cert_entry["certificateFile"], str(cert_link))
        self.assertEqual(cert_entry["keyFile"], str(key_link))
        broken = live / "broken.pem"
        broken.symlink_to(live / "missing.pem")
        with self.assertRaises(MODULE.CandidateError):
            self.render(certificate=str(broken))

    def test_vmess_menu_wires_candidate_and_checks_xray_file_access(self):
        module_text = (ROOT / "modules" / "vmess.sh").read_text()
        self.assertIn('5) Generate shared TCP 443 candidate (no live changes)', module_text)
        self.assertIn('runuser -u "$service_user" -g "$service_group" -- test -r "$cert"', module_text)
        self.assertIn('runuser -u "$service_user" -g "$service_group" -- test -r "$key"', module_text)
        self.assertIn('render-vmess-shared-443.py', module_text)

    def test_candidate_directory_is_private_and_review_only(self):
        candidate, manifest, haproxy = self.render()
        output = self.root / "candidate"
        MODULE.write_candidate_dir(output, candidate, manifest, haproxy)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        for name in ("xray-config.json", "tls-routes.json", "haproxy-443.cfg", "client-details.txt", "README.txt"):
            self.assertEqual((output / name).stat().st_mode & 0o777, 0o600)
        self.assertIn("Public port: 443/TCP", (output / "client-details.txt").read_text())
        self.assertIn("Review-only candidate", (output / "README.txt").read_text())
        with self.assertRaises(MODULE.CandidateError):
            MODULE.write_candidate_dir(output, candidate, manifest, haproxy)


if __name__ == "__main__":
    unittest.main()
