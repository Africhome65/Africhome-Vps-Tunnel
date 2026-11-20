#!/usr/bin/env python3
"""Render read-only Xray and HAProxy candidates for VMess + VLESS REALITY on TCP/443."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import uuid as uuidlib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
TAG = "africhome-vmess-ws-tls"
PATH_RE = re.compile(r"^/[A-Za-z0-9._~!$&'()*+,;=:@%/-]{0,255}$")


class CandidateError(ValueError):
    pass


def load_tls_renderer():
    path = ROOT / "scripts" / "render-central-router.py"
    spec = importlib.util.spec_from_file_location("africhome_tls_renderer", path)
    if spec is None or spec.loader is None:
        raise CandidateError("cannot load the central TLS/SNI renderer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_regular_file(path: str, label: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size == 0:
            raise CandidateError(f"{label} must be a non-empty regular file, not a symlink")
        return stream.read()


def validate_tls_pair(certificate: str, private_key: str, domain: str) -> None:
    if not Path(certificate).is_absolute() or not Path(private_key).is_absolute():
        raise CandidateError("TLS certificate and key paths must be absolute")
    read_regular_file(certificate, "TLS certificate")
    read_regular_file(private_key, "TLS private key")
    try:
        subprocess.run(
            ["openssl", "x509", "-in", certificate, "-noout", "-checkhost", domain],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        cert_pub_pem = subprocess.run(
            ["openssl", "x509", "-in", certificate, "-pubkey", "-noout"],
            check=True, capture_output=True,
        ).stdout
        cert_pub_der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-outform", "DER"],
            input=cert_pub_pem, check=True, capture_output=True,
        ).stdout
        key_pub_der = subprocess.run(
            ["openssl", "pkey", "-in", private_key, "-pubout", "-outform", "DER"],
            check=True, capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise CandidateError("TLS certificate/key validation failed or certificate does not cover the VMess domain") from exc
    if not cert_pub_der or cert_pub_der != key_pub_der:
        raise CandidateError("TLS certificate and private key do not match")


def load_xray_config(path: str) -> dict[str, Any]:
    raw = read_regular_file(path, "Xray source config")
    try:
        config = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CandidateError(f"Xray source config is invalid JSON: {exc}") from exc
    if not isinstance(config, dict) or not isinstance(config.get("inbounds"), list):
        raise CandidateError("Xray config must contain an inbounds array")
    return config


def validate_port(value: int, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1024 <= value <= 65535:
        raise CandidateError(f"{label} must be an integer from 1024 to 65535")
    return value


def render_candidates(
    config: dict[str, Any],
    vmess_domain: str,
    vmess_uuid: str,
    certificate: str,
    private_key: str,
    ws_path: str = "/vmess",
    vmess_backend_port: int = 8443,
    reality_backend_port: int = 1443,
) -> tuple[dict[str, Any], dict[str, Any], str]:
    tls = load_tls_renderer()
    if not tls.valid_hostname(vmess_domain):
        raise CandidateError("VMess SNI domain is not a valid DNS hostname")
    if not PATH_RE.fullmatch(ws_path):
        raise CandidateError("WebSocket path must start with / and contain only safe path characters")
    try:
        normalized_uuid = str(uuidlib.UUID(vmess_uuid))
    except (ValueError, AttributeError) as exc:
        raise CandidateError("VMess UUID is invalid") from exc
    vmess_backend_port = validate_port(vmess_backend_port, "VMess backend port")
    reality_backend_port = validate_port(reality_backend_port, "VLESS REALITY backend port")
    if vmess_backend_port == reality_backend_port:
        raise CandidateError("VMess and VLESS REALITY backend ports must be different")

    # Verify that the supplied TLS certificate covers the VMess SNI and matches its key.
    validate_tls_pair(certificate, private_key, vmess_domain)

    result = copy.deepcopy(config)
    realities: list[dict[str, Any]] = []
    for inbound in result["inbounds"]:
        if not isinstance(inbound, dict):
            continue
        stream = inbound.get("streamSettings")
        if (
            inbound.get("protocol") == "vless"
            and isinstance(stream, dict)
            and stream.get("security") == "reality"
        ):
            realities.append(inbound)
    if len(realities) != 1:
        raise CandidateError(f"Expected exactly one VLESS REALITY inbound; found {len(realities)}")

    reality = realities[0]
    reality_stream = reality.get("streamSettings", {})
    reality_settings = reality_stream.get("realitySettings")
    if not isinstance(reality_settings, dict):
        raise CandidateError("VLESS REALITY inbound is missing realitySettings")
    server_names = reality_settings.get("serverNames")
    if not isinstance(server_names, list) or not server_names:
        raise CandidateError("VLESS REALITY inbound must define at least one serverName for SNI routing")
    seen_sni: set[str] = set()
    for name in server_names:
        if not tls.valid_hostname(name):
            raise CandidateError(f"Invalid VLESS REALITY serverName: {name!r}")
        if name.lower() in seen_sni:
            raise CandidateError(f"Duplicate VLESS REALITY serverName: {name}")
        seen_sni.add(name.lower())
    if vmess_domain.lower() in seen_sni:
        raise CandidateError("VMess SNI domain must differ from every VLESS REALITY serverName")

    if any(isinstance(item, dict) and item.get("tag") == TAG for item in result["inbounds"]):
        raise CandidateError(f"Xray config already contains inbound tag {TAG}")

    for inbound in result["inbounds"]:
        if not isinstance(inbound, dict) or inbound is reality:
            continue
        port = inbound.get("port")
        if port == 443:
            raise CandidateError("Another Xray inbound already uses TCP/443; free it before creating the shared listener candidate")
        if port in (vmess_backend_port, reality_backend_port):
            raise CandidateError(f"Backend port {port} is already used by another Xray inbound")

    reality["listen"] = "127.0.0.1"
    reality["port"] = reality_backend_port
    result["inbounds"].append({
        "tag": TAG,
        "listen": "127.0.0.1",
        "port": vmess_backend_port,
        "protocol": "vmess",
        "settings": {"clients": [{"id": normalized_uuid, "alterId": 0}]},
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "tlsSettings": {
                "certificates": [{
                    "certificateFile": certificate,
                    "keyFile": private_key,
                }]
            },
            "wsSettings": {"path": ws_path},
        },
    })

    routes = []
    for index, name in enumerate(server_names, start=1):
        routes.append({
            "name": f"vless_reality_{index}",
            "sni": name,
            "backend_host": "127.0.0.1",
            "backend_port": reality_backend_port,
        })
    routes.append({
        "name": "vmess_ws",
        "sni": vmess_domain,
        "backend_host": "127.0.0.1",
        "backend_port": vmess_backend_port,
    })
    validated_routes = tls.validate_manifest({"routes": routes})
    haproxy_candidate = tls.render(validated_routes)
    manifest = {"routes": validated_routes}
    return result, manifest, haproxy_candidate


def write_candidate_dir(output_dir: Path, config: dict[str, Any], manifest: dict[str, Any], haproxy: str) -> None:
    if output_dir.exists() or output_dir.is_symlink():
        raise CandidateError(f"Candidate output directory already exists or is a symlink: {output_dir}")
    parent = output_dir.parent
    if not parent.is_dir() or parent.is_symlink():
        raise CandidateError("Candidate output parent must be an existing real directory")
    output_dir.mkdir(mode=0o700)
    try:
        files = {
            "xray-config.json": json.dumps(config, indent=2) + "\n",
            "tls-routes.json": json.dumps(manifest, indent=2) + "\n",
            "haproxy-443.cfg": haproxy,
            "client-details.txt": (
                f"VMess domain: {manifest['routes'][-1]['sni']}\n"
                "Public port: 443/TCP\n"
                f"UUID: {config['inbounds'][-1]['settings']['clients'][0]['id']}\n"
                "Transport: WebSocket over TLS\n"
                f"WebSocket path: {config['inbounds'][-1]['streamSettings']['wsSettings']['path']}\n"
            ),
            "README.txt": (
                "Review-only candidate. No active Xray/HAProxy config, service, DNS or firewall was changed.\n"
                "Xray: install xray-config.json only after reviewing and backing up the active config.\n"
                "HAProxy: review haproxy-443.cfg, then use the guarded HAProxy apply workflow.\n"
                "Both Xray backends bind to loopback; HAProxy routes by TLS SNI on TCP/443.\n"
                "External client testing must confirm VLESS REALITY ClientHello SNI inspection before production use.\n"
                "VMess clients connect to the VMess SNI domain on TCP/443 with TLS and the configured WebSocket path.\n"
            ),
        }
        for name, value in files.items():
            path = output_dir / name
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(path, flags, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(value)
                stream.flush()
                os.fsync(stream.fileno())
    except Exception:
        shutil.rmtree(output_dir, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_config", help="existing Xray JSON config (read only)")
    parser.add_argument("--vmess-domain", required=True)
    parser.add_argument("--vmess-uuid", required=True)
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--private-key", required=True)
    parser.add_argument("--ws-path", default="/vmess")
    parser.add_argument("--vmess-backend-port", type=int, default=8443)
    parser.add_argument("--reality-backend-port", type=int, default=1443)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    try:
        config = load_xray_config(args.source_config)
        candidate, manifest, haproxy = render_candidates(
            config,
            args.vmess_domain,
            args.vmess_uuid,
            args.certificate,
            args.private_key,
            args.ws_path,
            args.vmess_backend_port,
            args.reality_backend_port,
        )
        output_dir = Path(args.output_dir)
        write_candidate_dir(output_dir, candidate, manifest, haproxy)
    except (OSError, CandidateError, ValueError) as exc:
        print(f"VMess shared-443 candidate failed: {exc}", file=sys.stderr)
        return 1
    print(f"Review-only candidate created: {output_dir}")
    print(f"Xray candidate: {output_dir / 'xray-config.json'}")
    print(f"TLS route manifest: {output_dir / 'tls-routes.json'}")
    print(f"HAProxy TCP/443 candidate: {output_dir / 'haproxy-443.cfg'}")
    print("No active services, configuration files, DNS records or firewall rules were changed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
