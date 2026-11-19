#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=../modules/openvpn.sh
source "$ROOT/modules/openvpn.sh"
ah_err(){ :; }

ovpn_valid_port 1194
! ovpn_valid_port 0
! ovpn_valid_port 65536
! ovpn_valid_port abc
ovpn_valid_name client_01
! ovpn_valid_name ../escape
! ovpn_valid_name "client name"
ovpn_valid_remote vpn.example.com
ovpn_valid_remote vpn.xn--p1ai
! ovpn_valid_remote -bad.example
! ovpn_valid_remote bad-.example
! ovpn_valid_remote "$(printf 'a%.0s' {1..250}).com"
ovpn_valid_remote 192.0.2.10
! ovpn_valid_remote 999.1.1.1
! ovpn_valid_remote https://vpn.example.com
ss(){ printf 'LISTEN 0 128 0.0.0.0:1194 0.0.0.0:*\n'; }
! ovpn_port_available tcp 1194
ss(){ printf 'UNCONN 0 0 [::]:1194 [::]:*\n'; }
! ovpn_port_available udp 1194
ss(){ :; }
ovpn_port_available tcp 1194
ovpn_port_available udp 1194
unset -f ss

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OVPN_STATE="$TMP/state"
printf 'OVPN_REMOTE=vpn.example.com\nOVPN_PORT=1194\nOVPN_PROTO=udp\n' > "$OVPN_STATE"
chmod 0600 "$OVPN_STATE"
stat(){ printf '0:600\n'; }
ovpn_load_state
[[ "$OVPN_REMOTE" == vpn.example.com && "$OVPN_PORT" == 1194 && "$OVPN_PROTO" == udp ]]
printf 'OVPN_REMOTE=vpn.example.com\nOVPN_REMOTE=other.example.com\nOVPN_PORT=1194\nOVPN_PROTO=udp\n' > "$OVPN_STATE"
! ovpn_load_state
unset -f stat
OVPN_CLIENT_DIR="$TMP/client-export"
mkdir -m 0700 "$OVPN_CLIENT_DIR"
stat(){ printf '0:700\n'; }
ovpn_prepare_client_dir
rm -rf "$OVPN_CLIENT_DIR"
ln -s "$TMP" "$OVPN_CLIENT_DIR"
! ovpn_prepare_client_dir
unset -f stat
rm "$OVPN_CLIENT_DIR"
OVPN_EASYRSA_DIR="$TMP/easy-rsa"
OVPN_CONFIG_DIR="$TMP/server"
OVPN_CONFIG="$OVPN_CONFIG_DIR/africhome.conf"
mkdir -p "$OVPN_CONFIG_DIR" "$TMP/easy-rsa/pki"
mkdir -p "$TMP/easy-rsa/pki/private" "$TMP/easy-rsa/pki/issued"
touch "$TMP/easy-rsa/easyrsa"
chmod 0700 "$TMP/easy-rsa"
ovpn_pki_paths_safe
mv "$TMP/easy-rsa/pki/private" "$TMP/private-real"
ln -s "$TMP/private-real" "$TMP/easy-rsa/pki/private"
! ovpn_pki_paths_safe
rm "$TMP/easy-rsa/pki/private"
mv "$TMP/private-real" "$TMP/easy-rsa/pki/private"
ovpn_pki_paths_safe

ovpn_write_server_config "$TMP/server.conf" 1194 udp "$TMP/runtime"
grep -q '^proto udp$' "$TMP/server.conf"
grep -q "^tls-crypt $TMP/runtime/ta.key$" "$TMP/server.conf"
grep -q "^key $TMP/runtime/server.key$" "$TMP/server.conf"
grep -q "^crl-verify $TMP/runtime/crl.pem$" "$TMP/server.conf"
grep -q '^dh none$' "$TMP/server.conf"
grep -q '^explicit-exit-notify 1$' "$TMP/server.conf"

ovpn_write_server_config "$TMP/server-tcp.conf" 443 tcp "$TMP/runtime"
grep -q '^proto tcp-server$' "$TMP/server-tcp.conf"
[[ "$(ovpn_client_proto tcp)" == tcp-client ]]
[[ "$(ovpn_client_proto udp)" == udp ]]
! grep -q '^explicit-exit-notify' "$TMP/server-tcp.conf"

printf 'V\t20300101000000Z\t\t01\tunknown\t/CN=client-one\nR\t20300101000000Z\t20270101000000Z\t02\tunknown\t/CN=client-two\nV\t20300101000000Z\t\t03\tunknown\t/CN=server\n' > "$TMP/easy-rsa/pki/index.txt"
OVPN_EASYRSA_DIR="$TMP/easy-rsa" ovpn_list_clients > "$TMP/clients.txt"
grep -q 'VALID.*client-one' "$TMP/clients.txt"
grep -q 'REVOKED.*client-two' "$TMP/clients.txt"
! grep -q 'server' "$TMP/clients.txt"

# Revocation failure handling must stop the service.
OVPN_SERVICE="openvpn-server@africhome"
systemctl(){ touch "$TMP/systemctl.log"; printf '%s\n' "$*" >> "$TMP/systemctl.log"; }
ovpn_fail_closed "test CRL failure"
grep -q '^stop openvpn-server@africhome$' "$TMP/systemctl.log"
unset -f systemctl

echo "OpenVPN module validation passed."
