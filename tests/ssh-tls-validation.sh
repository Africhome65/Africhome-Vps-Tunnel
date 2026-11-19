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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 1 -subj "/CN=ssh.example.com" -addext "subjectAltName=DNS:ssh.example.com"
stat(){ printf '0:600\n'; }
ssh_tls_check_certificate ssh.example.com "$TMP/cert.pem" "$TMP/key.pem"
[[ "$(ssh_tls_resolve_material "$TMP/cert.pem")" == "$TMP/cert.pem" ]]
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/wrong-key.pem" >/dev/null 2>&1
! ssh_tls_check_certificate ssh.example.com "$TMP/cert.pem" "$TMP/wrong-key.pem"
ln -s "$TMP/cert.pem" "$TMP/cert-link.pem"
! ssh_tls_check_certificate ssh.example.com "$TMP/cert-link.pem" "$TMP/key.pem"
unset -f stat
! ssh_tls_resolve_material "$TMP/cert-link.pem"
grep -Fq "systemctl restart africhome-ssh-tls.service" "$ROOT/scripts/africhome-cert-deploy-hook.sh"
ssh_tls_write_config "$TMP/stunnel.conf" 12222 /etc/letsencrypt/live/example/fullchain.pem /etc/letsencrypt/live/example/privkey.pem
grep -q '^accept = 127.0.0.1:12222$' "$TMP/stunnel.conf"
grep -q '^connect = 127.0.0.1:22$' "$TMP/stunnel.conf"
grep -q '^sslVersionMin = TLSv1.2$' "$TMP/stunnel.conf"
! grep -q '^accept = 0.0.0.0' "$TMP/stunnel.conf"
ssh_tls_write_unit "$TMP/service.unit"
grep -q '^ExecStart=/usr/bin/stunnel4 /etc/stunnel/africhome-ssh.conf$' "$TMP/service.unit"
echo "SSH TLS backend validation passed."
