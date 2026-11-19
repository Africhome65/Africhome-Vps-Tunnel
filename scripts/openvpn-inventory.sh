#!/usr/bin/env bash
# Read-only OpenVPN inventory. Never prints credentials, inline keys, or certificate contents.
set -Eeuo pipefail

ovpn_inventory() {
  local -a configs=()
  local file unit
  local found=0

  printf 'OpenVPN configuration inventory (read-only)\n'
  for dir in /etc/openvpn /etc/openvpn/server; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' file; do
      configs+=("$file")
    done < <(find "$dir" -maxdepth 2 -type f -name '*.conf' -print0 2>/dev/null)
  done

  if (("${#configs[@]}" == 0)); then
    printf 'No OpenVPN .conf files found in standard directories.\n'
  else
    printf '%-48s %-8s %-8s %-8s\n' 'CONFIG' 'PROTO' 'PORT' 'DEVICE'
    for file in "${configs[@]}"; do
      found=1
      # Only display non-secret routing metadata from active, uncommented directives.
      awk -v label="$(basename "$file")" '
        /^[[:space:]]*[#;]/ {next}
        {
          key=tolower($1)
          if (key=="proto" || key=="port" || key=="dev") value[key]=$2
        }
        END {
          printf "%-48.48s %-8s %-8s %-8s\n", label, value["proto"], value["port"], value["dev"]
        }
      ' "$file"
    done
  fi

  printf '\nOpenVPN-related systemd units:\n'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-unit-files --type=service --no-legend 2>/dev/null |
      awk 'tolower($1) ~ /^openvpn([@.-]|$)/ {print $1}'
    printf '\nKnown service states:\n'
    for unit in openvpn.service openvpn-server@server.service; do
      if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
        printf '%-32s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
      fi
    done
  else
    printf 'systemctl unavailable\n'
  fi

  printf '\nTCP/UDP listeners (read-only; filtered for common OpenVPN ports):\n'
  if command -v ss >/dev/null 2>&1; then
    ss -H -lntup 2>/dev/null | awk '$0 ~ /:1194([[:space:]]|$)/ || $0 ~ /openvpn/ {print}'
  else
    printf 'ss unavailable\n'
  fi
  printf '\nSafety: configuration secrets, keys, certificates, usernames and passwords are not displayed. No files, firewall rules, or services are changed.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ovpn_inventory "$@"
fi
