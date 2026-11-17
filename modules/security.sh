#!/usr/bin/env bash

security_fail2ban_install(){
  ah_require_root || return 1
  ah_info "Installing Fail2ban and its systemd journal support..."
  ah_apt_install fail2ban python3-systemd || {
    ah_err "Fail2ban package installation failed."
    return 1
  }

  local ssh_port jail_file
  ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || ssh_port=22
  install -d -m 755 /etc/fail2ban/jail.d || return 1
  jail_file="/etc/fail2ban/jail.d/africhome-sshd.local"

  if [[ ! -e "$jail_file" ]]; then
    cat > "$jail_file" <<EOF
[sshd]
enabled = true
port = $ssh_port
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    chmod 644 "$jail_file"
  else
    ah_info "Existing Africhome Fail2ban SSH jail preserved."
  fi

  if ! fail2ban-client -t; then
    ah_err "Fail2ban configuration validation failed. Existing configuration was not overwritten."
    ah_info "Inspect /etc/fail2ban/jail.d/africhome-sshd.local and other jail files."
    return 1
  fi

  if ! systemctl enable fail2ban || ! systemctl restart fail2ban; then
    ah_err "Could not enable or restart the Fail2ban service."
    systemctl --no-pager --full status fail2ban || true
    journalctl -u fail2ban -n 30 --no-pager || true
    return 1
  fi

  if ! systemctl is-active --quiet fail2ban; then
    ah_err "Fail2ban service did not become active."
    systemctl --no-pager --full status fail2ban || true
    journalctl -u fail2ban -n 30 --no-pager || true
    return 1
  fi

  if ! fail2ban-client ping >/dev/null 2>&1; then
    ah_err "Fail2ban service is active but its control socket did not respond."
    journalctl -u fail2ban -n 30 --no-pager || true
    return 1
  fi

  if ! fail2ban-client status sshd >/dev/null 2>&1; then
    ah_err "Fail2ban is running, but the SSH jail is not active. Check the SSH jail configuration."
    fail2ban-client status || true
    return 1
  fi

  ah_ok "Fail2ban is active and its SSH jail is running on TCP port $ssh_port."
  fail2ban-client status sshd
}

security_fail2ban_status(){
  if command -v fail2ban-client >/dev/null 2>&1; then
    systemctl --no-pager --full status fail2ban || true
    echo
    fail2ban-client status || true
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
  local ssh_port
  ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || ssh_port=22
  ah_warn "This enables UFW. SSH TCP port $ssh_port will be allowed first."
  read -r -p "Type ENABLE to continue (anything else cancels): " answer
  [[ "$answer" == "ENABLE" ]] || { ah_info "Cancelled."; return; }
  ufw allow "$ssh_port/tcp" || return
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
security_torrent_enable(){
  ah_require_root || return
  command -v nft >/dev/null 2>&1 || { ah_apt_install nftables || return; }
  ah_warn "Applies runtime INPUT/OUTPUT drops for common BitTorrent TCP/UDP ports 6881-6999 and 51413. This is not comprehensive torrent detection and does not persist after reboot."
  read -r -p "Type BLOCK to apply these nftables rules: " answer
  [[ "$answer" == "BLOCK" ]] || { ah_info "Cancelled."; return; }
  if nft list table inet africhome_torrent >/dev/null 2>&1; then
    nft delete table inet africhome_torrent
  fi
  nft -f - <<'NFT'
add table inet africhome_torrent
add chain inet africhome_torrent input { type filter hook input priority 10; policy accept; }
add chain inet africhome_torrent output { type filter hook output priority 10; policy accept; }
add rule inet africhome_torrent input tcp dport 6881-6999 drop
add rule inet africhome_torrent input udp dport 6881-6999 drop
add rule inet africhome_torrent output tcp dport 6881-6999 drop
add rule inet africhome_torrent output udp dport 6881-6999 drop
add rule inet africhome_torrent input tcp dport 51413 drop
add rule inet africhome_torrent input udp dport 51413 drop
add rule inet africhome_torrent output tcp dport 51413 drop
add rule inet africhome_torrent output udp dport 51413 drop
NFT
  ah_ok "Basic common-port torrent filtering applied."
}
security_torrent_disable(){
  ah_require_root || return
  if nft list table inet africhome_torrent >/dev/null 2>&1; then
    read -r -p "Type REMOVE to delete Africhome torrent-filter rules: " answer
    [[ "$answer" == "REMOVE" ]] || { ah_info "Cancelled."; return; }
    nft delete table inet africhome_torrent
    ah_ok "Africhome torrent-filter rules removed."
  else
    ah_info "No Africhome torrent-filter table found."
  fi
}
security_menu(){
  while true; do
    clear
    echo "=== SECURITY MANAGEMENT ==="
    echo "1) Install/enable Fail2ban"
    echo "2) Fail2ban status"
    echo "3) UFW status"
    echo "4) Safely enable UFW"
    echo "5) Enable basic torrent common-port filter"
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
