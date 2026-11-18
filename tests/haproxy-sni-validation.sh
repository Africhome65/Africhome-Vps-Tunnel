#!/usr/bin/env bash
set -Eeuo pipefail
# Loopback-only ordinary TLS SNI passthrough test; this is NOT an Xray REALITY test.
for cmd in haproxy openssl timeout ss; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd" >&2; exit 77; }
done
tmp="$(mktemp -d)"
haproxy_pid=""
backend_a_pid=""
backend_b_pid=""
proxy_port="${AFRICHOME_TEST_PROXY_PORT:-19443}"
backend_a_port="${AFRICHOME_TEST_BACKEND_A_PORT:-19444}"
backend_b_port="${AFRICHOME_TEST_BACKEND_B_PORT:-19445}"
cleanup() {
  [[ -z "$haproxy_pid" ]] || kill "$haproxy_pid" 2>/dev/null || true
  [[ -z "$backend_a_pid" ]] || kill "$backend_a_pid" 2>/dev/null || true
  [[ -z "$backend_b_pid" ]] || kill "$backend_b_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
for port in "$proxy_port" "$backend_a_port" "$backend_b_port"; do
  if ss -H -lnt | grep -Eq "[:.]$port([[:space:]]|$)"; then
    echo "Test port $port is already in use." >&2
    exit 1
  fi
done
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=sni-a.test" -keyout "$tmp/a.key" -out "$tmp/a.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=sni-b.test" -keyout "$tmp/b.key" -out "$tmp/b.crt" >/dev/null 2>&1
openssl s_server -quiet -accept "127.0.0.1:$backend_a_port" -cert "$tmp/a.crt" -key "$tmp/a.key" >"$tmp/a.log" 2>&1 &
backend_a_pid=$!
openssl s_server -quiet -accept "127.0.0.1:$backend_b_port" -cert "$tmp/b.crt" -key "$tmp/b.key" >"$tmp/b.log" 2>&1 &
backend_b_pid=$!
sleep 1
cat > "$tmp/haproxy.cfg" <<EOF
global
  maxconn 32
  log stdout format raw local0
defaults
  mode tcp
  timeout connect 3s
  timeout client 5s
  timeout server 5s
frontend tls_sni_in
  bind 127.0.0.1:$proxy_port
  tcp-request inspect-delay 2s
  tcp-request content accept if { req.ssl_hello_type 1 }
  use_backend tls_a if { req.ssl_sni -i sni-a.test }
  use_backend tls_b if { req.ssl_sni -i sni-b.test }
  default_backend reject_unknown
backend tls_a
  server a 127.0.0.1:$backend_a_port
backend tls_b
  server b 127.0.0.1:$backend_b_port
backend reject_unknown
  tcp-request content reject
EOF
haproxy -c -f "$tmp/haproxy.cfg"
haproxy -db -f "$tmp/haproxy.cfg" >"$tmp/haproxy.log" 2>&1 &
haproxy_pid=$!
sleep 1
kill -0 "$haproxy_pid"
get_backend_cn() {
  local sni="$1"
  timeout 5 openssl s_client -connect "127.0.0.1:$proxy_port" -servername "$sni" </dev/null 2>/dev/null |
    openssl x509 -noout -subject 2>/dev/null
}
a_subject="$(get_backend_cn sni-a.test)"
b_subject="$(get_backend_cn sni-b.test)"
[[ "$a_subject" == *"CN = sni-a.test"* ]] || { echo "SNI route A failed: $a_subject" >&2; exit 1; }
[[ "$b_subject" == *"CN = sni-b.test"* ]] || { echo "SNI route B failed: $b_subject" >&2; exit 1; }
echo "HAProxy ordinary-TLS SNI passthrough tests passed."
echo "NOTE: This does not test Xray REALITY, Trojan, SSH TLS wrappers, or OpenVPN wrappers."
