#!/usr/bin/env bash
# Read-only DNSTT deployment inventory. Never prints private keys or credentials.
set -Eeuo pipefail

dnstt_inventory() {
  local -a candidates=(
    /etc/dnstt/server.key
    /etc/dnstt/server.pub
    /etc/dnstt/dnstt.conf
    /etc/systemd/system/dnstt.service
    /etc/africhome-dnstt.env
    /etc/africhome-dnstt.conf
  )
  printf '%-44s %-12s\n' "PATH" "STATUS"
  for path in "${candidates[@]}"; do
    if [[ -e "$path" ]]; then
      printf '%-44.44s %-12s\n' "$path" "PRESENT"
    else
      printf '%-44.44s %-12s\n' "$path" "NOT FOUND"
    fi
  done

  printf '\nDNSTT-related service units:\n'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files --type=service --no-legend 2>/dev/null |
      awk 'tolower($1) ~ /dnstt/ {print $1}'
    printf '\nKnown service status:\n'
    for unit in dnstt.service dnstt-server.service; do
      if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
        printf '%-24s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
      fi
    done
  else
    printf 'systemctl unavailable\n'
  fi

  printf '\nUDP/DNS listeners (read-only):\n'
  if command -v ss >/dev/null 2>&1; then
    ss -H -lunp 2>/dev/null | awk 'NR <= 80 {print}'
  else
    printf 'ss unavailable\n'
  fi
  printf '\nSafety: this inventory does not read key contents, edit files, change DNS, firewall, or services.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dnstt_inventory "$@"
fi
