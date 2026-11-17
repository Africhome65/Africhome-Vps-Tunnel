#!/usr/bin/env bash
# Africhome Xray: VLESS + REALITY (TCP). Does not overwrite an existing Xray config.
set -Eeuo pipefail

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_ENV="/etc/africhome-xray.env"

xray_install() {
  ah_require_root || return 1
  command -v curl >/dev/null 2>&1 || ah_apt_install curl ca-certificates || return 1
  local tmp
  tmp="$(mktemp)"
  ah_info "Downloading the official XTLS Xray installation script..."
  if ! curl -fsSL --retry 3 https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp"; then
    rm -f "$tmp"; ah_err "Could not download the Xray installer."; return 1
  fi
  if ! bash "$tmp" install; then
    rm -f "$tmp"; ah_err "Xray installation failed."; return 1
  fi
  rm -f "$tmp"
  command -v xray >/dev/null 2>&1 || { ah_err "Xray binary was not found after installation."; return 1; }
  ah_ok "Xray installed."
}

xray_setup_vless_reality() {
  ah_require_root || return 1
  command -v xray >/dev/null 2>&1 || { ah_warn "Install Xray first."; return 1; }
  [[ ! -e "$XRAY_CONFIG" ]] || { ah_warn "$XRAY_CONFIG already exists. Existing configuration was not changed."; return 1; }

  local port server_name public_ip uuid key_output private_key public_key short_id
  read -r -p "VLESS REALITY TCP port [443]: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { ah_err "Invalid TCP port."; return 1; }
  read -r -p "REALITY server name [www.microsoft.com]: " server_name
  server_name="${server_name:-www.microsoft.com}"
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+$ ]] || { ah_err "Invalid server name."; return 1; }

  uuid="$(xray uuid)" || { ah_err "Could not generate a client UUID."; return 1; }
  key_output="$(xray x25519 2>&1)" || { ah_err "Could not generate REALITY keys: $key_output"; return 1; }
  private_key="$(awk -F': *' '/PrivateKey:/ {print $2; exit}' <<< "$key_output")"
  public_key="$(awk -F': *' '/Password:|PublicKey:/ {print $2; exit}' <<< "$key_output")"
  [[ -n "$private_key" && -n "$public_key" ]] || { ah_err "Could not parse REALITY key output from this Xray version."; return 1; }
  short_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  public_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$public_ip" ]]; then
    read -r -p "Enter VPS public IP or DNS name: " public_ip
  fi
  [[ "$public_ip" =~ ^[A-Za-z0-9.-]+$ ]] || { ah_err "Invalid endpoint host."; return 1; }

  install -d -m 755 /usr/local/etc/xray /etc/africhome
  umask 077
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $port,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$uuid", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$server_name:443",
        "xver": 0,
        "serverNames": ["$server_name"],
        "privateKey": "$private_key",
        "shortIds": ["$short_id"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  chmod 600 "$XRAY_CONFIG"
  if ! xray run -test -config "$XRAY_CONFIG"; then
    rm -f "$XRAY_CONFIG"
    ah_err "Xray rejected the generated configuration; no service was started."
    return 1
  fi
  printf 'XRAY_PORT=%s\nXRAY_HOST=%s\nXRAY_UUID=%s\nXRAY_PUBLIC_KEY=%s\nXRAY_SHORT_ID=%s\nXRAY_SERVER_NAME=%s\n' \
    "$port" "$public_ip" "$uuid" "$public_key" "$short_id" "$server_name" > "$XRAY_ENV"
  chmod 600 "$XRAY_ENV"
  if ! systemctl enable xray || ! systemctl restart xray; then
    rm -f "$XRAY_CONFIG" "$XRAY_ENV"
    ah_err "Xray could not start with the new configuration. The generated config and saved credentials were removed."
    return 1
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$port/tcp" || ah_warn "Could not add TCP $port to UFW; open it manually."
  fi
  ah_ok "VLESS + REALITY service configured."
  echo "Server: $public_ip:$port"
  echo "Client UUID: $uuid"
  echo "Public key: $public_key"
  echo "Short ID: $short_id"
  echo "SNI: $server_name"
  echo "Flow: xtls-rprx-vision"
  ah_info "Also allow TCP $port in your VPS provider firewall."
  ah_warn "Keep the client UUID and server details private. Test from an external network."
}

xray_status() {
  ah_require_root || return 1
  systemctl --no-pager --full status xray || true
  echo
  journalctl -u xray -n 30 --no-pager 2>/dev/null || true
}

xray_show_client() {
  [[ -r "$XRAY_ENV" ]] || { ah_warn "Set up VLESS REALITY first."; return 1; }
  # shellcheck disable=SC1090
  . "$XRAY_ENV"
  printf '\nClient URI (import into a compatible Xray client):\n'
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#Africhome-VLESS\n' \
    "$XRAY_UUID" "$XRAY_HOST" "$XRAY_PORT" "$XRAY_SERVER_NAME" "$XRAY_PUBLIC_KEY" "$XRAY_SHORT_ID"
  ah_warn "Treat this URI as a credential: anyone holding it can use the account."
}

xray_menu() {
  while true; do
    echo
    echo "----- Xray Management -----"
    echo "1) Install Xray"
    echo "2) Configure VLESS + REALITY"
    echo "3) Show client import URI"
    echo "4) Service status and logs"
    echo "5) Start Xray"
    echo "6) Stop Xray"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) xray_install; ah_pause ;;
      2) xray_setup_vless_reality; ah_pause ;;
      3) xray_show_client; ah_pause ;;
      4) xray_status; ah_pause ;;
      5) ah_require_root && systemctl enable --now xray; ah_pause ;;
      6) ah_require_root && systemctl disable --now xray; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
