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
security_menu(){
  while true; do
    clear
    echo "=== SECURITY MANAGEMENT ==="
    echo "1) Install/enable Fail2ban SSH protection"
    echo "2) Fail2ban status"
    echo "3) UFW status"
    echo "4) Safely enable UFW"
    echo "5) Enable basic host torrent common-port filter"
    echo "6) Torrent filter status"
    echo "7) Disable Africhome torrent filter"
    echo "0) Back"
    read -r -p "Select: " choice
    case "$choice" in
      1) security_fail2ban_install; ah_pause ;;
      2) security_fail2ban_status; ah_pause ;;
      3) security_ufw_status; ah_pause ;;
      4) security_ufw_enable; ah_pause ;;
      5) security_torrent_enable; ah_pause ;;
      6) security_torrent_status; ah_pause ;;
      7) security_torrent_disable; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice."; sleep 1 ;;
    esac
  done
}
