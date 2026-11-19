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
# Port availability must distinguish an occupied socket from a free one.
ss() { printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\n'; }
if pr_check_port_available tcp 443; then
  echo "Occupied TCP port was reported free." >&2
  exit 1
fi
ss() { :; }
pr_check_port_available tcp 443 || {
  echo "Free TCP port was reported occupied." >&2
  exit 1
}

declare -F pr_route_plan >/dev/null || {
  echo "Missing read-only route planner." >&2
  exit 1
}

# The interactive planner must not terminate the set -e menu on ordinary input/results.
if ! printf 'bad\n443\nexample.com\n' | pr_route_plan >/dev/null 2>&1; then
  echo "Invalid planner input incorrectly returned a fatal status." >&2
  exit 1
fi
pr_check_port_available(){ return 1; }
if ! printf 'tcp\n443\nexample.com\n' | pr_route_plan >/dev/null 2>&1; then
  echo "Occupied port incorrectly returned a fatal menu status." >&2
  exit 1
fi


# Hostname validation rejects empty labels, leading/trailing hyphens, and bad characters.
for hostname in example.com sub-domain.example.org localhost 192.0.2.1 a; do
  pr_valid_hostname "$hostname" || {
    echo "Valid hostname rejected: $hostname" >&2
    exit 1
  }
done
for hostname in .example.com example..com example.com. -example.com example-.com 'bad host' _service.example.com; do
  if pr_valid_hostname "$hostname"; then
    echo "Invalid hostname accepted: $hostname" >&2
    exit 1
  fi
done
long_label="$(printf '%064d' 0 | tr '0' 'a')"
if pr_valid_hostname "$long_label.example"; then
  echo "Hostname label longer than 63 characters was accepted." >&2
  exit 1
fi

# Ensure the route planner prints real line breaks rather than literal backslash-n text.
route_output="$(printf 'tcp\n443\nexample.com\n' | pr_route_plan 2>/dev/null)"
grep -Fq 'Proposed route: tcp/443' <<< "$route_output" || {
  echo "Route planner did not print its proposed route." >&2
  exit 1
}
grep -Fq 'Hostname/SNI: example.com' <<< "$route_output" || {
  echo "Route planner did not print the validated hostname." >&2
  exit 1
}

echo "Port-routing read-only validation passed."
