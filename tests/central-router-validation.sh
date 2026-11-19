#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/modules/central_router.sh"
bash -n "$MODULE"
# shellcheck disable=SC1090
. "$MODULE"

for port in 1 80 443 1194 65535; do cr_valid_port "$port"; done
for port in 0 65536 abc 12x ""; do
  if cr_valid_port "$port"; then echo "Invalid port accepted: $port" >&2; exit 1; fi
done

cr_valid_hostname example.com
cr_valid_hostname vpn-1.example.net
if cr_valid_hostname '-bad.example'; then exit 1; fi
cr_valid_backend 127.0.0.1 10001
if cr_valid_backend 127.0.0.1 70000; then exit 1; fi

cr_validate_route vless-reality tcp 443 reality.example.com 127.0.0.1 1443 >/dev/null
cr_validate_route ssh-direct-ssl tcp 443 ssh.example.com 127.0.0.1 2222 >/dev/null
cr_validate_route v2ray-ws tcp 443 ws.example.com 127.0.0.1 10002 >/dev/null
cr_validate_route openvpn-direct-udp udp 1194 - 127.0.0.1 1195 >/dev/null
if cr_validate_route vless-reality udp 443 - 127.0.0.1 1443 >/dev/null 2>&1; then
  echo "Invalid transport accepted." >&2; exit 1
fi
if cr_validate_route v2ray-ws tcp 80 ws.example.com 127.0.0.1 10002 >/dev/null 2>&1; then
  echo "Invalid public port accepted." >&2; exit 1
fi

cr_check_route_collisions $'tcp|443|reality.example.com|vless-reality\ntcp|443|ssh.example.com|ssh-direct-ssl'
if cr_check_route_collisions $'udp|1194||openvpn\nudp|1194||hysteria2' >/dev/null 2>&1; then
  echo "UDP socket collision was not detected." >&2; exit 1
fi
if cr_check_route_collisions $'tcp|443|same.example.com|route-a\ntcp|443|same.example.com|route-b' >/dev/null 2>&1; then
  echo "Duplicate SNI collision was not detected." >&2; exit 1
fi

# Validation module must remain non-mutating.
if grep -Eiq 'apt-get[[:space:]]+(install|remove)|systemctl[[:space:]]+(restart|stop|disable)|ufw[[:space:]]+(allow|deny|delete|enable)|nft[[:space:]]+(add|delete|flush)|iptables[[:space:]]+(-A|-D|-F)' "$MODULE"; then
  echo "Mutating command found in validation-only router module." >&2; exit 1
fi
echo "Central-router validation checks passed."
