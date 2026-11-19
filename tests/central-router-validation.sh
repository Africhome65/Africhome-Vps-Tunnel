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
if cr_valid_hostname '-bad.example'; then echo "Invalid hostname accepted." >&2; exit 1; fi
label64="$(printf '%064d' 0 | tr '0' 'a')"
label63="$(printf '%063d' 0 | tr '0' 'a')"
long_hostname="${label63}.${label63}.${label63}.${label63}"
if cr_valid_hostname "${label64}.example.com"; then echo "Overlong DNS label accepted." >&2; exit 1; fi
if cr_valid_hostname "$long_hostname"; then echo "Overlong DNS hostname accepted." >&2; exit 1; fi

cr_valid_backend 127.0.0.1 10001
cr_valid_backend ::1 10001
for args in "127.0.0.1 70000" "0.0.0.0 10001" "203.0.113.10 10001"; do
  if cr_valid_backend $args; then echo "Unsafe backend accepted: $args" >&2; exit 1; fi
done

cr_validate_route vless-reality tcp 443 reality.example.com 127.0.0.1 1443 >/dev/null
cr_validate_route ssh-direct-ssl tcp 443 ssh.example.com 127.0.0.1 2222 >/dev/null
cr_validate_route ssh-payload-direct tcp 80 - 127.0.0.1 2200 >/dev/null
cr_validate_route v2ray-ws tcp 443 ws.example.com 127.0.0.1 10002 >/dev/null
cr_validate_route trojan-tls tcp 443 trojan.example.com 127.0.0.1 8443 >/dev/null
cr_validate_route openvpn-direct-tcp tcp 1194 - 127.0.0.1 1195 >/dev/null
cr_validate_route openvpn-direct-udp udp 1194 - 127.0.0.1 1195 >/dev/null
if cr_validate_route vless-reality udp 443 - 127.0.0.1 1443 >/dev/null 2>&1; then echo "Invalid transport accepted." >&2; exit 1; fi
if cr_validate_route v2ray-ws tcp 80 ws.example.com 127.0.0.1 10002 >/dev/null 2>&1; then echo "Invalid public port accepted." >&2; exit 1; fi
if cr_validate_route openvpn-direct-udp udp 1194 udp.example.com 127.0.0.1 1195 >/dev/null 2>&1; then echo "UDP route accepted SNI." >&2; exit 1; fi
if cr_validate_route openvpn-direct-udp udp 1194 - 203.0.113.10 1195 >/dev/null 2>&1; then echo "Public UDP backend accepted." >&2; exit 1; fi
if cr_validate_route ssh-direct-ssl tcp 80 ssh.example.com 127.0.0.1 2222 >/dev/null 2>&1; then echo "SSH direct SSL accepted wrong port." >&2; exit 1; fi

cr_check_route_collisions $'tcp|443|reality.example.com|vless-reality\ntcp|443|ssh.example.com|ssh-direct-ssl'
for routes in \
  $'udp|1194||openvpn\nudp|1194||hysteria2' \
  $'tcp|443|same.example.com|route-a\ntcp|443|same.example.com|route-b' \
  $'tcp|443|first.example.com|route-a\ntcp|443|second.example.com|route-b\ntcp|443|second.example.com|route-c' \
  $'tcp|443|-|raw-route\ntcp|443|ssh.example.com|sni-route' \
  $'tcp|443|SSH.EXAMPLE.COM|route-a\ntcp|443|ssh.example.com|route-b' \
  $'tcp|443|bad_host.example.com|route-a' \
  $'udp|1194|vpn.example.com|udp-route'; do
  if cr_check_route_collisions "$routes" >/dev/null 2>&1; then echo "Invalid route collision case accepted." >&2; exit 1; fi
done

[[ "$(cr_pick_udp_port 10000 10002 10000,10001)" == "10002" ]]
[[ "$(cr_pick_udp_port 20000 20002 '')" == "20000" ]]
for args in "10000 10001 10000,10001" "0 10001 ''" "10000 10001 10000,bad"; do
  if cr_pick_udp_port $args >/dev/null 2>&1; then echo "Invalid UDP allocation accepted: $args" >&2; exit 1; fi
done

if grep -Eiq 'apt-get[[:space:]]+(install|remove)|systemctl[[:space:]]+(restart|stop|disable)|ufw[[:space:]]+(allow|deny|delete|enable)|nft[[:space:]]+(add|delete|flush)|iptables[[:space:]]+(-A|-D|-F)' "$MODULE"; then
  echo "Mutating command found in validation-only router module." >&2; exit 1
fi

for mode in ssh-direct-ssl ssh-payload-direct ssh-payload-proxy ssh-payload-proxy-sni \
  v2ray-ssl v2ray-payload-proxy v2ray-direct v2ray-ws vless-reality \
  trojan-tls trojan-tls-80 openvpn-tls-sni openvpn-ws openvpn-direct-tcp \
  openvpn-direct-80 openvpn-direct-443 openvpn-direct-udp udp-direct hysteria2 dnstt; do
  cr_mode_transport "$mode" >/dev/null || { echo "Missing mode mapping: $mode" >&2; exit 1; }
done

echo "Central-router validation checks passed."
