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

echo "Port-routing read-only validation passed."
