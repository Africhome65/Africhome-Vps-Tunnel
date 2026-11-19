#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/modules/ssh_tls.sh"
ah_err(){ :; }
ssh_tls_valid_port 12222
! ssh_tls_valid_port 80
! ssh_tls_valid_port 65536
ssh_tls_valid_hostname ssh.example.com
ssh_tls_valid_hostname vpn.xn--p1ai
! ssh_tls_valid_hostname -bad.example
! ssh_tls_valid_hostname bad-.example
! ssh_tls_valid_hostname https://ssh.example.com
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ssh_tls_write_config "$TMP/stunnel.conf" 12222 /etc/letsencrypt/live/example/fullchain.pem /etc/letsencrypt/live/example/privkey.pem
grep -q '^accept = 127.0.0.1:12222$' "$TMP/stunnel.conf"
grep -q '^connect = 127.0.0.1:22$' "$TMP/stunnel.conf"
grep -q '^sslVersionMin = TLSv1.2$' "$TMP/stunnel.conf"
! grep -q '^accept = 0.0.0.0' "$TMP/stunnel.conf"
ssh_tls_write_unit "$TMP/service.unit"
grep -q '^ExecStart=/usr/bin/stunnel4 /etc/stunnel/africhome-ssh.conf$' "$TMP/service.unit"
echo "SSH TLS backend validation passed."
