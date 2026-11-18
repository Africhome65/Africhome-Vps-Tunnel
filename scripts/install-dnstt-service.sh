#!/usr/bin/env bash
# Prepare a DNSTT systemd service using the operator's own DNS settings.
# This writes the unit but deliberately does not stop iodine or start DNSTT.
set -Eeuo pipefail

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }

[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash scripts/install-dnstt-service.sh"
SERVER_BIN="/usr/local/bin/dnstt-server"
KEY_DIR="/etc/africhome-dnstt"
DOMAIN_CONFIG="$KEY_DIR/server.env"
SERVICE_CONFIG="$KEY_DIR/service.env"
UNIT_FILE="/etc/systemd/system/africhome-dnstt.service"

[[ -x "$SERVER_BIN" ]] || fail "DNSTT server is missing. Run scripts/install-dnstt.sh first."
[[ -s "$KEY_DIR/server.key" && -s "$KEY_DIR/server.pub" ]] || fail "DNSTT keypair is missing or incomplete. Run scripts/install-dnstt.sh first."
[[ -f "$DOMAIN_CONFIG" ]] || fail "DNSTT domain is not configured. Run scripts/configure-dnstt-domain.sh first."
[[ "$(stat -c '%u' "$DOMAIN_CONFIG")" == "0" ]] || fail "$DOMAIN_CONFIG must be owned by root."

# This file is created by configure-dnstt-domain.sh and is root-owned.
# shellcheck disable=SC1090
source "$DOMAIN_CONFIG"

valid_fqdn() {
  local value="$1"
  [[ "$value" == "${value,,}" ]] || return 1
  [[ "$value" != .* && "$value" != *. && "$value" == *.* ]] || return 1
  [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || return 1
  (( ${#value} <= 253 ))
}

valid_fqdn "${DNS_DOMAIN:-}" || fail "DNS_DOMAIN in $DOMAIN_CONFIG is invalid."
valid_fqdn "${DNS_NS_HOST:-}" || fail "DNS_NS_HOST in $DOMAIN_CONFIG is invalid."

old_bind=""
old_upstream=""
if [[ -f "$SERVICE_CONFIG" ]]; then
  [[ "$(stat -c '%u' "$SERVICE_CONFIG")" == "0" ]] || fail "$SERVICE_CONFIG must be owned by root."
  # shellcheck disable=SC1090
  source "$SERVICE_CONFIG"
  old_bind="${DNSTT_UDP_ADDR:-}"
  old_upstream="${DNSTT_UPSTREAM:-}"
fi

echo "Africhome DNSTT service configuration"
echo "Tunnel domain: $DNS_DOMAIN"
echo "Nameserver host: $DNS_NS_HOST"
echo "The default upstream is the local SSH server on 127.0.0.1:22."
echo

read -r -p "DNSTT UDP listen address [${old_bind:-:53}]: " DNSTT_UDP_ADDR
DNSTT_UDP_ADDR="${DNSTT_UDP_ADDR:-${old_bind:-:53}}"
read -r -p "SSH upstream address [${old_upstream:-127.0.0.1:22}]: " DNSTT_UPSTREAM
DNSTT_UPSTREAM="${DNSTT_UPSTREAM:-${old_upstream:-127.0.0.1:22}}"

[[ "$DNSTT_UDP_ADDR" =~ ^(:|[0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]{1,5}$ ]] || fail "Invalid UDP listen address. Use :53, 0.0.0.0:53, or an IPv4-address:port."
listen_port="${DNSTT_UDP_ADDR##*:}"
(( 10#$listen_port >= 1 && 10#$listen_port <= 65535 )) || fail "UDP listen port must be between 1 and 65535."
[[ "$DNSTT_UPSTREAM" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || fail "Invalid SSH upstream. Use a hostname-or-IPv4:port such as 127.0.0.1:22."
upstream_port="${DNSTT_UPSTREAM##*:}"
(( 10#$upstream_port >= 1 && 10#$upstream_port <= 65535 )) || fail "SSH upstream port must be between 1 and 65535."

install -d -m 0700 "$KEY_DIR"
tmp="$(mktemp "$KEY_DIR/service.env.XXXXXX")"
chmod 0600 "$tmp"
{
  printf 'DNSTT_UDP_ADDR="%s"\n' "$DNSTT_UDP_ADDR"
  printf 'DNSTT_UPSTREAM="%s"\n' "$DNSTT_UPSTREAM"
} > "$tmp"
if [[ -f "$SERVICE_CONFIG" ]]; then
  cp -a "$SERVICE_CONFIG" "$SERVICE_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
fi
mv -f "$tmp" "$SERVICE_CONFIG"
chmod 0600 "$SERVICE_CONFIG"

unit_tmp="$(mktemp)"
cat > "$unit_tmp" <<'UNIT'
[Unit]
Description=Africhome DNSTT DNS tunnel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/africhome-dnstt/server.env
EnvironmentFile=/etc/africhome-dnstt/service.env
ExecStart=/usr/local/bin/dnstt-server -udp ${DNSTT_UDP_ADDR} -privkey-file /etc/africhome-dnstt/server.key ${DNS_DOMAIN} ${DNSTT_UPSTREAM}
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$unit_tmp"
if [[ -f "$UNIT_FILE" ]]; then
  cp -a "$UNIT_FILE" "$UNIT_FILE.bak.$(date +%Y%m%d%H%M%S)"
fi
install -m 0644 "$unit_tmp" "$UNIT_FILE"
rm -f "$unit_tmp"
systemctl daemon-reload

ok "DNSTT systemd unit installed: africhome-dnstt.service"
info "The service has NOT been started or enabled; no existing tunnel was stopped."
if command -v ss >/dev/null 2>&1 && ss -H -lun "sport = :$listen_port" 2>/dev/null | grep -q .; then
  info "UDP port $listen_port is already occupied. Keep the current service running; do not start DNSTT until you plan the port switch."
else
  info "UDP port $listen_port appears free, but confirm provider firewall and external DNS before starting."
fi
info "Review the unit with: systemctl cat africhome-dnstt"
info "Start only during the planned migration: systemctl enable --now africhome-dnstt"
