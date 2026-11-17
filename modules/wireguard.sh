#!/usr/bin/env bash
# WireGuard server and peer management for Africhome VPS Tunnel.
set -Eeuo pipefail

WG_CONF="/etc/wireguard/wg0.conf"
WG_CLIENT_DIR="/root/africhome-wireguard-clients"
WG_PORT="51820"
WG_NET_PREFIX="10.66.66"
WG_SERVER_ADDR="10.66.66.1/24"

wg_require_tools() {
  ah_require_root || return 1
  command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1 || {
    ah_warn "WireGuard is not installed. Choose Install WireGuard first."
    return 1
  }
}

wg_install() {
  ah_require_root || return 1
  ah_info "Installing WireGuard and required networking tools..."
  ah_apt_install wireguard wireguard-tools iptables curl || return 1
  install -d -m 700 /etc/wireguard "$WG_CLIENT_DIR"
  ah_ok "WireGuard packages installed."
}

wg_setup_server() {
  ah_require_root || return 1
  command -v wg >/dev/null 2>&1 || { ah_warn "Install WireGuard first."; return 1; }
  if [[ -e "$WG_CONF" ]]; then
    ah_warn "$WG_CONF already exists. Existing configuration was not changed."
    return 1
  fi

  local wan_if public_ip server_priv server_pub
  wan_if="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  [[ -n "$wan_if" ]] || { ah_err "Could not detect the internet-facing network interface."; return 1; }
  public_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$public_ip" ]]; then
    read -r -p "Enter this VPS public IPv4 address: " public_ip
  else
    read -r -p "Detected public IPv4 $public_ip. Press Enter to use it or type another: " answer
    [[ -n "$answer" ]] && public_ip="$answer"
  fi
  [[ "$public_ip" =~ ^[0-9a-fA-F:.]+$ ]] || { ah_err "The endpoint must be an IP address."; return 1; }
  read -r -p "WireGuard UDP port [$WG_PORT]: " answer
  [[ -n "$answer" ]] && WG_PORT="$answer"
  [[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) || { ah_err "Invalid UDP port."; return 1; }

  install -d -m 700 /etc/wireguard "$WG_CLIENT_DIR"
  umask 077
  server_priv="$(wg genkey)"
  server_pub="$(printf '%s' "$server_priv" | wg pubkey)"
  printf '%s\n' "$server_priv" > /etc/wireguard/server_private.key
  printf '%s\n' "$server_pub" > /etc/wireguard/server_public.key
  cat > "$WG_CONF" <<EOF
[Interface]
Address = $WG_SERVER_ADDR
ListenPort = $WG_PORT
PrivateKey = $server_priv
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $wan_if -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $wan_if -j MASQUERADE
EOF
  chmod 600 "$WG_CONF" /etc/wireguard/server_private.key
  printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-africhome-wireguard.conf
  sysctl --system >/dev/null
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$WG_PORT/udp" || ah_warn "Could not add the WireGuard port to UFW; open it manually."
  fi
  systemctl enable wg-quick@wg0
  systemctl start wg-quick@wg0
  ah_ok "WireGuard server started on UDP $WG_PORT."
  printf 'Server public key: %s\nEndpoint: %s:%s\n' "$server_pub" "$public_ip" "$WG_PORT"
  ah_info "Also allow UDP $WG_PORT in your VPS provider/cloud firewall."
  WG_ENDPOINT="$public_ip"
  printf '%s\n' "$public_ip" > /etc/wireguard/server_endpoint
  printf '%s\n' "$WG_PORT" > /etc/wireguard/server_port
}

wg_next_client_ip() {
  local used
  used="$(grep -Eo '10\.66\.66\.[0-9]+' "$WG_CONF" 2>/dev/null | sort -Vu || true)"
  local n
  for n in $(seq 2 254); do
    if ! grep -q "10.66.66.$n" <<< "$used"; then
      printf '10.66.66.%s' "$n"
      return 0
    fi
  done
  return 1
}

wg_add_client() {
  wg_require_tools || return 1
  systemctl is-active --quiet wg-quick@wg0 || { ah_warn "Set up and start the WireGuard server first."; return 1; }
  local name ip client_priv client_pub server_pub endpoint port psk
  local backup server_tmp client_tmp
  read -r -p "Client name (letters, numbers, dash, underscore): " name
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { ah_err "Invalid client name."; return 1; }
  [[ ! -e "$WG_CLIENT_DIR/$name.conf" ]] || { ah_warn "That client already exists."; return 1; }
  [[ -s "$WG_CONF" && -s /etc/wireguard/server_public.key && -s /etc/wireguard/server_endpoint && -s /etc/wireguard/server_port ]] || {
    ah_err "WireGuard server state is incomplete. Re-run server setup or restore its state files."; return 1;
  }
  ip="$(wg_next_client_ip)" || { ah_err "No free client addresses remain."; return 1; }
  umask 077
  client_priv="$(wg genkey)" || return 1
  client_pub="$(printf '%s' "$client_priv" | wg pubkey)" || return 1
  server_pub="$(cat /etc/wireguard/server_public.key)"
  endpoint="$(cat /etc/wireguard/server_endpoint)"
  port="$(cat /etc/wireguard/server_port)"
  psk="$(wg genpsk)" || return 1

  backup="$(mktemp)"
  server_tmp="$(mktemp)"
  client_tmp="$(mktemp)"
  cp -a "$WG_CONF" "$backup"
  if ! cat "$WG_CONF" > "$server_tmp" || ! cat >> "$server_tmp" <<EOF

# client:$name
[Peer]
PublicKey = $client_pub
PresharedKey = $psk
AllowedIPs = $ip/32
EOF
  then
    rm -f "$backup" "$server_tmp" "$client_tmp"
    ah_err "Could not prepare the server configuration."
    return 1
  fi
  cat > "$client_tmp" <<EOF
[Interface]
PrivateKey = $client_priv
Address = $ip/32
DNS = 1.1.1.1

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = $endpoint:$port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "$server_tmp" "$client_tmp"
  if ! wg-quick strip "$server_tmp" >/dev/null 2>&1; then
    rm -f "$backup" "$server_tmp" "$client_tmp"
    ah_err "Generated server configuration failed validation."
    return 1
  fi
  if ! install -m 600 "$server_tmp" "$WG_CONF" || ! install -m 600 "$client_tmp" "$WG_CLIENT_DIR/$name.conf"; then
    cp -a "$backup" "$WG_CONF"
    rm -f "$WG_CLIENT_DIR/$name.conf" "$backup" "$server_tmp" "$client_tmp"
    ah_err "Could not save the client. Previous server configuration restored."
    return 1
  fi
  if ! wg set wg0 peer "$client_pub" preshared-key <(printf '%s\n' "$psk") allowed-ips "$ip/32"; then
    cp -a "$backup" "$WG_CONF"
    rm -f "$WG_CLIENT_DIR/$name.conf" "$backup" "$server_tmp" "$client_tmp"
    ah_err "Could not activate the peer. Previous server configuration restored."
    return 1
  fi
  rm -f "$backup" "$server_tmp" "$client_tmp"
  ah_ok "Client $name created: $WG_CLIENT_DIR/$name.conf"
  ah_info "Copy this file securely to the client's WireGuard app. It contains a private key."
}

wg_list_clients() {
  wg_require_tools || return 1
  echo "Configured WireGuard peers:"
  wg show wg0 peers 2>/dev/null || true
  echo
  echo "Client configuration files:"
  if compgen -G "$WG_CLIENT_DIR/*.conf" >/dev/null; then
    find "$WG_CLIENT_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | sort
  else
    echo "No client files found."
  fi
  echo
  wg show wg0
}

wg_remove_client() {
  wg_require_tools || return 1
  local name file pub
  read -r -p "Client name to remove: " name
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { ah_err "Invalid client name."; return 1; }
  file="$WG_CLIENT_DIR/$name.conf"
  [[ -f "$file" ]] || { ah_warn "Client file not found."; return 1; }
  pub="$(awk '/^PublicKey[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$WG_CONF" 2>/dev/null)"
  # Find the peer public key in the named, commented section.
  pub="$(awk -v marker="# client:$name" '$0==marker {found=1; next} found && /^PublicKey[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit} found && /^# client:/ {exit}' "$WG_CONF")"
  [[ -n "$pub" ]] || { ah_err "Could not find the peer in the server config; no changes made."; return 1; }
  read -r -p "Remove peer '$name'? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 0
  wg set wg0 peer "$pub" remove
  awk -v marker="# client:$name" '
    $0==marker {skip=1; next}
    skip && /^# client:/ {skip=0}
    !skip {print}
  ' "$WG_CONF" > "$WG_CONF.tmp"
  install -m 600 "$WG_CONF.tmp" "$WG_CONF"
  rm -f "$WG_CONF.tmp" "$file"
  ah_ok "Client $name removed."
}

wg_menu() {
  while true; do
    echo
    echo "----- WireGuard Management -----"
    echo "1) Install WireGuard"
    echo "2) Set up WireGuard server"
    echo "3) Add client"
    echo "4) List peers and status"
    echo "5) Remove client"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) wg_install; ah_pause ;;
      2) wg_setup_server; ah_pause ;;
      3) wg_add_client; ah_pause ;;
      4) wg_list_clients; ah_pause ;;
      5) wg_remove_client; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
