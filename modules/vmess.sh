#!/usr/bin/env bash
# VMess over WebSocket + TLS. Requires an existing Xray installation and valid TLS cert.
set -Eeuo pipefail

VMESS_CONFIG="/usr/local/etc/xray/config.json"
VMESS_STATE="/etc/africhome-vmess.env"
VMESS_TAG="africhome-vmess-ws-tls"

vmess_add() {
  ah_require_root || return 1
  command -v xray >/dev/null 2>&1 || { ah_warn "Install Xray first."; return 1; }
  command -v jq >/dev/null 2>&1 || ah_apt_install jq || return 1
  [[ -s "$VMESS_CONFIG" ]] || { ah_warn "Xray config not found. Configure Xray first."; return 1; }
  [[ ! -e "$VMESS_STATE" ]] || { ah_warn "Africhome VMess is already configured. Remove it before replacing."; return 1; }

  local domain port cert key path uuid backup tmp
  read -r -p "VMess TLS domain (must match certificate): " domain
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || { ah_err "Invalid domain."; return 1; }
  read -r -p "VMess WebSocket TLS port [8443]: " port
  port="${port:-8443}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { ah_err "Invalid port."; return 1; }
  read -r -p "TLS certificate full path: " cert
  read -r -p "TLS private key full path: " key
  [[ -s "$cert" && -s "$key" ]] || { ah_err "Certificate or private key file does not exist."; return 1; }
  read -r -p "WebSocket path [/vmess]: " path
  path="${path:-/vmess}"
  [[ "$path" == /* && "$path" != *[[:space:]]* ]] || { ah_err "Path must start with / and contain no spaces."; return 1; }
  [[ "$(jq -r 'type' "$VMESS_CONFIG" 2>/dev/null)" == "object" ]] || { ah_err "Existing Xray config is not valid JSON."; return 1; }
  if jq -e --argjson p "$port" 'any(.inbounds[]?; .port == $p)' "$VMESS_CONFIG" >/dev/null; then
    ah_err "Port $port is already used by an Xray inbound."; return 1
  fi
  uuid="$(xray uuid)" || { ah_err "Could not generate UUID."; return 1; }
  backup="${VMESS_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  cp -a "$VMESS_CONFIG" "$backup"
  if ! jq --arg tag "$VMESS_TAG" --arg uuid "$uuid" --argjson port "$port" --arg cert "$cert" --arg key "$key" --arg path "$path" '
    .inbounds = ((.inbounds // []) + [{
      "tag": $tag,
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vmess",
      "settings": {"clients": [{"id": $uuid, "alterId": 0}]},
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {"certificates": [{"certificateFile": $cert, "keyFile": $key}]},
        "wsSettings": {"path": $path}
      }
    }])
  ' "$VMESS_CONFIG" > "$tmp"; then
    rm -f "$tmp"; ah_err "Could not update Xray configuration."; return 1
  fi
  install -m 640 -o root -g xray "$tmp" "$VMESS_CONFIG"
  rm -f "$tmp"
  if ! xray run -test -config "$VMESS_CONFIG"; then
    cp -a "$backup" "$VMESS_CONFIG"
    ah_err "Xray rejected the VMess configuration; previous config restored."
    return 1
  fi
  umask 077
  printf 'VMESS_DOMAIN=%s\nVMESS_PORT=%s\nVMESS_UUID=%s\nVMESS_PATH=%s\n' "$domain" "$port" "$uuid" "$path" > "$VMESS_STATE"
  chmod 600 "$VMESS_STATE"
  if ! systemctl restart xray; then
    cp -a "$backup" "$VMESS_CONFIG"
    systemctl restart xray || true
    rm -f "$VMESS_STATE"
    ah_err "Xray restart failed; previous config restored."
    return 1
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$port/tcp" || ah_warn "Could not add TCP $port to UFW; open it manually."
  fi
  ah_ok "VMess WebSocket + TLS inbound configured."
  echo "Domain: $domain"
  echo "Port: $port"
  echo "UUID: $uuid"
  echo "WebSocket path: $path"
  ah_info "Open TCP $port in your VPS provider firewall. Ensure DNS points to this VPS and certificate renewal is configured."
  ah_warn "Client credentials are sensitive. Test TLS and connection from an external network."
}

vmess_show_client() {
  [[ -r "$VMESS_STATE" ]] || { ah_warn "Configure VMess first."; return 1; }
  # shellcheck disable=SC1090
  . "$VMESS_STATE"
  local payload encoded
  payload="$(jq -cn --arg add "$VMESS_DOMAIN" --arg port "$VMESS_PORT" --arg id "$VMESS_UUID" --arg path "$VMESS_PATH" '{
    v:"2", ps:"Africhome-VMess", add:$add, port:$port, id:$id, aid:"0",
    scy:"auto", net:"ws", type:"none", host:$add, path:$path, tls:"tls", sni:$add, alpn:"http/1.1"
  }')"
  encoded="$(printf '%s' "$payload" | base64 -w0)"
  printf '\nVMess import URI:\nvmess://%s\n' "$encoded"
  ah_warn "Treat this URI as a password. Do not share it publicly."
}

vmess_status() {
  ah_require_root || return 1
  systemctl --no-pager --full status xray || true
  journalctl -u xray -n 20 --no-pager 2>/dev/null || true
}

vmess_remove() {
  ah_require_root || return 1
  [[ -s "$VMESS_CONFIG" && -r "$VMESS_STATE" ]] || { ah_warn "Africhome VMess state was not found."; return 1; }
  read -r -p "Remove Africhome VMess inbound? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 0
  command -v jq >/dev/null 2>&1 || { ah_err "jq is required to safely edit Xray config."; return 1; }
  local backup tmp
  backup="${VMESS_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  cp -a "$VMESS_CONFIG" "$backup"
  jq --arg tag "$VMESS_TAG" '.inbounds = [.inbounds[]? | select(.tag != $tag)]' "$VMESS_CONFIG" > "$tmp"
  install -m 640 -o root -g xray "$tmp" "$VMESS_CONFIG"
  rm -f "$tmp"
  if ! xray run -test -config "$VMESS_CONFIG" || ! systemctl restart xray; then
    cp -a "$backup" "$VMESS_CONFIG"
    systemctl restart xray || true
    ah_err "Could not safely remove VMess; previous config restored."
    return 1
  fi
  rm -f "$VMESS_STATE"
  ah_ok "VMess inbound removed. Firewall rule was left unchanged."
}

vmess_shared_443_candidate() {
  ah_require_root || return 1
  command -v python3 >/dev/null 2>&1 || { ah_err "Python 3 is required."; return 1; }
  command -v xray >/dev/null 2>&1 || { ah_err "Install Xray first."; return 1; }
  command -v openssl >/dev/null 2>&1 || { ah_err "OpenSSL is required to verify the TLS certificate/key."; return 1; }
  [[ -s "$VMESS_CONFIG" && ! -L "$VMESS_CONFIG" ]] || { ah_err "Xray config must be a regular non-symlink file."; return 1; }
  local script_dir domain cert key path vmess_port reality_port uuid output_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ -r "$script_dir/scripts/license.sh" ]] || { ah_err "Licence verifier is missing."; return 1; }
  bash "$script_dir/scripts/license.sh" verify || return 1
  read -r -p "VMess SNI domain (must match TLS certificate): " domain
  read -r -p "TLS certificate full path: " cert
  read -r -p "TLS private key full path: " key
  read -r -p "WebSocket path [/vmess]: " path
  path="${path:-/vmess}"
  read -r -p "VMess loopback backend port [8443]: " vmess_port
  vmess_port="${vmess_port:-8443}"
  read -r -p "VLESS REALITY loopback backend port [1443]: " reality_port
  reality_port="${reality_port:-1443}"
  [[ "$vmess_port" =~ ^[0-9]+$ && "$reality_port" =~ ^[0-9]+$ ]] || { ah_err "Backend ports must be numeric."; return 1; }
  uuid="$(xray uuid)" || { ah_err "Could not generate VMess UUID."; return 1; }
  output_dir="/root/africhome-vmess-shared443-candidate-$(date +%Y%m%d%H%M%S)"
  python3 "$script_dir/scripts/render-vmess-shared-443.py" "$VMESS_CONFIG" \
    --vmess-domain "$domain" --vmess-uuid "$uuid" --certificate "$cert" --private-key "$key" \
    --ws-path "$path" --vmess-backend-port "$vmess_port" --reality-backend-port "$reality_port" \
    --output-dir "$output_dir" || return 1
  if ! xray run -test -config "$output_dir/xray-config.json"; then
    ah_err "Xray rejected the candidate. Active config and services were not changed."
    return 1
  fi
  if command -v haproxy >/dev/null 2>&1; then
    if ! haproxy -c -f "$output_dir/haproxy-443.cfg"; then
      ah_err "HAProxy rejected the candidate. Active config and services were not changed."
      return 1
    fi
  else
    ah_warn "HAProxy is not installed; the candidate was rendered but not syntax-checked by HAProxy."
  fi
  ah_ok "Shared TCP 443 candidate generated and validated without live changes."
  echo "Candidate directory: $output_dir"
  echo "VMess client details: $output_dir/client-details.txt"
  echo "Xray candidate: $output_dir/xray-config.json"
  echo "HAProxy candidate: $output_dir/haproxy-443.cfg"
  ah_warn "This is a review-only candidate. External VLESS REALITY and VMess client tests are still required before applying it."
}

vmess_menu() {
  while true; do
    echo
    echo "----- VMess Management (WebSocket + TLS) -----"
    echo "1) Configure VMess inbound"
    echo "2) Show client import URI"
    echo "3) Xray service status and logs"
    echo "4) Remove VMess inbound"
    echo "5) Generate shared TCP 443 candidate (no live changes)"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) vmess_add; ah_pause ;;
      2) vmess_show_client; ah_pause ;;
      3) vmess_status; ah_pause ;;
      4) vmess_remove; ah_pause ;;
      5) vmess_shared_443_candidate; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
