#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/modules/service_modes.sh"
bash -n "$MODULE"
# shellcheck disable=SC1090
. "$MODULE"
rows="$(af_mode_rows)"
for expected in \
  'SSH|Direct SSL|tcp|443|' \
  'SSH|Payload Direct|tcp|80|' \
  'V2Ray|SSL (VLESS)|tcp|443|' \
  'V2Ray|Payload Proxy (VLESS)|tcp|80|' \
  'V2Ray|VLESS REALITY|tcp|443|' \
  'Trojan|TLS|tcp|443|' \
  'OpenVPN|Direct UDP|udp|1194|' \
  'UDP|Direct (custom port)|udp|custom|' \
  'Hysteria 2|UDP|udp|custom|' \
  'DNSTT|DNS tunnel|udp|custom|'; do
  grep -Fq "$expected" <<< "$rows" || {
    echo "Missing required service mode: $expected" >&2
    exit 1
  }
done
if grep -Eiq 'WireGuard|ZIVPN|SlowDNS|Iodine' "$MODULE"; then
  echo "Excluded protocol found in service mode catalogue." >&2
  exit 1
fi
echo "Service mode catalogue validation passed."
