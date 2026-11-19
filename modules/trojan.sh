#!/usr/bin/env bash
# Trojan over TLS inbound for an existing Xray installation.
set -Eeuo pipefail

TROJAN_CONFIG="/usr/local/etc/xray/config.json"
TROJAN_STATE="/etc/africhome-trojan.env"
TROJAN_TAG="africhome-trojan-tls"

trojan_add() {
  ah_require_root || return 1
  command -v xray >/dev/null 2>&1 || { ah_warn "Install Xray first."; return 1; }
  command -v jq >/dev/null 2>&1 || ah_apt_install jq || return 1
  command -v openssl >/dev/null 2>&1 || ah_apt_install openssl || return 1
  [[ -s "$TROJAN_CONFIG" ]] || { ah_warn "Xray config not found. Configure Xray first."; return 1; }
  [[ ! -e "$TROJAN_STATE" ]] || { ah_warn "Africhome Trojan is already configured. Remove it before replacing."; return 1; }
  [[ "$(jq -r 'type' "$TROJAN_CONFIG" 2>/dev/null)" == "object" ]] || { ah_err "Existing Xray config is not valid JSON."; return 1; }

  local domain port cert key password backup tmp
  read -r -p "Trojan TLS domain (must match certificate): " domain
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || { ah_err "Invalid domain."; return 1; }
  read -r -p "Trojan TLS port [8443]: " port
  port="${port:-8443}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { ah_err "Invalid port."; return 1; }
  read -r -p "TLS certificate full path: " cert
  read -r -p "TLS private key full path: " key
  [[ -s "$cert" && -s "$key" ]] || { ah_err "Certificate or private key file does not exist."; return 1; }
  if jq -e --argjson p "$port" 'any(.inbounds[]?; .port == $p)' "$TROJAN_CONFIG" >/dev/null; then
    ah_err "Port $port is already used by an Xray inbound."; return 1
  fi

  password="$(openssl rand -hex 24)" || { ah_err "Could not generate a password."; return 1; }
  backup="${TROJAN_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  cp -a "$TROJAN_CONFIG" "$backup"
  if ! jq --arg tag "$TROJAN_TAG" --arg password "$password" --argjson port "$port" --arg cert "$cert" --arg key "$key" '
    .inbounds = ((.inbounds // []) + [{
      "tag": $tag,
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "trojan",
      "settings": {"clients": [{"password": $password}], "fallbacks": []},
      "streamSettings": {
        "network": "raw",
        "security": "tls",
        "tlsSettings": {"certificates": [{"certificateFile": $cert, "keyFile": $key}]}
      }
    }])
  ' "$TROJAN_CONFIG" > "$tmp"; then
    rm -f "$tmp"; ah_err "Could not update Xray configuration."; return 1
  fi
  install -m 640 -o root -g xray "$tmp" "$TROJAN_CONFIG"
  rm -f "$tmp"
  if ! xray run -test -config "$TROJAN_CONFIG"; then
    cp -a "$backup" "$TROJAN_CONFIG"
    ah_err "Xray rejected the Trojan configuration; previous config restored."
    return 1
  fi

  umask 077
  printf 'TROJAN_DOMAIN=%s\nTROJAN_PORT=%s\nTROJAN_PASSWORD=%s\n' "$domain" "$port" "$password" > "$TROJAN_STATE"
  chmod 600 "$TROJAN_STATE"
  if ! systemctl restart xray; then
    cp -a "$backup" "$TROJAN_CONFIG"
    systemctl restart xray || true
    rm -f "$TROJAN_STATE"
    ah_err "Xray restart failed; previous config restored."
    return 1
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$port/tcp" || ah_warn "Could not add TCP $port to UFW; open it manually."
  fi
  ah_ok "Trojan over TLS inbound configured."
  echo "Domain: $domain"
  echo "Port: $port"
  echo "Password: $password"
  ah_info "Open TCP $port in your VPS provider firewall and ensure DNS points to this VPS."
  ah_warn "Keep the password private. The module uses an existing certificate; it does not issue or renew TLS certificates."
}

trojan_show_client() {
  [[ -r "$TROJAN_STATE" ]] || { ah_warn "Configure Trojan first."; return 1; }
  # shellcheck disable=SC1090
  . "$TROJAN_STATE"
  printf '\nTrojan client URI:\n'
  printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=tcp#Africhome-Trojan\n' "$TROJAN_PASSWORD" "$TROJAN_DOMAIN" "$TROJAN_PORT" "$TROJAN_DOMAIN"
  ah_warn "Treat this URI as a password. Do not share it publicly."
}

trojan_status() {
  ah_require_root || return 1
  systemctl --no-pager --full status xray || true
  journalctl -u xray -n 20 --no-pager 2>/dev/null || true
}

trojan_remove() {
  ah_require_root || return 1
  [[ -s "$TROJAN_CONFIG" && -r "$TROJAN_STATE" ]] || { ah_warn "Africhome Trojan state was not found."; return 1; }
  read -r -p "Remove Africhome Trojan inbound? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 0
  command -v jq >/dev/null 2>&1 || { ah_err "jq is required to safely edit Xray config."; return 1; }
  local backup tmp
  backup="${TROJAN_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  cp -a "$TROJAN_CONFIG" "$backup"
  if ! jq --arg tag "$TROJAN_TAG" '.inbounds = [.inbounds[]? | select(.tag != $tag)]' "$TROJAN_CONFIG" > "$tmp"; then
    rm -f "$tmp"; ah_err "Could not update Xray configuration."; return 1
  fi
  install -m 640 -o root -g xray "$tmp" "$TROJAN_CONFIG"
  rm -f "$tmp"
  if ! xray run -test -config "$TROJAN_CONFIG" || ! systemctl restart xray; then
    cp -a "$backup" "$TROJAN_CONFIG"
    systemctl restart xray || true
    ah_err "Could not safely remove Trojan; previous config restored."
    return 1
  fi
  rm -f "$TROJAN_STATE"
  ah_ok "Trojan inbound removed. Firewall rule was left unchanged."
}

trojan_menu() {
  while true; do
    echo
    echo "----- Trojan Management (TLS) -----"
    echo "1) Configure Trojan inbound"
    echo "2) Show client URI"
    echo "3) Xray service status and logs"
    echo "4) Remove Trojan inbound"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) trojan_add; ah_pause ;;
      2) trojan_show_client; ah_pause ;;
      3) trojan_status; ah_pause ;;
      4) trojan_remove; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
