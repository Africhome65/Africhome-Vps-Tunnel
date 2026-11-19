#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "render-central-haproxy.py"

MANIFEST = {
    "tls_routes": [
        {"name": "reality", "sni": "reality.example.com",
         "backend_host": "127.0.0.1", "backend_port": 1443}
    ],
    "http_routes": [
        {"name": "ws", "host": "ws.example.com", "path_prefix": "/tunnel",
         "backend_host": "127.0.0.1", "backend_port": 10080}
    ],
}


def run(data):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "manifest.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return subprocess.run([sys.executable, str(SCRIPT), str(path)],
                              text=True, capture_output=True, check=False)


result = run(MANIFEST)
assert result.returncode == 0, result.stderr
for expected in (
    "global", "defaults", "frontend africhome_tls_443",
    "bind 0.0.0.0:443", "req.ssl_sni -i reality.example.com",
    "frontend africhome_http_80", "bind 0.0.0.0:80",
    "hdr(host),lower,field(1,:) -m str ws.example.com",
    "path_beg -i /tunnel",
    "server srv_reality 127.0.0.1:1443 check",
    "server srv_ws 127.0.0.1:10080 check",
):
    assert expected in result.stdout, expected
assert result.stdout.splitlines().count("global") == 1
assert result.stdout.splitlines().count("defaults") == 1

if shutil.which("haproxy"):
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "haproxy.cfg"
        config.write_text(result.stdout, encoding="utf-8")
        checked = subprocess.run(["haproxy", "-c", "-f", str(config)],
                                 text=True, capture_output=True, check=False)
        assert checked.returncode == 0, checked.stdout + checked.stderr

bad = {
    "tls_routes": MANIFEST["tls_routes"],
    "http_routes": [
        {"name": "reality", "host": "other.example.com",
         "backend_host": "127.0.0.1", "backend_port": 10080}
    ],
}
failed = run(bad)
assert failed.returncode != 0 and not failed.stdout

bad_schema = run({"routes": []})
assert bad_schema.returncode != 0 and not bad_schema.stdout

print("Combined HAProxy TCP 80/443 renderer validation passed.")
