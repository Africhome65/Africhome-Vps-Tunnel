#!/usr/bin/env bash
# Iodine-based DNS tunnel. SSH is reached through the tunnel IP.
set -Eeuo pipefail

SD_ENV="/etc/africhome-slowdns.env"
SD_UNIT="/etc/systemd/system/africhome-slowdns.service"
SD_SERVER_IP="10.77.0.1/24"

sd_install() {
  ah_require_root || return 1
  ah_apt_install iodine openssh-client || return 1
  ah_ok "Iodine DNS tunnel packages installed."
}

sd_setup() {
  ah_require_root || return 1
  command -v iodined >/dev/null 2>&1 || { ah_warn "Install SlowDNS packages first."; return 1; }
  [[ ! -e "$SD_ENV" ]] || { ah_warn "SlowDNS configuration already exists. Remove it from the menu before creating a new one."; return 1; }
  if command -v ss >/dev/null 2>&1 && ss -lun | awk '$5 ~ /:53$/ {found=1} END {exit !found}'; then
    ah_err "UDP port 53 is already in use. Identify the DNS service before continuing."
    return 1
  fi

  local domain password
  read -r -p "Delegated tunnel DNS name (for example tunnel.example.com): " domain
  [[ "$domain" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]] || { ah_err "Enter a valid DNS name."; return 1; }
  read -r -s -p "Create a strong tunnel password (minimum 12 characters): " password
  echo
  [[ "$password" =~ ^[A-Za-z0-9_-]{12,64}$ ]] || { ah_err "Use 12-64 characters: letters, numbers, underscore, or dash only."; return 1; }

  install -d -m 700 /etc/africhome
  umask 077
  {
    printf 'DNS_DOMAIN=%s\n' "$domain"
    printf 'DNS_PASSWORD=%s\n' "$password"
  } > "$SD_ENV"
  chmod 600 "$SD_ENV"

  cat > "$SD_UNIT" <<'EOF'
[Unit]
Description=Africhome SlowDNS (iodine) tunnel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/africhome-slowdns.env
ExecStart=/bin/bash -c 'exec /usr/sbin/iodined -f -P "$DNS_PASSWORD" 10.77.0.1/24 "$DNS_DOMAIN"'
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SD_UNIT"
  systemctl daemon-reload
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow 53/udp || ah_warn "Could not add UDP 53 to UFW; open it manually."
  fi
  ah_info "Before starting, configure DNS delegation:"
  echo "  1. Create a nameserver such as ns1.example.com pointing to this VPS public IP."
  echo "  2. Add the required glue record at your registrar."
  echo "  3. Delegate $domain to that nameserver (NS record)."
  echo "  4. Ensure UDP port 53 is allowed by your VPS provider firewall."
  read -r -p "Have you completed DNS delegation and opened UDP 53? [y/N]: " ready
  if [[ "$ready" =~ ^[Yy]$ ]]; then
    systemctl enable --now africhome-slowdns
    ah_ok "SlowDNS service enabled. Check status before connecting clients."
  else
    ah_warn "Configuration saved but service not started. Complete DNS delegation, then use Start service."
  fi
}

sd_status() {
  ah_require_root || return 1
  if [[ ! -f "$SD_UNIT" ]]; then
    if command -v iodined >/dev/null 2>&1; then
      ah_info "Iodine is installed, but the Africhome SlowDNS server is not configured yet."
      echo "Next step: choose option 2 (Configure DNS tunnel server)."
    else
      ah_warn "Iodine is not installed. Choose option 1 (Install iodine) first."
    fi
    return 0
  fi
  systemctl --no-pager --full status africhome-slowdns || true
  echo
  journalctl -u africhome-slowdns -n 20 --no-pager 2>/dev/null || true
}

sd_client_help() {
  [[ -r "$SD_ENV" ]] || { ah_warn "Configure the SlowDNS server first."; return 1; }
  local domain
  domain="$(sed -n 's/^DNS_DOMAIN=//p' "$SD_ENV")"
  echo "Client requirements: install the iodine client on the remote device."
  echo "Connect the DNS tunnel with: sudo iodine -f $domain"
  echo "Then open SSH through the tunnel: ssh YOUR_SSH_USER@10.77.0.1"
  echo "The iodine password is the one set during server setup."
  echo "Do not share the password or expose it in public logs."
}

sd_remove() {
  ah_require_root || return 1
  read -r -p "Remove the Africhome SlowDNS service and its saved password? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 0
  systemctl disable --now africhome-slowdns 2>/dev/null || true
  rm -f "$SD_UNIT" "$SD_ENV"
  systemctl daemon-reload
  ah_ok "SlowDNS service files removed. UDP 53 firewall rule, if added, was left unchanged."
}

slowdns_menu() {
  while true; do
    echo
    echo "----- SlowDNS SSH (iodine) -----"
    echo "1) Install iodine"
    echo "2) Configure DNS tunnel server"
    echo "3) Start service"
    echo "4) Stop service"
    echo "5) Service status and logs"
    echo "6) Show client connection instructions"
    echo "7) Remove service configuration"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) sd_install; ah_pause ;;
      2) sd_setup; ah_pause ;;
      3) ah_require_root && systemctl enable --now africhome-slowdns; ah_pause ;;
      4) ah_require_root && systemctl disable --now africhome-slowdns; ah_pause ;;
      5) sd_status; ah_pause ;;
      6) sd_client_help; ah_pause ;;
      7) sd_remove; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
