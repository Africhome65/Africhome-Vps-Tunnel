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
  local backup_config="" backup_env="" port server_name public_ip uuid key_output private_key public_key short_id
  if [[ -e "$XRAY_CONFIG" ]]; then
    ah_warn "$XRAY_CONFIG already exists."
    read -r -p "Back it up and replace it with a new Africhome VLESS + REALITY configuration? [y/N]: " replace_config
    [[ "$replace_config" =~ ^[Yy]$ ]] || { ah_info "Existing Xray configuration was left unchanged."; return 1; }
    backup_config="${XRAY_CONFIG}.africhome-backup-$(date +%Y%m%d%H%M%S)"
    cp -a "$XRAY_CONFIG" "$backup_config" || { ah_err "Could not back up the existing Xray configuration."; return 1; }
    ah_ok "Existing configuration backed up to $backup_config"
  fi
  if [[ -e "$XRAY_ENV" ]]; then
    ah_warn "$XRAY_ENV already exists."
    read -r -p "Back up the existing Africhome credentials and generate fresh credentials? [y/N]: " rotate_env
    [[ "$rotate_env" =~ ^[Yy]$ ]] || { ah_info "Existing Africhome credentials were left unchanged."; return 1; }
    backup_env="${XRAY_ENV}.africhome-backup-$(date +%Y%m%d%H%M%S)"
    cp -a "$XRAY_ENV" "$backup_env" || { ah_err "Could not back up the existing credentials."; return 1; }
    ah_ok "Existing credentials backed up securely."
  fi

  read -r -p "VLESS REALITY TCP port [443]: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { ah_err "Invalid TCP port."; return 1; }
  read -r -p "REALITY SNI / server name (a hostname with a valid TLS service): " server_name
  [[ -n "$server_name" ]] || { ah_err "A REALITY SNI hostname is required."; return 1; }
  [[ "$server_name" =~ ^[A-Za-z0-9.-]+$ ]] || { ah_err "Invalid server name."; return 1; }

  uuid="$(xray uuid)" || { ah_err "Could not generate a client UUID."; return 1; }
  key_output="$(xray x25519 2>&1)" || { ah_err "Could not generate REALITY keys: $key_output"; return 1; }
  # Xray 26.x may label the client public key as "Password (PublicKey):".
  private_key="$(awk -F': *' '/PrivateKey:|Private key:/ {print $2; exit}' <<< "$key_output" | awk '{print $1}')"
  public_key="$(awk -F': *' '/^Password[[:space:]]*[(]PublicKey[)]:|^PublicKey:|^Public key:/ {print $2; exit}' <<< "$key_output" | awk '{print $1}')"
  [[ -n "$private_key" && -n "$public_key" ]] || { ah_err "Could not parse REALITY key output from this Xray version."; return 1; }
  short_id="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  read -r -p "Server address (your own domain or VPS public IP; never shared by Africhome): " public_ip
  [[ -n "$public_ip" && "$public_ip" =~ ^[A-Za-z0-9.-]+$ ]] || { ah_err "Enter a valid domain name or IPv4 address."; return 1; }

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
  chown root:xray "$XRAY_CONFIG"
  chmod 640 "$XRAY_CONFIG"
  if ! xray run -test -config "$XRAY_CONFIG"; then
    rm -f "$XRAY_CONFIG"
    [[ -z "$backup_config" ]] || cp -a "$backup_config" "$XRAY_CONFIG"
    ah_err "Xray rejected the generated configuration; the previous configuration was restored when available."
    return 1
  fi
  printf 'XRAY_PORT=%s\nXRAY_HOST=%s\nXRAY_UUID=%s\nXRAY_PUBLIC_KEY=%s\nXRAY_SHORT_ID=%s\nXRAY_SERVER_NAME=%s\n' \
    "$port" "$public_ip" "$uuid" "$public_key" "$short_id" "$server_name" > "$XRAY_ENV"
  chmod 600 "$XRAY_ENV"
  if ! systemctl enable xray || ! systemctl restart xray; then
    rm -f "$XRAY_CONFIG" "$XRAY_ENV"
    [[ -z "$backup_config" ]] || cp -a "$backup_config" "$XRAY_CONFIG"
    [[ -z "$backup_env" ]] || cp -a "$backup_env" "$XRAY_ENV"
    systemctl restart xray >/dev/null 2>&1 || true
    ah_err "Xray could not start with the new configuration. The previous configuration was restored when available."
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


xray_add_sni() {
  ah_require_root || return 1
  [[ -r "$XRAY_ENV" && -r "$XRAY_CONFIG" ]] || { ah_warn "Configure VLESS + REALITY first."; return 1; }
  command -v python3 >/dev/null 2>&1 || { ah_err "Python 3 is required to safely update the REALITY SNI list."; return 1; }
  read -r -p "Additional REALITY SNI hostname (DNS name only): " new_sni
  new_sni="${new_sni,,}"
  [[ "$new_sni" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$new_sni" != *..* ]] || { ah_err "Enter a valid DNS hostname."; return 1; }
  # shellcheck disable=SC1090
  . "$XRAY_ENV"
  local backup_config
  backup_config="${XRAY_CONFIG}.africhome-sni-backup-$(date +%Y%m%d%H%M%S)"
  cp -a "$XRAY_CONFIG" "$backup_config" || { ah_err "Could not back up the current Xray configuration."; return 1; }
  if ! python3 - "$XRAY_CONFIG" "$new_sni" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    config = json.load(f)
settings = config["inbounds"][0]["streamSettings"]["realitySettings"]
names = settings.get("serverNames", [])
if name not in names:
    names.append(name)
settings["serverNames"] = names
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\\n")
PY
  then
    cp -a "$backup_config" "$XRAY_CONFIG"
    ah_err "Could not update the SNI list; the previous configuration was restored."
    return 1
  fi
  chown root:xray "$XRAY_CONFIG"
  chmod 640 "$XRAY_CONFIG"
  if ! xray run -test -config "$XRAY_CONFIG"; then
    cp -a "$backup_config" "$XRAY_CONFIG"
    ah_err "Xray rejected the updated SNI list; the previous configuration was restored."
    return 1
  fi
  if ! systemctl restart xray; then
    cp -a "$backup_config" "$XRAY_CONFIG"
    systemctl restart xray >/dev/null 2>&1 || true
    ah_err "Xray failed to restart; the previous configuration was restored."
    return 1
  fi
  if grep -q '^XRAY_SERVER_NAME=' "$XRAY_ENV"; then
    sed -i "s/^XRAY_SERVER_NAME=.*/XRAY_SERVER_NAME=$new_sni/" "$XRAY_ENV"
  else
    printf 'XRAY_SERVER_NAME=%s\\n' "$new_sni" >> "$XRAY_ENV"
  fi
  chmod 600 "$XRAY_ENV"
  ah_ok "SNI hostname added and selected: $new_sni"
  ah_info "The client URI will now use this SNI. The REALITY destination remains unchanged."
  ah_warn "This hostname is accepted by Xray only; it must also be compatible with the configured REALITY destination to connect successfully."
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
    echo "7) Add/select an additional REALITY SNI"
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
      7) xray_add_sni; ah_pause ;;
      5) ah_require_root && systemctl enable --now xray; ah_pause ;;
      6) ah_require_root && systemctl disable --now xray; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
