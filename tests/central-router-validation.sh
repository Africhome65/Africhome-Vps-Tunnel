#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/modules/central_router.sh"

bash -n "$MODULE"
# shellcheck disable=SC1090
. "$MODULE"

for port in 1 80 443 1194 65535; do
  cr_valid_port "$port"
done
for port in 0 65536 abc 12x ""; do
  if cr_valid_port "$port"; then
    echo "Invalid port accepted: $port" >&2
    exit 1
  fi
done

cr_valid_hostname example.com
cr_valid_hostname vpn-1.example.net
if cr_valid_hostname '-bad.example'; then
  echo "Invalid hostname accepted." >&2
  exit 1
fi

cr_valid_backend 127.0.0.1 10001
cr_valid_backend ::1 10001
if cr_valid_backend 127.0.0.1 70000; then
  echo "Invalid backend port accepted." >&2
  exit 1
fi
if cr_valid_backend 0.0.0.0 10001; then
  echo "Wildcard backend address accepted." >&2
  exit 1
fi
if cr_valid_backend 203.0.113.10 10001; then
  echo "Public backend address accepted." >&2
  exit 1
fi

cr_validate_route vless-reality tcp 443 reality.example.com 127.0.0.1 1443 >/dev/null
cr_validate_route ssh-direct-ssl tcp 443 ssh.example.com 127.0.0.1 2222 >/dev/null
cr_validate_route v2ray-ws tcp 443 ws.example.com 127.0.0.1 10002 >/dev/null
cr_validate_route openvpn-direct-udp udp 1194 - 127.0.0.1 1195 >/dev/null
if cr_validate_route vless-reality udp 443 - 127.0.0.1 1443 >/dev/null 2>&1; then
  echo "Invalid transport accepted." >&2
  exit 1
fi
if cr_validate_route v2ray-ws tcp 80 ws.example.com 127.0.0.1 10002 >/dev/null 2>&1; then
  echo "Invalid public port accepted." >&2
  exit 1
fi
if cr_validate_route openvpn-direct-udp udp 1194 udp.example.com 127.0.0.1 1195 >/dev/null 2>&1; then
  echo "UDP route incorrectly accepted an SNI hostname." >&2
  exit 1
fi
if cr_validate_route openvpn-direct-udp udp 1194 - 203.0.113.10 1195 >/dev/null 2>&1; then
  echo "Public UDP backend address accepted." >&2
  exit 1
fi

cr_check_route_collisions $'tcp|443|reality.example.com|vless-reality\ntcp|443|ssh.example.com|ssh-direct-ssl'
if cr_check_route_collisions $'udp|1194||openvpn\nudp|1194||hysteria2' >/dev/null 2>&1; then
  echo "UDP socket collision was not detected." >&2
  exit 1
fi
if cr_check_route_collisions $'tcp|443|same.example.com|route-a\ntcp|443|same.example.com|route-b' >/dev/null 2>&1; then
  echo "Duplicate SNI collision was not detected." >&2
  exit 1
fi
if cr_check_route_collisions $'tcp|443|first.example.com|route-a\ntcp|443|second.example.com|route-b\ntcp|443|second.example.com|route-c' >/dev/null 2>&1; then
  echo "Repeated SNI in a later route was not detected." >&2
  exit 1
fi
if cr_check_route_collisions $'tcp|443|-|raw-route\ntcp|443|ssh.example.com|sni-route' >/dev/null 2>&1; then
  echo "Wildcard TCP route was incorrectly allowed to share a socket." >&2
  exit 1
fi
if cr_check_route_collisions $'tcp|443|SSH.EXAMPLE.COM|route-a\ntcp|443|ssh.example.com|route-b' >/dev/null 2>&1; then
  echo "Case-insensitive duplicate SNI was not detected." >&2
  exit 1
fi
if cr_check_route_collisions 

# UDP allocator uses supplied inventory only and never reserves a socket.
[[ "$(cr_pick_udp_port 10000 10002 10000,10001)" == "10002" ]]
[[ "$(cr_pick_udp_port 20000 20002 '')" == "20000" ]]
if cr_pick_udp_port 10000 10001 10000,10001 >/dev/null 2>&1; then
  echo "Full UDP range incorrectly returned a free port." >&2
  exit 1
fi
if cr_pick_udp_port 0 10001 '' >/dev/null 2>&1; then
  echo "Invalid UDP range was accepted." >&2
  exit 1
fi
if cr_pick_udp_port 10000 10001 10000,bad >/dev/null 2>&1; then
  echo "Malformed occupied-port inventory was accepted." >&2
  exit 1
fi

# Validation module must remain non-mutating.
if grep -Eiq 'apt-get[[:space:]]+(install|remove)|systemctl[[:space:]]+(restart|stop|disable)|ufw[[:space:]]+(allow|deny|delete|enable)|nft[[:space:]]+(add|delete|flush)|iptables[[:space:]]+(-A|-D|-F)' "$MODULE"; then
  echo "Mutating command found in validation-only router module." >&2
  exit 1
fi

for mode in ssh-direct-ssl ssh-payload-direct ssh-payload-proxy ssh-payload-proxy-sni \
  v2ray-ssl v2ray-payload-proxy v2ray-direct v2ray-ws vless-reality \
  trojan-tls trojan-tls-80 openvpn-tls-sni openvpn-ws openvpn-direct-tcp \
  openvpn-direct-80 openvpn-direct-443 openvpn-direct-udp udp-direct hysteria2 dnstt; do
  cr_mode_transport "$mode" >/dev/null || {
    echo "Missing central-router mode mapping: $mode" >&2
    exit 1
  }
done

echo "Central-router validation checks passed."
tcp|443|bad_host.example.com|route-a' >/dev/null 2>&1; then
  echo "Invalid SNI hostname was accepted in route list." >&2
  exit 1
fi

if cr_check_route_collisions 

# UDP allocator uses supplied inventory only and never reserves a socket.
[[ "$(cr_pick_udp_port 10000 10002 10000,10001)" == "10002" ]]
[[ "$(cr_pick_udp_port 20000 20002 '')" == "20000" ]]
if cr_pick_udp_port 10000 10001 10000,10001 >/dev/null 2>&1; then
  echo "Full UDP range incorrectly returned a free port." >&2
  exit 1
fi
if cr_pick_udp_port 0 10001 '' >/dev/null 2>&1; then
  echo "Invalid UDP range was accepted." >&2
  exit 1
fi
if cr_pick_udp_port 10000 10001 10000,bad >/dev/null 2>&1; then
  echo "Malformed occupied-port inventory was accepted." >&2
  exit 1
fi

# Validation module must remain non-mutating.
if grep -Eiq 'apt-get[[:space:]]+(install|remove)|systemctl[[:space:]]+(restart|stop|disable)|ufw[[:space:]]+(allow|deny|delete|enable)|nft[[:space:]]+(add|delete|flush)|iptables[[:space:]]+(-A|-D|-F)' "$MODULE"; then
  echo "Mutating command found in validation-only router module." >&2
  exit 1
fi

for mode in ssh-direct-ssl ssh-payload-direct ssh-payload-proxy ssh-payload-proxy-sni \
  v2ray-ssl v2ray-payload-proxy v2ray-direct v2ray-ws vless-reality \
  trojan-tls trojan-tls-80 openvpn-tls-sni openvpn-ws openvpn-direct-tcp \
  openvpn-direct-80 openvpn-direct-443 openvpn-direct-udp udp-direct hysteria2 dnstt; do
  cr_mode_transport "$mode" >/dev/null || {
    echo "Missing central-router mode mapping: $mode" >&2
    exit 1
  }
done

echo "Central-router validation checks passed."
udp|1194|vpn.example.com|udp-route' >/dev/null 2>&1; then
  echo "UDP hostname/SNI route was incorrectly accepted." >&2
  exit 1
fi
# Every fixed-port route must validate against the numeric public port.
cr_validate_route ssh-payload-direct tcp 80 - 127.0.0.1 2200 >/dev/null
cr_validate_route trojan-tls tcp 443 trojan.example.com 127.0.0.1 8443 >/dev/null
cr_validate_route openvpn-direct-tcp tcp 1194 - 127.0.0.1 1195 >/dev/null
if cr_validate_route ssh-direct-ssl tcp 80 ssh.example.com 127.0.0.1 2222 >/dev/null 2>&1; then
  echo "SSH direct SSL accepted the wrong public port." >&2
  exit 1
fi

# UDP allocator uses supplied inventory only and never reserves a socket.
[[ "$(cr_pick_udp_port 10000 10002 10000,10001)" == "10002" ]]
[[ "$(cr_pick_udp_port 20000 20002 '')" == "20000" ]]
if cr_pick_udp_port 10000 10001 10000,10001 >/dev/null 2>&1; then
  echo "Full UDP range incorrectly returned a free port." >&2
  exit 1
fi
if cr_pick_udp_port 0 10001 '' >/dev/null 2>&1; then
  echo "Invalid UDP range was accepted." >&2
  exit 1
fi
if cr_pick_udp_port 10000 10001 10000,bad >/dev/null 2>&1; then
  echo "Malformed occupied-port inventory was accepted." >&2
  exit 1
fi

# Validation module must remain non-mutating.
if grep -Eiq 'apt-get[[:space:]]+(install|remove)|systemctl[[:space:]]+(restart|stop|disable)|ufw[[:space:]]+(allow|deny|delete|enable)|nft[[:space:]]+(add|delete|flush)|iptables[[:space:]]+(-A|-D|-F)' "$MODULE"; then
  echo "Mutating command found in validation-only router module." >&2
  exit 1
fi

for mode in ssh-direct-ssl ssh-payload-direct ssh-payload-proxy ssh-payload-proxy-sni \
  v2ray-ssl v2ray-payload-proxy v2ray-direct v2ray-ws vless-reality \
  trojan-tls trojan-tls-80 openvpn-tls-sni openvpn-ws openvpn-direct-tcp \
  openvpn-direct-80 openvpn-direct-443 openvpn-direct-udp udp-direct hysteria2 dnstt; do
  cr_mode_transport "$mode" >/dev/null || {
    echo "Missing central-router mode mapping: $mode" >&2
    exit 1
  }
done

echo "Central-router validation checks passed."
