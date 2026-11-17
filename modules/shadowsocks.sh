#!/usr/bin/env bash
# Shadowsocks AEAD inbound managed by Xray.
set -Eeuo pipefail

SS_CONFIG="/usr/local/etc/xray/config.json"
SS_STATE="/etc/africhome-shadowsocks.env"
SS_TAG="africhome-shadowsocks"

shadowsocks_add() {
  ah_require_root || return 1
  command -v xray >/dev/null 2>&1 || { ah_warn "Install Xray first."; return 1; }
  command -v jq >/dev/null 2>&1 || ah_apt_install jq || return 1
  command -v openssl >/dev/null 2>&1 || ah_apt_install openssl || return 1
  [[ -s "$SS_CONFIG" ]] || { ah_warn "Xray config not found. Configure Xray first."; return 1; }
  [[ ! -e "$SS_STATE" ]] || { ah_warn "Africhome Shadowsocks is already configured. Remove it before replacing."; return 1; }
  [[ "$(jq -r 'type' "$SS_CONFIG" 2>/dev/null)" == "object" ]] || { ah_err "Existing Xray config is not valid JSON."; return 1; }

  local host port method password backup tmp
  read -r -p "VPS public IP or DNS name: " host
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || { ah_err "Invalid server host."; return 1; }
  read -r -p "Shadowsocks port [8388]: " port
  port="${port:-8388}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { ah_err "Invalid port."; return 1; }
  method="aes-128-gcm"
  echo "Cipher: $method"
  if jq -e --argjson p "$port" 'any(.inbounds[]?; .port == $p)' "$SS_CONFIG" >/dev/null; then
    ah_err "Port $port is already used by an Xray inbound."; return 1
  fi
  password="$(openssl rand -hex 16)" || { ah_err "Could not generate password."; return 1; }
  backup="${SS_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  cp -a "$SS_CONFIG" "$backup"
  if ! jq --arg tag "$SS_TAG" --arg password "$password" --arg method "$method" --argjson port "$port" '
    .inbounds = ((.inbounds // []) + [{
      "tag": $tag,
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "shadowsocks",
      "settings": {"method": $method, "password": $password, "network": "tcp,udp"}
    }])
  ' "$SS_CONFIG" > "$tmp"; then
    rm -f "$tmp"; ah_err "Could not update Xray configuration."; return 1
  fi
  install -m 600 "$tmp" "$SS_CONFIG"
  rm -f "$tmp"
  if ! xray run -test -config "$SS_CONFIG"; then
    cp -a "$backup" "$SS_CONFIG"
    ah_err "Xray rejected the Shadowsocks configuration; previous config restored."
    return 1
  fi
  umask 077
  printf 'SS_HOST=%s\nSS_PORT=%s\nSS_METHOD=%s\nSS_PASSWORD=%s\n' "$host" "$port" "$method" "$password" > "$SS_STATE"
  chmod 600 "$SS_STATE"
  if ! systemctl restart xray; then
    cp -a "$backup" "$SS_CONFIG"
    systemctl restart xray || true
    rm -f "$SS_STATE"
    ah_err "Xray restart failed; previous config restored."
    return 1
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$port/tcp" || ah_warn "Could not add TCP $port to UFW."
    ufw allow "$port/udp" || ah_warn "Could not add UDP $port to UFW."
  fi
  ah_ok "Shadowsocks AEAD inbound configured."
  echo "Server: $host:$port"
  echo "Cipher: $method"
  ah_info "Open both TCP and UDP $port in the VPS provider firewall."
  ah_warn "Keep the generated client URI private."
}

shadowsocks_show_client() {
  [[ -r "$SS_STATE" ]] || { ah_warn "Configure Shadowsocks first."; return 1; }
  # shellcheck disable=SC1090
  . "$SS_STATE"
  local userinfo encoded
  userinfo="$(printf '%s' "$SS_METHOD:$SS_PASSWORD" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  encoded="ss://${userinfo}@${SS_HOST}:${SS_PORT}#Africhome-Shadowsocks"
  printf '\nShadowsocks client URI:\n%s\n' "$encoded"
  ah_warn "Treat this URI as a password. Do not share it publicly."
}

shadowsocks_status() {
  ah_require_root || return 1
  systemctl --no-pager --full status xray || true
  journalctl -u xray -n 20 --no-pager 2>/dev/null || true
}

shadowsocks_remove() {
  ah_require_root || return 1
  [[ -s "$SS_CONFIG" && -r "$SS_STATE" ]] || { ah_warn "Africhome Shadowsocks state was not found."; return 1; }
  read -r -p "Remove Africhome Shadowsocks inbound? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 0
  command -v jq >/dev/null 2>&1 || { ah_err "jq is required to safely edit Xray config."; return 1; }
  local backup tmp
  backup="${SS_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  cp -a "$SS_CONFIG" "$backup"
  if ! jq --arg tag "$SS_TAG" '.inbounds = [.inbounds[]? | select(.tag != $tag)]' "$SS_CONFIG" > "$tmp"; then
    rm -f "$tmp"; ah_err "Could not update Xray configuration."; return 1
  fi
  install -m 600 "$tmp" "$SS_CONFIG"
  rm -f "$tmp"
  if ! xray run -test -config "$SS_CONFIG" || ! systemctl restart xray; then
    cp -a "$backup" "$SS_CONFIG"
    systemctl restart xray || true
    ah_err "Could not safely remove Shadowsocks; previous config restored."
    return 1
  fi
  rm -f "$SS_STATE"
  ah_ok "Shadowsocks inbound removed. Firewall rules were left unchanged."
}

shadowsocks_menu() {
  while true; do
    echo
    echo "----- Shadowsocks Management -----"
    echo "1) Configure Shadowsocks inbound"
    echo "2) Show client URI"
    echo "3) Xray service status and logs"
    echo "4) Remove Shadowsocks inbound"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) shadowsocks_add; ah_pause ;;
      2) shadowsocks_show_client; ah_pause ;;
      3) shadowsocks_status; ah_pause ;;
      4) shadowsocks_remove; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
