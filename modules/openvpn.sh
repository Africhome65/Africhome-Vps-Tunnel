#!/usr/bin/env bash
# Native OpenVPN server and certificate-based client management.
# Does not alter UFW/nftables, IP forwarding, NAT, or the central TCP router.
set -Eeuo pipefail

OVPN_CONFIG_DIR="${OVPN_CONFIG_DIR:-/etc/openvpn/server}"
OVPN_EASYRSA_DIR="${OVPN_EASYRSA_DIR:-/etc/openvpn/easy-rsa}"
OVPN_CLIENT_DIR="${OVPN_CLIENT_DIR:-/root/africhome-openvpn-clients}"
OVPN_CONFIG="${OVPN_CONFIG:-$OVPN_CONFIG_DIR/africhome.conf}"
OVPN_STATE="${OVPN_STATE:-/etc/africhome-openvpn.env}"
OVPN_SERVICE="openvpn-server@africhome"

ovpn_error(){ ah_err "$*"; }
ovpn_valid_port(){
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#${1} >= 1 && 10#${1} <= 65535 ))
}
ovpn_valid_name(){
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]
}
ovpn_valid_remote(){
  local value="${1:-}"
  (( ${#value} <= 253 )) || return 1
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ||
     "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local part
    IFS=. read -r -a _ovpn_octets <<< "$value"
    for part in "${_ovpn_octets[@]}"; do (( 10#$part <= 255 )) || return 1; done
  fi
}
ovpn_easyrsa(){
  [[ -x "$OVPN_EASYRSA_DIR/easyrsa" ]] || { ovpn_error "Easy-RSA is not initialized."; return 1; }
  (cd "$OVPN_EASYRSA_DIR" && EASYRSA_BATCH=1 ./easyrsa "$@")
}
ovpn_require_tools(){
  local missing=0 cmd
  for cmd in openvpn systemctl ss install openssl; do
    command -v "$cmd" >/dev/null 2>&1 || { ah_warn "Missing command: $cmd"; missing=1; }
  done
  (( missing == 0 ))
}
ovpn_install_packages(){
  ah_require_root || return 1
  ah_apt_install openvpn easy-rsa openssl iproute2 || return 1
  [[ -x /usr/share/easy-rsa/easyrsa ]] || { ovpn_error "Easy-RSA executable not found after installation."; return 1; }
  ah_ok "OpenVPN and Easy-RSA packages installed."
  ah_info "No firewall, NAT, or existing VPN service was changed."
}
ovpn_init_pki(){
  ah_require_root || return 1
  [[ ! -e "$OVPN_EASYRSA_DIR" ]] || { ovpn_error "PKI directory already exists; refusing to replace it."; return 1; }
  [[ -x /usr/share/easy-rsa/easyrsa ]] || { ovpn_error "Install OpenVPN/Easy-RSA packages first."; return 1; }
  install -d -o root -g root -m 0700 "$OVPN_EASYRSA_DIR" || return 1
  cp -a /usr/share/easy-rsa/. "$OVPN_EASYRSA_DIR/" || return 1
  chmod 0700 "$OVPN_EASYRSA_DIR"
  if ! ovpn_easyrsa init-pki ||
     ! ovpn_easyrsa --batch --req-cn=Africhome-CA build-ca nopass; then
    ovpn_error "CA initialization failed. PKI directory retained for inspection: $OVPN_EASYRSA_DIR"
    return 1
  fi
  ah_ok "Private certificate authority created."
  ah_warn "The CA private key is highly sensitive. Keep a protected off-host backup."
}
ovpn_port_available(){
  local proto="$1" port="$2"
  if [[ "$proto" == udp ]]; then
    ! ss -H -lun 2>/dev/null | awk -v p=":$port" '$0 ~ p"([[:space:]]|$)" {found=1} END{exit !found}'
  else
    ! ss -H -ltn 2>/dev/null | awk -v p=":$port" '$0 ~ p"([[:space:]]|$)" {found=1} END{exit !found}'
  fi
}
ovpn_client_proto(){
  case "${1:-}" in tcp) printf 'tcp-client\n' ;; udp) printf 'udp\n' ;; *) return 1 ;; esac
}
ovpn_write_server_config(){
  local output="$1" port="$2" proto="$3" runtime_dir="${4:-/etc/openvpn/server/africhome-pki}"
  local server_proto="$proto"
  [[ "$proto" != tcp ]] || server_proto="tcp-server"
  cat > "$output" <<EOF
port $port
proto $server_proto
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/africhome/ipp.txt
keepalive 10 120
user nobody
group nogroup
persist-key
persist-tun
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
tls-version-min 1.2
tls-crypt $runtime_dir/ta.key
ca $runtime_dir/ca.crt
cert $runtime_dir/server.crt
key $runtime_dir/server.key
crl-verify $runtime_dir/crl.pem
dh none
ecdh-curve prime256v1
status /var/log/openvpn/africhome/status.log
verb 3
EOF
  [[ "$proto" != udp ]] || printf 'explicit-exit-notify 1\n' >> "$output"
}
ovpn_configure_server(){
  ah_require_root || return 1
  ovpn_require_tools || return 1
  [[ -s "$OVPN_EASYRSA_DIR/pki/ca.crt" && -s "$OVPN_EASYRSA_DIR/pki/private/ca.key" ]] || {
    ovpn_error "Initialize the Africhome CA first."; return 1;
  }
  [[ ! -e "$OVPN_CONFIG" ]] || { ovpn_error "OpenVPN config already exists. Refusing to overwrite it."; return 1; }
  local remote port proto tmp backup
  read -r -p "Public VPS IP/domain for client profiles: " remote
  ovpn_valid_remote "$remote" || { ovpn_error "Invalid public hostname or IPv4 address."; return 1; }
  read -r -p "OpenVPN transport [udp/tcp] (default udp): " proto
  proto="${proto:-udp}"
  [[ "$proto" == udp || "$proto" == tcp ]] || { ovpn_error "Choose udp or tcp."; return 1; }
  read -r -p "OpenVPN port [1194]: " port
  port="${port:-1194}"
  ovpn_valid_port "$port" || { ovpn_error "Invalid port."; return 1; }
  ovpn_port_available "$proto" "$port" || { ovpn_error "$proto/$port is already in use."; return 1; }

  [[ ! -L "$OVPN_CONFIG_DIR" && ! -L "$OVPN_RUNTIME_DIR" && ! -L "$OVPN_CONFIG" && ! -L "$OVPN_STATE" ]] || {
    ovpn_error "OpenVPN config, runtime, or state paths must not be symlinks."; return 1;
  }
  [[ ! -L /var/log/openvpn/africhome ]] || { ovpn_error "OpenVPN log directory must not be a symlink."; return 1; }
  install -d -m 0755 "$OVPN_CONFIG_DIR"
  install -d -o nobody -g nogroup -m 0750 /var/log/openvpn/africhome
  if [[ ! -s "$OVPN_EASYRSA_DIR/pki/private/server.key" ]]; then
    ovpn_easyrsa gen-req server nopass || return 1
    ovpn_easyrsa sign-req server server || return 1
  fi
  [[ -s "$OVPN_EASYRSA_DIR/pki/issued/server.crt" ]] || { ovpn_error "Server certificate was not created."; return 1; }
  [[ -s "$OVPN_EASYRSA_DIR/pki/crl.pem" ]] || ovpn_easyrsa gen-crl || return 1
  if [[ ! -s "$OVPN_EASYRSA_DIR/pki/ta.key" ]]; then
    openvpn --genkey secret "$OVPN_EASYRSA_DIR/pki/ta.key" || return 1
  fi
  install -d -o root -g nogroup -m 0750 "$OVPN_RUNTIME_DIR" || return 1
  install -o root -g nogroup -m 0640 "$OVPN_EASYRSA_DIR/pki/ta.key" "$OVPN_RUNTIME_DIR/ta.key" || return 1
  install -o root -g nogroup -m 0640 "$OVPN_EASYRSA_DIR/pki/private/server.key" "$OVPN_RUNTIME_DIR/server.key" || return 1
  install -o root -g nogroup -m 0644 "$OVPN_EASYRSA_DIR/pki/ca.crt" "$OVPN_RUNTIME_DIR/ca.crt" || return 1
  install -o root -g nogroup -m 0644 "$OVPN_EASYRSA_DIR/pki/issued/server.crt" "$OVPN_RUNTIME_DIR/server.crt" || return 1
  install -o root -g nogroup -m 0644 "$OVPN_EASYRSA_DIR/pki/crl.pem" "$OVPN_RUNTIME_DIR/crl.pem" || return 1
  tmp="$(mktemp "$OVPN_CONFIG_DIR/.africhome.XXXXXX")" || return 1
  backup=""
  ovpn_write_server_config "$tmp" "$port" "$proto" "$OVPN_RUNTIME_DIR"
  chmod 0640 "$tmp"
  chown root:nogroup "$tmp"
  mv -n -- "$tmp" "$OVPN_CONFIG" || { rm -f "$tmp"; ovpn_error "Config path appeared during setup; refusing overwrite."; return 1; }
  chmod 0600 "$OVPN_EASYRSA_DIR/pki/private/server.key"
  if ! systemctl enable "$OVPN_SERVICE" || ! systemctl restart "$OVPN_SERVICE"; then
    backup="$OVPN_CONFIG.failed.$(date +%Y%m%d%H%M%S)"
    mv -- "$OVPN_CONFIG" "$backup"
    rm -f -- "$OVPN_STATE"
    systemctl disable "$OVPN_SERVICE" >/dev/null 2>&1 || true
    ovpn_error "OpenVPN did not start. Failed config preserved at $backup."
    journalctl -u "$OVPN_SERVICE" -n 30 --no-pager 2>/dev/null || true
    return 1
  fi
  [[ -d "$(dirname -- "$OVPN_STATE")" && ! -L "$(dirname -- "$OVPN_STATE")" ]] || { ovpn_error "OpenVPN state parent directory is missing or unsafe."; return 1; }
  local state_tmp
  state_tmp="$(mktemp "$(dirname -- "$OVPN_STATE")/.africhome-openvpn.XXXXXX")" || return 1
  umask 077
  printf 'OVPN_REMOTE=%q\nOVPN_PORT=%q\nOVPN_PROTO=%q\n' "$remote" "$port" "$proto" > "$state_tmp"
  chmod 0600 "$state_tmp"
  mv -n -- "$state_tmp" "$OVPN_STATE" || { rm -f "$state_tmp"; ovpn_error "Could not safely save OpenVPN state."; return 1; }
  ah_ok "Native OpenVPN server started on $proto/$port."
  ah_info "Open $proto/$port in the VPS provider firewall. UFW/nftables were not changed."
  ah_warn "Internet routing/NAT and IP forwarding are not enabled automatically. Configure and review them separately before advertising full-tunnel internet access."
  ah_info "This is native OpenVPN only; it does not provide WebSocket, payload proxy, or SNI wrapping."
}
ovpn_add_client(){
  ah_require_root || return 1
  [[ -s "$OVPN_CONFIG" && -r "$OVPN_STATE" ]] || { ovpn_error "Configure the OpenVPN server first."; return 1; }
  local name remote port proto output tmp
  read -r -p "New client name (letters/numbers/_/-): " name
  ovpn_valid_name "$name" || { ovpn_error "Invalid client name."; return 1; }
  [[ ! -e "$OVPN_EASYRSA_DIR/pki/issued/$name.crt" && ! -e "$OVPN_CLIENT_DIR/$name.ovpn" ]] || {
    ovpn_error "Client already exists."; return 1;
  }
  # shellcheck disable=SC1090
  . "$OVPN_STATE"
  ovpn_easyrsa gen-req "$name" nopass || return 1
  ovpn_easyrsa sign-req client "$name" || return 1
  [[ -s "$OVPN_EASYRSA_DIR/pki/issued/$name.crt" && -s "$OVPN_EASYRSA_DIR/pki/private/$name.key" ]] || {
    ovpn_error "Client certificate/key generation incomplete."; return 1;
  }
  [[ ! -L "$OVPN_CLIENT_DIR" ]] || { ovpn_error "Client export directory must not be a symlink."; return 1; }
  install -d -m 0700 "$OVPN_CLIENT_DIR"
  output="$OVPN_CLIENT_DIR/$name.ovpn"
  tmp="$(mktemp "$OVPN_CLIENT_DIR/.$name.XXXXXX")" || return 1
  cat > "$tmp" <<EOF
client
dev tun
proto $(ovpn_client_proto "$OVPN_PROTO")
remote $OVPN_REMOTE $OVPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name server name
auth SHA256
auth-nocache
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3
<ca>
$(cat "$OVPN_EASYRSA_DIR/pki/ca.crt")
</ca>
<cert>
$(awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{if(p)exit}' "$OVPN_EASYRSA_DIR/pki/issued/$name.crt")
</cert>
<key>
$(cat "$OVPN_EASYRSA_DIR/pki/private/$name.key")
</key>
<tls-crypt>
$(cat "$OVPN_EASYRSA_DIR/pki/ta.key")
</tls-crypt>
EOF
  chmod 0600 "$tmp"
  mv -n -- "$tmp" "$output" || { rm -f "$tmp"; ovpn_error "Client profile already exists; refusing overwrite."; return 1; }
  ah_ok "Client profile created: $output"
  ah_warn "This file contains a private key. Transfer it securely and never upload it to GitHub or paste it into chat."
}
ovpn_revoke_client(){
  ah_require_root || return 1
  [[ -s "$OVPN_CONFIG" ]] || { ovpn_error "Configure OpenVPN first."; return 1; }
  local name
  read -r -p "Client name to revoke: " name
  ovpn_valid_name "$name" || { ovpn_error "Invalid client name."; return 1; }
  [[ -s "$OVPN_EASYRSA_DIR/pki/issued/$name.crt" ]] || { ovpn_error "Client certificate not found."; return 1; }
  read -r -p "Revoke $name and disconnect future connections? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 0
  ovpn_easyrsa revoke "$name" || return 1
  ovpn_easyrsa gen-crl || return 1
  install -o root -g nogroup -m 0644 "$OVPN_EASYRSA_DIR/pki/crl.pem" "$OVPN_RUNTIME_DIR/crl.pem" || return 1
  systemctl restart "$OVPN_SERVICE" || { ovpn_error "CRL generated but OpenVPN restart failed; check service status."; return 1; }
  rm -f -- "$OVPN_CLIENT_DIR/$name.ovpn"
  ah_ok "Client $name revoked; CRL installed and service restarted."
}
ovpn_status(){
  ah_require_root || return 1
  systemctl --no-pager --full status "$OVPN_SERVICE" || true
  journalctl -u "$OVPN_SERVICE" -n 25 --no-pager 2>/dev/null || true
}
ovpn_menu(){
  while true; do
    echo
    echo "----- OpenVPN Native Server Management -----"
    echo "1) Install OpenVPN + Easy-RSA packages"
    echo "2) Create Africhome certificate authority (one-time)"
    echo "3) Configure native OpenVPN server (UDP/TCP)"
    echo "4) Create client profile"
    echo "5) Revoke client certificate"
    echo "6) Service status and logs"
    echo "7) Read-only OpenVPN deployment inventory"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) ovpn_install_packages; ah_pause ;;
      2) ovpn_init_pki; ah_pause ;;
      3) ovpn_configure_server; ah_pause ;;
      4) ovpn_add_client; ah_pause ;;
      5) ovpn_revoke_client; ah_pause ;;
      6) ovpn_status; ah_pause ;;
      7) bash "$BASE_DIR/scripts/openvpn-inventory.sh"; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
