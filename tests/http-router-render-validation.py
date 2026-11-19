#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "render-http-router.py"


def run_manifest(data):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "routes.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return subprocess.run([sys.executable, str(SCRIPT), str(path)],
                              text=True, capture_output=True, check=False)


valid = {"routes": [
    {"name": "v2ray_ws", "host": "ws.example.com", "path_prefix": "/vless",
     "backend_host": "127.0.0.1", "backend_port": 10002},
    {"name": "web_fallback", "host": "site.example.com",
     "backend_host": "::1", "backend_port": 8080},
]}
result = run_manifest(valid)
assert result.returncode == 0, result.stderr
for expected in (
    "frontend africhome_http_80", "bind 0.0.0.0:80",
    "hdr(host),lower,field(1,:) -m str ws.example.com",
    "path_beg -i /vless", "server srv_v2ray_ws 127.0.0.1:10002 check",
    "server srv_web_fallback [::1]:8080 check",
    "http-request deny deny_status 421",
):
    assert expected in result.stdout, expected
assert result.stdout.index("path_beg -i /vless") < result.stdout.index("default_backend")
assert "bind 0.0.0.0:443" not in result.stdout
assert "not an SSH payload/proxy gateway" in result.stdout

if shutil.which("haproxy"):
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "haproxy.cfg"
        config.write_text(result.stdout, encoding="utf-8")
        checked = subprocess.run(["haproxy", "-c", "-f", str(config)],
                                 text=True, capture_output=True, check=False)
        assert checked.returncode == 0, checked.stdout + checked.stderr

invalid_cases = [
    {"routes": []},
    {"routes": [{"name": "Bad", "host": "a.example", "backend_host": "127.0.0.1", "backend_port": 80}]},
    {"routes": [{"name": "one", "host": "a.example", "backend_host": "0.0.0.0", "backend_port": 80}]},
    {"routes": [{"name": "one", "host": "a.example", "backend_host": "203.0.113.9", "backend_port": 80}]},
    {"routes": [{"name": "one", "host": "bad_host.example", "backend_host": "127.0.0.1", "backend_port": 80}]},
    {"routes": [{"name": "one", "host": "a.example", "path_prefix": "no-slash", "backend_host": "127.0.0.1", "backend_port": 80}]},
    {"routes": [{"name": "one", "host": "a.example", "path_prefix": "/a", "backend_host": "127.0.0.1", "backend_port": 80},
                {"name": "two", "host": "A.example", "path_prefix": "/a", "backend_host": "127.0.0.1", "backend_port": 81}]},
    {"routes": [{"name": "one", "host": "a.example", "backend_host": "127.0.0.1", "backend_port": True}]},
]
for case in invalid_cases:
    failed = run_manifest(case)
    assert failed.returncode != 0, case
    assert not failed.stdout, case

print("Central-router HTTP Host/path renderer validation passed.")
