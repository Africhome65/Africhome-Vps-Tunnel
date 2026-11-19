#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "render-central-router.py"


def run_manifest(data):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "routes.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(path)],
            text=True, capture_output=True, check=False,
        )


valid = {
    "routes": [
        {"name": "xray_reality", "sni": "reality.example.com",
         "backend_host": "127.0.0.1", "backend_port": 1443},
        {"name": "trojan_tls", "sni": "trojan.example.net",
         "backend_host": "::1", "backend_port": 8443},
    ]
}
result = run_manifest(valid)
assert result.returncode == 0, result.stderr
for expected in (
    "frontend africhome_tls_443", "bind 0.0.0.0:443",
    "req.ssl_sni -i reality.example.com",
    "server srv_xray_reality 127.0.0.1:1443 check",
    "server srv_trojan_tls ::1:8443 check",
    "default_backend be_unmatched", "tcp-request content reject",
):
    assert expected in result.stdout, expected
assert "bind *:80" not in result.stdout
assert "ssl crt" not in result.stdout

invalid_cases = [
    {"routes": []},
    {"routes": [{"name": "Bad", "sni": "a.example", "backend_host": "127.0.0.1", "backend_port": 1000}]},
    {"routes": [{"name": "one", "sni": "same.example", "backend_host": "127.0.0.1", "backend_port": 1000},
                {"name": "two", "sni": "SAME.example", "backend_host": "127.0.0.1", "backend_port": 1001}]},
    {"routes": [{"name": "one", "sni": "a.example", "backend_host": "0.0.0.0", "backend_port": 1000}]},
    {"routes": [{"name": "one", "sni": "a.example", "backend_host": "203.0.113.8", "backend_port": 1000}]},
    {"routes": [{"name": "one", "sni": "bad_host.example", "backend_host": "127.0.0.1", "backend_port": 1000}]},
    {"routes": [{"name": "one", "sni": "a.example", "backend_host": "127.0.0.1", "backend_port": 65536}]},
    {"routes": [{"name": "one", "sni": "a.example", "backend_host": "127.0.0.1", "backend_port": True}]},
]
for case in invalid_cases:
    failed = run_manifest(case)
    assert failed.returncode != 0, case
    assert not failed.stdout, case

print("Central-router HAProxy renderer validation passed.")
