#!/usr/bin/env bash

security_detect_ssh_ports(){
  command -v sshd >/dev/null 2>&1 || return 1
  local ports
  ports="$(sshd -T 2>/dev/null | awk '$1=="port" { if ($2 ~ /^[0-9]+$/ && $2 >= 1 && $2 <= 65535) { if (out != "") out=out ","; out=out $2 } } END { print out }')"
  [[ -n "$ports" ]] || return 1
  printf '%s\n' "$ports"
}

security_fail2ban_rollback_new_jail(){
  local jail_file="$1"
  rm -f -- "$jail_file"
  systemctl restart fail2ban >/dev/null 2>&1 || true
}

security_fail2ban_install(){
  ah_require_root || return 1
  local ssh_ports jail_dir jail_file created=0
  ssh_ports="$(security_detect_ssh_ports)" || {
    ah_err "Could not safely detect the effective SSH daemon port. No jail was written."
    return 1
  }

  ah_info "Installing Fail2ban and systemd journal support..."
  ah_apt_install fail2ban python3-systemd || {
    ah_err "Fail2ban package installation failed."
    return 1
  }

  jail_dir="/etc/fail2ban/jail.d"
  jail_file="$jail_dir/africhome-sshd.local"
  install -d -m 0755 "$jail_dir" || return 1

  if [[ -e "$jail_file" ]]; then
    ah_info "Existing Africhome SSH jail found; preserving it without modification."
  else
    local tmp
    tmp="$(mktemp "$jail_dir/.africhome-sshd.XXXXXX")" || return 1
    if ! cat > "$tmp" <<EOF
# Managed by Africhome VPS Tunnel. Existing files are never overwritten.
[sshd]
enabled = true
port = $ssh_ports
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    then
      rm -f "$tmp"
      return 1
    fi
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    if ! mv -- "$tmp" "$jail_file"; then
      rm -f "$tmp"
      return 1
    fi
    created=1
  fi

  if ! fail2ban-client -t; then
    ah_err "Fail2ban configuration validation failed."
    if (( created )); then rm -f -- "$jail_file"; fi
    return 1
  fi

  if ! systemctl enable fail2ban || ! systemctl restart fail2ban; then
    ah_err "Fail2ban could not be enabled or restarted."
    if (( created )); then security_fail2ban_rollback_new_jail "$jail_file"; fi
    systemctl --no-pager --full status fail2ban || true
    journalctl -u fail2ban -n 30 --no-pager || true
    return 1
  fi

  if ! systemctl is-active --quiet fail2ban ||
     ! fail2ban-client ping >/dev/null 2>&1 ||
     ! fail2ban-client status sshd >/dev/null 2>&1; then
    ah_err "Fail2ban started, but its SSH jail did not become healthy."
    if (( created )); then security_fail2ban_rollback_new_jail "$jail_file"; fi
    fail2ban-client status || true
    journalctl -u fail2ban -n 30 --no-pager || true
    return 1
  fi

  ah_ok "Fail2ban is active; SSH jail protects TCP port(s): $ssh_ports."
  fail2ban-client status sshd
}

security_fail2ban_status(){
  if command -v fail2ban-client >/dev/null 2>&1; then
    systemctl --no-pager --full status fail2ban || true
    echo
    fail2ban-client status || true
    echo
    fail2ban-client status sshd || true
  else
    ah_warn "Fail2ban is not installed."
  fi
}
security_fail2ban_banned_ips(){
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    ah_warn "Fail2ban is not installed."
    return 1
  fi
  fail2ban-client get sshd banip
}
security_valid_ip(){
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$1" >/dev/null 2>&1
}
security_fail2ban_unban(){
  ah_require_root || return 1
  command -v fail2ban-client >/dev/null 2>&1 || {
    ah_warn "Fail2ban is not installed."
    return 1
  }
  fail2ban-client status sshd >/dev/null 2>&1 || {
    ah_err "The SSH jail is not active."
    return 1
  }
  local ip
  read -r -p "IP address to unban from the sshd jail: " ip
  if ! security_valid_ip "$ip"; then
    ah_err "Enter a valid IPv4 or IPv6 address."
    return 1
  fi
  echo "Selected address: $ip"
  read -r -p "Type UNBAN to release this address: " answer
  [[ "$answer" == "UNBAN" ]] || { ah_info "Cancelled."; return; }
  fail2ban-client set sshd unbanip "$ip"
}
security_ufw_status(){
  if command -v ufw >/dev/null 2>&1; then ufw status verbose; else ah_warn "UFW is not installed."; fi
}
security_ufw_enable(){
  ah_require_root || return
  command -v ufw >/dev/null 2>&1 || { ah_apt_install ufw || return; }
  local ssh_ports
  ssh_ports="$(security_detect_ssh_ports)" || {
    ah_err "Could not detect SSH port(s); refusing to enable UFW."
    return 1
  }
  ah_warn "This enables UFW after allowing SSH TCP port(s): $ssh_ports."
  read -r -p "Type ENABLE to continue (anything else cancels): " answer
  [[ "$answer" == "ENABLE" ]] || { ah_info "Cancelled."; return; }
  local port
  IFS=',' read -r -a _ssh_port_list <<< "$ssh_ports"
  for port in "${_ssh_port_list[@]}"; do ufw allow "$port/tcp" || return; done
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw --force enable
  ah_ok "UFW enabled. Check that all required service ports are allowed."
}
security_torrent_status(){
  if command -v nft >/dev/null 2>&1 && nft list table inet africhome_torrent >/dev/null 2>&1; then
    nft list table inet africhome_torrent
  else
    ah_warn "Africhome common-port torrent filter is not active."
  fi
}
security_torrent_rules(){
  cat <<'NFT'
add table inet africhome_torrent
add chain inet africhome_torrent input { type filter hook input priority 10; policy accept; }
add chain inet africhome_torrent output { type filter hook output priority 10; policy accept; }
add rule inet africhome_torrent input tcp dport { 6881-6999, 51413 } drop
add rule inet africhome_torrent input udp dport { 6881-6999, 51413 } drop
add rule inet africhome_torrent output tcp dport { 6881-6999, 51413 } drop
add rule inet africhome_torrent output udp dport { 6881-6999, 51413 } drop
NFT
}
security_torrent_enable(){
  ah_require_root || return
  command -v nft >/dev/null 2>&1 || { ah_apt_install nftables || return; }
  if nft list table inet africhome_torrent >/dev/null 2>&1; then
    ah_warn "Africhome torrent table already exists; preserving it without replacement."
    security_torrent_status
    return 0
  fi
  ah_warn "Optional host-only common-port filter: TCP/UDP 6881-6999 and 51413 on INPUT/OUTPUT."
  ah_warn "It is incomplete: alternate ports, encryption, trackers and dynamic peer ports can bypass it."
  ah_warn "It does not filter traffic forwarded through tunnel interfaces and does not persist after reboot."
  ah_warn "No existing nftables table, UFW rule, Hysteria UDP range, or other firewall rule will be flushed."
  if ! security_torrent_rules | nft -c -f -; then
    ah_err "nftables rejected the proposed rules; nothing was applied."
    return 1
  fi
  read -r -p "Type BLOCK to apply these host firewall rules: " answer
  [[ "$answer" == "BLOCK" ]] || { ah_info "Cancelled."; return; }
  if ! security_torrent_rules | nft -f -; then
    ah_err "Could not apply the Africhome torrent filter."
    return 1
  fi
  ah_ok "Basic host common-port torrent filtering applied."
}
security_torrent_disable(){
  ah_require_root || return
  if command -v nft >/dev/null 2>&1 && nft list table inet africhome_torrent >/dev/null 2>&1; then
    read -r -p "Type REMOVE to delete only the Africhome torrent table: " answer
    [[ "$answer" == "REMOVE" ]] || { ah_info "Cancelled."; return; }
    nft delete table inet africhome_torrent
    ah_ok "Africhome torrent-filter table removed."
  else
    ah_info "No Africhome torrent-filter table found."
  fi
}
security_audit_readonly(){
  echo "=== AFRICHOME READ-ONLY SECURITY AUDIT ==="
  echo "Timestamp (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo
  echo "-- OS --"
  if [[ -r /etc/os-release ]]; then . /etc/os-release; printf '%s\n' "${PRETTY_NAME:-unknown}"; fi
  printf 'Kernel: %s\n' "$(uname -r)"
  echo
  echo "-- SSH effective configuration --"
  if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | awk '$1=="port" || $1=="permitrootlogin" || $1=="passwordauthentication" || $1=="pubkeyauthentication" {print}'
  else
    echo "sshd binary not found"
  fi
  echo
  echo "-- Listening TCP/UDP sockets --"
  if command -v ss >/dev/null 2>&1; then ss -H -lntup 2>/dev/null || true; else echo "ss command unavailable"; fi
  echo
  echo "-- Security services --"
  local unit
  for unit in ssh.service sshd.service fail2ban.service ufw.service nftables.service; do
    if command -v systemctl >/dev/null 2>&1; then
      printf '%-22s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
    fi
  done
  echo
  echo "-- Firewall overview (read-only) --"
  if command -v ufw >/dev/null 2>&1; then ufw status verbose 2>&1 || true; fi
  if command -v nft >/dev/null 2>&1; then nft list ruleset 2>/dev/null | sed -n '1,180p' || true; fi
  echo
  echo "-- Failed login summary --"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u ssh -u sshd --since '24 hours ago' --no-pager 2>/dev/null |
      grep -Ei 'failed password|invalid user|authentication failure' | tail -n 20 || true
  fi
  echo
  echo "-- Africhome-owned torrent filter --"
  security_torrent_status 2>&1 || true
  echo
  echo "Audit is informational only: no settings, services, or firewall rules were changed."
}
security_menu(){
  while true; do
    clear
    echo "=== SECURITY MANAGEMENT ==="
    echo "1) Install/enable Fail2ban SSH protection"
    echo "2) Fail2ban status"
    echo "3) Show SSH banned IP addresses"
    echo "4) Unban an SSH IP address"
    echo "5) UFW status"
    echo "6) Safely enable UFW"
    echo "7) Enable basic host torrent common-port filter"
    echo "8) Torrent filter status"
    echo "9) Disable Africhome torrent filter"
    echo "10) Read-only security audit"
    echo "0) Back"
    read -r -p "Select: " choice
    case "$choice" in
      1) security_fail2ban_install; ah_pause ;;
      2) security_fail2ban_status; ah_pause ;;
      3) security_fail2ban_banned_ips; ah_pause ;;
      4) security_fail2ban_unban; ah_pause ;;
      5) security_ufw_status; ah_pause ;;
      6) security_ufw_enable; ah_pause ;;
      7) security_torrent_enable; ah_pause ;;
      8) security_torrent_status; ah_pause ;;
      9) security_torrent_disable; ah_pause ;;
      10) security_audit_readonly; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice."; sleep 1 ;;
    esac
  done
}
