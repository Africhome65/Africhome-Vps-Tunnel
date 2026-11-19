#!/usr/bin/env python3
"""Render a loopback-only Xray VLESS REALITY backend candidate without changing source."""
import argparse
import copy
import json
import os
import re
import stat
import sys


def load_config(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Xray config must be a regular file")
        config = json.load(stream)
    if not isinstance(config, dict) or not isinstance(config.get("inbounds"), list):
        raise ValueError("Xray config must contain an inbounds array")
    return config


def render(config, port=1443):
    if isinstance(port, bool) or not isinstance(port, int) or not 1024 <= port <= 65535:
        raise ValueError("Backend port must be an integer from 1024 to 65535")
    result = copy.deepcopy(config)
    matches = []
    for inbound in result["inbounds"]:
        if not isinstance(inbound, dict):
            continue
        stream = inbound.get("streamSettings")
        if (
            inbound.get("protocol") == "vless"
            and isinstance(stream, dict)
            and stream.get("security") == "reality"
        ):
            matches.append(inbound)
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one VLESS REALITY inbound; found {len(matches)}")

    for inbound in result["inbounds"]:
        if not isinstance(inbound, dict) or inbound is matches[0]:
            continue
        if inbound.get("port") == port:
            raise ValueError(f"Backend port {port} is already used by another inbound")

    matches[0]["listen"] = "127.0.0.1"
    matches[0]["port"] = port
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="source Xray JSON config (read only)")
    parser.add_argument("--port", type=int, default=1443, help="loopback backend TCP port (default: 1443)")
    args = parser.parse_args()
    config = load_config(args.config)
    candidate = render(config, args.port)
    json.dump(candidate, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"REALITY backend candidate failed: {error}", file=sys.stderr)
        sys.exit(1)
