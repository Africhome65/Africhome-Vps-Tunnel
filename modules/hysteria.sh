#!/usr/bin/env bash
# Hysteria 2 server with a user-supplied domain and UDP port/range.
set -Eeuo pipefail
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_STATE="/etc/africhome-hysteria.env"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_HOOK="/etc/letsencrypt/renewal-hooks/deploy/africhome-hysteria.sh"

hy2_valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" != *..* && "$1" != *.-* && "$1" != *-.* ]]
}
hy2_valid_port_spec() {
  local spec="$1" first last
  if [[ "$spec" =~ ^[0-9]{1,5}$ ]]; then
    first="$spec"
    (( 10#$first >= 1 && 10#$first <= 65535 )) || return 1
  elif [[ "$spec" =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]]; then
    IFS=- read -r first last <<< "$spec"
    (( 10#$first >= 1 && 10#$first < 65535 && 10#$last <= 65535 && 10#$last > 10#$first )) || return 1
  else
    return 1
  fi
}

hy2_install() {
  ah_require_root || return 1
  command -v curl >/dev/null 2>&1 || ah_apt_install curl ca-certificates || return 1
  ah_info "Installing/updating Hysteria 2 with the official installer..."
  bash <(curl -fsSL https://get.hy2.sh/) || { ah_err "Official Hysteria installer failed."; return 1; }
  command -v hysteria >/dev/null 2>&1 || { ah_err "Hysteria binary was not found."; return 1; }
  ah_ok "Hysteria 2 installed."
}

hy2_setup() {
  ah_require_root || return 1
  command -v hysteria >/dev/null 2>&1 || { ah_warn "Install Hysteria 2 first."; return 1; }
  command -v certbot >/dev/null 2>&1 || ah_apt_install certbot || return 1
  command -v ss >/dev/null 2>&1 || ah_apt_install iproute2 || return 1
  command -v openssl >/dev/null 2>&1 || ah_apt_install openssl || return 1
  local domain email port_spec first_port last_port ufw_port_spec username password backup="" config_tmp hook_tmp replace
  read -r -p "Your domain (DNS A/AAAA must point to this VPS): " domain
  domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
  hy2_valid_domain "$domain" || { ah_err "Invalid domain name."; return 1; }
  read -r -p "UDP port or port-hopping range [443]: " port_spec
  [[ -n "$port_spec" ]] || port_spec="443"
  hy2_valid_port_spec "$port_spec" || { ah_err "Use a UDP port 1-65535 or range such as 20000-30000."; return 1; }
  first_port="$(printf '%s' "$port_spec" | cut -d- -f1)"
  last_port="$(printf '%s' "$port_spec" | awk -F- '{print $NF}')"
  ufw_port_spec="$port_spec"
  if [[ "$port_spec" == *-* ]]; then
    ufw_port_spec="$first_port:$last_port"
    if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
      ah_info "Installing nftables for Hysteria port hopping..."
      ah_apt_install nftables || return 1
    fi
  fi
  read -r -p "Email for Let's Encrypt: " email
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { ah_err "Enter a valid email address."; return 1; }
  read -r -p "Hysteria username [africhome]: " username
  [[ -n "$username" ]] || username="africhome"
  [[ "$username" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { ah_err "Invalid username."; return 1; }
  password="$(openssl rand -hex 24)" || { ah_err "Could not generate password."; return 1; }

  if [[ -e "$HY2_CONFIG" ]]; then
    backup="$HY2_CONFIG.africhome-backup-$(date +%Y%m%d%H%M%S)"
    cp -a "$HY2_CONFIG" "$backup" || { ah_err "Could not back up existing Hysteria config."; return 1; }
    ah_warn "Existing config backup: $backup"
    read -r -p "Replace existing Hysteria config? [y/N]: " replace
    [[ "$replace" =~ ^[Yy]$ ]] || { ah_info "Existing config left unchanged."; return 1; }
  fi
  if ss -H -lunp 2>/dev/null | awk -v first="$first_port" -v last="$last_port" '
    /hysteria/ {next}
    { localport=$4; sub(/^.*:/, "", localport); if (localport ~ /^[0-9]+$/ && localport >= first && localport <= last) found=1 }
    END {exit !found}
  '; then
    ah_err "A UDP listener already uses a port in $port_spec. Choose another range."
    return 1
  fi
  if ss -H -ltn 2>/dev/null | awk '$4 ~ /:80$/ {found=1} END{exit !found}'; then
    ah_err "TCP port 80 is busy. Stop the conflicting web server before requesting a certificate."
    return 1
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow 80/tcp || ah_warn "Could not add TCP 80 to UFW; certificate issuance/renewal may fail."
  fi
  ah_info "Requesting a certificate. DNS must point to this VPS and inbound TCP 80 must be reachable."
  certbot certonly --standalone --non-interactive --agree-tos --email "$email" -d "$domain" || {
    ah_err "Certificate issuance failed. Check DNS and TCP 80 in UFW/provider firewall."; return 1;
  }
  [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" && -s "/etc/letsencrypt/live/$domain/privkey.pem" ]] || {
    ah_err "Certificate files were not created."; return 1;
  }
  getent passwd hysteria >/dev/null 2>&1 || { ah_err "Hysteria service user missing. Re-run the official installer."; return 1; }
  install -d -o hysteria -g hysteria -m 750 "$HY2_CERT_DIR"
  install -o hysteria -g hysteria -m 640 "/etc/letsencrypt/live/$domain/fullchain.pem" "$HY2_CERT_DIR/fullchain.pem"
  install -o hysteria -g hysteria -m 640 "/etc/letsencrypt/live/$domain/privkey.pem" "$HY2_CERT_DIR/privkey.pem"

  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  hook_tmp="$(mktemp)"
  cat > "$hook_tmp" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
DOMAIN="@@DOMAIN@@"
DEST="/etc/hysteria/certs"
SRC="/etc/letsencrypt/live/$DOMAIN"
[[ -s "$SRC/fullchain.pem" && -s "$SRC/privkey.pem" ]] || exit 1
install -d -o hysteria -g hysteria -m 750 "$DEST"
tmp_cert="$(mktemp "$DEST/.fullchain.XXXXXX")"
tmp_key="$(mktemp "$DEST/.privkey.XXXXXX")"
trap 'rm -f "$tmp_cert" "$tmp_key"' EXIT
install -o hysteria -g hysteria -m 640 "$SRC/fullchain.pem" "$tmp_cert"
install -o hysteria -g hysteria -m 640 "$SRC/privkey.pem" "$tmp_key"
mv -f "$tmp_cert" "$DEST/fullchain.pem"
mv -f "$tmp_key" "$DEST/privkey.pem"
systemctl restart hysteria-server.service
HOOK
  sed "s/@@DOMAIN@@/$domain/g" "$hook_tmp" > "$HY2_HOOK"
  rm -f "$hook_tmp"
  chmod 750 "$HY2_HOOK"

  config_tmp="$(mktemp)"
  cat > "$config_tmp" <<EOF
listen: :$port_spec
tls:
  cert: $HY2_CERT_DIR/fullchain.pem
  key: $HY2_CERT_DIR/privkey.pem
auth:
  type: userpass
  userpass:
    $username: $password
EOF
  install -o root -g root -m 600 "$config_tmp" "$HY2_CONFIG"
  rm -f "$config_tmp"
  if ! systemctl daemon-reload || ! systemctl enable hysteria-server.service || ! systemctl restart hysteria-server.service; then
    ah_err "Hysteria failed to start. Restoring the previous configuration when available."
    if [[ -n "$backup" && -s "$backup" ]]; then
      cp -a "$backup" "$HY2_CONFIG"
      systemctl restart hysteria-server.service || true
    fi
    return 1
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$ufw_port_spec/udp" || ah_warn "Could not add UDP $port_spec to UFW."
  fi
  umask 077
  printf 'HY2_DOMAIN=%q\nHY2_PORT_SPEC=%q\nHY2_USERNAME=%q\nHY2_PASSWORD=%q\n' "$domain" "$port_spec" "$username" "$password" > "$HY2_STATE"
  chmod 600 "$HY2_STATE"
  ah_ok "Hysteria 2 configured and running."
  echo "Domain: $domain"
  echo "UDP port/range: $port_spec"
  echo "Username: $username"
  echo "Password: $password"
  ah_info "Open UDP $port_spec in your VPS provider firewall too."
  [[ "$port_spec" != *-* ]] || ah_info "Port hopping requires nftables/iptables and CAP_NET_ADMIN; the official systemd unit includes the required capabilities."
  ah_warn "Save the password securely. Never commit client credentials to Git."
}

hy2_show_client() {
  [[ -r "$HY2_STATE" ]] || { ah_warn "Configure Hysteria 2 first."; return 1; }
  # shellcheck disable=SC1090
  . "$HY2_STATE"
  echo
  printf 'hysteria2://%s:%s@%s:%s/?sni=%s#Africhome-Hysteria2\n' "$HY2_USERNAME" "$HY2_PASSWORD" "$HY2_DOMAIN" "$HY2_PORT_SPEC" "$HY2_DOMAIN"
  ah_warn "This URI contains the account password. Keep it private. Configure the same port range in a compatible client when using port hopping."
}
hy2_status() {
  ah_require_root || return 1
  systemctl --no-pager --full status hysteria-server.service || true
  journalctl -u hysteria-server.service -n 30 --no-pager 2>/dev/null || true
}
hy2_menu() {
  while true; do
    echo
    echo "----- Hysteria 2 Management -----"
    echo "1) Install/update Hysteria 2"
    echo "2) Configure custom domain and UDP port/range"
    echo "3) Show client import URI"
    echo "4) Service status and logs"
    echo "5) Restart Hysteria 2"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) hy2_install; ah_pause ;;
      2) hy2_setup; ah_pause ;;
      3) hy2_show_client; ah_pause ;;
      4) hy2_status; ah_pause ;;
      5) ah_require_root && systemctl restart hysteria-server.service; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
