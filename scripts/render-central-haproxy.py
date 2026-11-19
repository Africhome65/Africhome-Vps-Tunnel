#!/usr/bin/env python3
"""Render one combined HAProxy configuration for Africhome TCP 80 and 443.

This generator is read-only and writes the candidate config to stdout.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]


class ConfigError(ValueError):
    pass


def load_renderer(filename: str, module_name: str):
    path = ROOT / "scripts" / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ConfigError(f"cannot load renderer: {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TLS = load_renderer("render-central-router.py", "africhome_tls_renderer")
HTTP = load_renderer("render-http-router.py", "africhome_http_renderer")


def validate(data: Any):
    if not isinstance(data, dict) or set(data) != {"tls_routes", "http_routes"}:
        raise ConfigError("manifest must contain only 'tls_routes' and 'http_routes'")
    tls_routes = TLS.validate_manifest({"routes": data["tls_routes"]})
    http_routes = HTTP.validate_manifest({"routes": data["http_routes"]})
    names = [route["name"] for route in tls_routes + http_routes]
    if len(names) != len(set(names)):
        raise ConfigError("route names must be unique across both listeners")
    return tls_routes, http_routes


def render(tls_routes, http_routes) -> str:
    tls_config = TLS.render(tls_routes).rstrip()
    http_config = HTTP.render(http_routes).splitlines()
    try:
        http_start = http_config.index("frontend africhome_http_80")
    except ValueError as exc:
        raise ConfigError("HTTP renderer did not produce its expected frontend") from exc
    http_fragment = "\n".join(http_config[http_start:]).replace("be_unmatched", "be_http_unmatched")
    return tls_config + "\n\n" + http_fragment + "\n"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {Path(argv[0]).name} ROUTES.json", file=sys.stderr)
        return 2
    try:
        with open(argv[1], "r", encoding="utf-8") as handle:
            tls_routes, http_routes = validate(json.load(handle))
        sys.stdout.write(render(tls_routes, http_routes))
    except (OSError, json.JSONDecodeError, ConfigError, ValueError) as exc:
        print(f"central-haproxy-render: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
