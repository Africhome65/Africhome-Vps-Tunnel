#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/modules/port_routing.sh"

bash -n "$MODULE"
# shellcheck disable=SC1090
. "$MODULE"

for fn in pr_port_routing_inventory pr_listener_inventory pr_firewall_inventory pr_service_inventory pr_port_routing_menu; do
  declare -F "$fn" >/dev/null || {
    echo "Missing port-routing function: $fn" >&2
    exit 1
  }
done

# The discovery module must not perform installation, listener changes, or firewall writes.
if grep -Eiq 'apt-get[[:space:]]+(install|remove)|systemctl[[:space:]]+(restart|stop|disable)|ufw[[:space:]]+(allow|deny|delete|enable)|nft[[:space:]]+(add|delete|flush)|iptables[[:space:]]+(-A|-D|-F)' "$MODULE"; then
  echo "Unsafe mutating command found in read-only discovery module." >&2
  exit 1
fi

# Validate route-planner input checks without touching host networking.
for port in 1 80 443 1194 65535; do
  pr_valid_port "$port" || { echo "Valid port rejected: $port" >&2; exit 1; }
done
for port in 0 65536 abc 12x ""; do
  if pr_valid_port "$port"; then
    echo "Invalid port accepted: $port" >&2
    exit 1
  fi
done
for protocol in tcp udp; do
  pr_check_port_available "$protocol" 443 >/dev/null 2>&1 && :
  rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 1 || "$rc" -eq 2 ]] || exit 1
done
declare -F pr_route_plan >/dev/null || {
  echo "Missing read-only route planner." >&2
  exit 1
}

echo "Port-routing read-only validation passed."
