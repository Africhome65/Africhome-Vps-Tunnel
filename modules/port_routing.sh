#!/usr/bin/env bash
# Africhome read-only port inventory. This module deliberately makes no changes.
set -Eeuo pipefail

pr_info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
pr_warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
pr_section(){ printf '\n===== %s =====\n' "$*"; }

pr_require_root(){
  if [[ "${EUID}" -ne 0 ]]; then
    pr_warn "Run the inventory as root to see owning process details and firewall state."
    return 1
  fi
}

pr_listener_inventory(){
  pr_section "LISTENING TCP AND UDP SOCKETS"
  if command -v ss >/dev/null 2>&1; then
    ss -H -lntup
  else
    pr_warn "'ss' is unavailable; install iproute2 to inspect listening sockets."
  fi
}

pr_firewall_inventory(){
  pr_section "UFW STATUS"
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose 2>&1 || true
  else
    printf 'UFW is not installed.\n'
  fi

  pr_section "NFTABLES STATUS"
  if command -v nft >/dev/null 2>&1; then
    nft list ruleset 2>&1 || true
  else
    printf 'nft command is not installed.\n'
  fi

  pr_section "IPTABLES SUMMARY"
  if command -v iptables >/dev/null 2>&1; then
    iptables -S 2>&1 || true
  else
    printf 'iptables command is not installed.\n'
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -S 2>&1 || true
  fi
}

# Read-only helpers for validating proposed public ports.
pr_valid_port(){
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# Return 0 when the selected transport/port is free, 1 when occupied, 2 if unknown.
pr_check_port_available(){
  local protocol="${1:-}" port="${2:-}" output
  [[ "$protocol" == tcp || "$protocol" == udp ]] || return 2
  pr_valid_port "$port" || return 2
  command -v ss >/dev/null 2>&1 || return 2
  if [[ "$protocol" == tcp ]]; then output="$(ss -H -lnt 2>/dev/null)" || return 2
  else output="$(ss -H -lun 2>/dev/null)" || return 2; fi
  awk -v p="$port" '{ endpoint=$4; sub(/^.*:/,"",endpoint); if(endpoint==p) found=1 } END{exit !found}' <<< "$output"
}

pr_route_plan(){
  local protocol port hostname status rc
  pr_section "READ-ONLY ROUTE PLANNER"
  printf 'No proxy, firewall, service, or configuration changes will be made.\\n'
  read -r -p "Transport (tcp/udp): " protocol
  protocol="${protocol,,}"
  [[ "$protocol" == tcp || "$protocol" == udp ]] || { pr_warn "Choose tcp or udp."; return 0; }
  read -r -p "Proposed public port (1-65535): " port
  pr_valid_port "$port" || { pr_warn "Invalid port."; return 0; }
  read -r -p "Hostname/SNI (optional): " hostname
  if [[ -n "$hostname" && ! "$hostname" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
    pr_warn "Hostname format is invalid."; return 0
  fi
  if pr_check_port_available "$protocol" "$port"; then rc=0; else rc=$?; fi
  case "$rc" in 0) status="CURRENTLY FREE" ;; 1) status="ALREADY IN USE" ;; *) status="UNKNOWN (inspection unavailable)" ;; esac
  printf '\\nProposed route: %s/%s\\nHostname/SNI: %s\\nSocket status: %s\\n' "$protocol" "$port" "${hostname:-not specified}" "$status"
  printf 'Planning only: no port has been reserved and no configuration has been written.\\n'
  # A busy or unknown port is a reported planning result, not a fatal menu error.
  return 0
}
pr_service_inventory(){
  pr_section "RELEVANT SERVICE STATES"
  local unit
  for unit in xray.service hysteria-server.service dnstt.service openvpn.service haproxy.service nginx.service ssh.service sshd.service stunnel4.service; do
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q "^$unit"; then
      printf '%-30s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
    fi
  done
}

pr_port_routing_inventory(){
  pr_info "Read-only discovery: no services, listeners, firewall rules, or configuration files will be changed."
  printf 'Host: %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'Kernel: %s\n' "$(uname -r)"
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"
  fi
  pr_listener_inventory
  pr_firewall_inventory
  pr_service_inventory
  pr_section "PROVIDER FIREWALL REMINDER"
  printf 'Cloud/provider firewall rules are not visible from this VPS. Check the provider control panel separately.\n'
  pr_section "NEXT STEP"
  printf 'Review the inventory before planning any port-sharing migration. Existing public listeners remain untouched.\n'
}

pr_port_routing_menu(){
  while true; do
    printf '\n======================================\n'
    printf ' AFRICHOME PORT & ROUTING MANAGER\n'
    printf '======================================\n'
    printf '1) Read-only port and firewall inventory\n'
    printf '2) Plan a proposed TCP/UDP route (read-only)\n'
    printf '0) Return to main menu\n'
    read -r -p "Select an option: " pr_choice
    case "$pr_choice" in
      1) pr_port_routing_inventory; read -r -p "Press Enter to continue..." _ ;;
      2) pr_route_plan; read -r -p "Press Enter to continue..." _ ;;
      0) return 0 ;;
      *) pr_warn "Invalid choice." ;;
    esac
  done
}
