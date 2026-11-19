#!/usr/bin/env python3
"""Safely add a server name to exactly one Xray VLESS REALITY inbound."""
import json
import os
import re
import stat
import sys
import tempfile


def valid_hostname(name):
    if not isinstance(name, str) or len(name) > 253:
        return False
    labels = name.split(".")
    return all(
        1 <= len(label) <= 63
        and re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?", label)
        for label in labels
    )


def update(path, hostname):
    hostname = hostname.lower()
    if not valid_hostname(hostname):
        raise ValueError("Invalid DNS hostname")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    source_fd = os.open(path, flags)
    with os.fdopen(source_fd, "r", encoding="utf-8") as stream:
        st = os.fstat(stream.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("Xray config must be a regular file")
        config = json.load(stream)
    if not isinstance(config, dict) or not isinstance(config.get("inbounds"), list):
        raise ValueError("Xray config has no valid inbounds array")

    matches = []
    for inbound in config["inbounds"]:
        if not isinstance(inbound, dict):
            continue
        stream = inbound.get("streamSettings")
        if not isinstance(stream, dict) or stream.get("security") != "reality":
            continue
        reality = stream.get("realitySettings")
        if isinstance(reality, dict):
            matches.append(reality)
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one REALITY inbound; found {len(matches)}")

    names = matches[0].get("serverNames", [])
    if not isinstance(names, list) or any(not isinstance(item, str) for item in names):
        raise ValueError("REALITY serverNames must be a string array")
    if hostname not in [item.lower() for item in names]:
        names.append(hostname)
    matches[0]["serverNames"] = names

    directory = os.path.dirname(os.path.abspath(path))
    fd, temporary = tempfile.mkstemp(prefix=".xray-reality-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(config, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), stat.S_IMODE(st.st_mode))
            os.fchown(stream.fileno(), st.st_uid, st.st_gid)
        os.replace(temporary, path)
        dirfd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} CONFIG.json HOSTNAME", file=sys.stderr)
        sys.exit(2)
    try:
        update(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"REALITY SNI update failed: {error}", file=sys.stderr)
        sys.exit(1)
