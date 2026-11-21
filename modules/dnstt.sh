#!/usr/bin/env bash
# Africhome DNSTT server management.
# Upstream: https://www.bamsoftware.com/software/dnstt/
set -Eeuo pipefail

DNSTT_BIN="/usr/local/bin/dnstt-server"
DNSTT_DIR="/etc/africhome/dnstt"
DNSTT_KEY="$DNSTT_DIR/server.key"
DNSTT_PUB="$DNSTT_DIR/server.pub"
DNSTT_DOMAIN_FILE="$DNSTT_DIR/domain"
DNSTT_UNIT="/etc/systemd/system/africhome-dnstt.service"
DNSTT_VERSION="v1.20260501.0"

ah_dnstt_valid_domain() {
  local value="$1"
  [[ "$value" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

ah_dnstt_ensure_go() {
  local version major minor arch file sha tmp
  if command -v go >/dev/null 2>&1; then
    version="$(go version | sed -E 's/.* go([0-9]+)\.([0-9]+).*/\1.\2/')"
    major="${version%%.*}"; minor="${version#*.}"
    if (( major > 1 || (major == 1 && minor >= 23) )); then return 0; fi
    ah_warn "The installed Go toolchain is too old; installing a current verified Go toolchain."
  else
    ah_info "Installing a current Go toolchain to build the official DNSTT server."
  fi

  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) ah_err "Unsupported CPU architecture for automatic Go installation: $(uname -m)"; return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || ah_apt_install curl ca-certificates
  command -v jq >/dev/null 2>&1 || ah_apt_install jq
  file="$(curl -fsSL https://go.dev/dl/?mode=json | jq -r '.[0].files[] | select(.os == "linux" and .arch == "'"$arch"'" and .kind == "archive") | .filename' | head -n1)"
  sha="$(curl -fsSL https://go.dev/dl/?mode=json | jq -r '.[0].files[] | select(.os == "linux" and .arch == "'"$arch"'" and .kind == "archive") | .sha256' | head -n1)"
  [[ -n "$file" && "$sha" =~ ^[a-f0-9]{64}$ ]] || { ah_err "Could not obtain verified Go download metadata."; return 1; }
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fL --retry 3 "https://go.dev/dl/$file" -o "$tmp/$file"
  printf '%s  %s\n' "$sha" "$tmp/$file" | sha256sum -c -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp/$file"
  export PATH="/usr/local/go/bin:$PATH"
  go version
}

ah_dnstt_install_binary() {
  local tmp
  if [[ -x "$DNSTT_BIN" ]]; then
    ah_info "DNSTT server binary is already installed."
    return 0
  fi
  ah_dnstt_ensure_go || return 1
  tmp="$(mktemp -d)"
  GOBIN="$tmp" go install "www.bamsoftware.com/git/dnstt.git/dnstt-server@$DNSTT_VERSION"
  install -o root -g root -m 0755 "$tmp/dnstt-server" "$DNSTT_BIN"
  rm -rf "$tmp"
  "$DNSTT_BIN" -h >/dev/null 2>&1 || true
  ah_ok "Official DNSTT server binary installed ($DNSTT_VERSION)."
}

ah_dnstt_prepare_user() {
  if ! id dnstt >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin dnstt
  fi
  install -d -o root -g dnstt -m 0750 /etc/africhome /etc/africhome/dnstt
}

ah_dnstt_dns_instructions() {
  local domain="$1" ns="$2"
  cat <<EOF

DNS records required at your DNS provider:
  A     $ns       -> this VPS public IPv4 address
  NS    $domain   -> $ns

If your DNS provider requires glue records, add the nameserver host/glue as directed.
The nameserver host must be outside the delegated tunnel zone. Do not proxy these records
through a CDN. Allow inbound UDP 53 in the VPS provider firewall.
EOF
}

ah_dnstt_check_dns() {
  local domain="$1" ns="$2" ns_records ns_addresses
  if ! command -v dig >/dev/null 2>&1; then
    ah_warn "dig is unavailable; DNS delegation could not be checked."
    return 1
  fi
  ns_records="$(dig +time=3 +tries=1 +short NS "$domain" | sed 's/\.$//' || true)"
  ns_addresses="$(dig +time=3 +tries=1 +short A "$ns" || true)"
  if ! printf '%s\n' "$ns_records" | grep -Fxq "$ns"; then
    ah_warn "The tunnel zone does not currently resolve to the nameserver $ns."
    [[ -n "$ns_records" ]] && printf 'Observed NS records: %s\n' "$ns_records"
    return 1
  fi
  if [[ -z "$ns_addresses" ]]; then
    ah_warn "The nameserver hostname $ns has no publicly resolvable IPv4 A record."
    return 1
  fi
  ah_ok "DNS delegation and nameserver A record are visible."
}

ah_dnstt_write_service() {
  local domain="$1"
  cat > "$DNSTT_UNIT" <<EOF
[Unit]
Description=Africhome DNSTT DNS tunnel server
Wants=network-online.target
After=network-online.target ssh.service sshd.service

[Service]
Type=simple
User=dnstt
Group=dnstt
ExecStart=$DNSTT_BIN -udp :53 -privkey-file $DNSTT_KEY $domain 127.0.0.1:22
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadOnlyPaths=$DNSTT_DIR
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$DNSTT_UNIT"
}

ah_dnstt_configure() {
  local domain ns answer
  ah_require_root || return 1
  ah_dnstt_install_binary || return 1
  ah_dnstt_prepare_user
  if [[ -s "$DNSTT_DOMAIN_FILE" ]]; then
    domain="$(cat "$DNSTT_DOMAIN_FILE")"
    read -r -p "Current tunnel zone is $domain. Keep it? [Y/n]: " answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then domain=""; fi
  fi
  if [[ -z "${domain:-}" ]]; then
    read -r -p "Delegated tunnel subdomain (for example t.example.com): " domain
  fi
  domain="${domain,,}"
  ah_dnstt_valid_domain "$domain" || { ah_err "Enter a valid fully qualified tunnel subdomain."; return 1; }

  read -r -p "Nameserver hostname outside $domain (for example ns1.example.com): " ns
  ns="${ns,,}"
  ah_dnstt_valid_domain "$ns" || { ah_err "Enter a valid nameserver hostname."; return 1; }
  if [[ "$ns" == "$domain" || "$ns" == *".$domain" ]]; then
    ah_err "The nameserver host must be outside the delegated tunnel zone."; return 1
  fi

  if [[ -s "$DNSTT_KEY" && -s "$DNSTT_PUB" ]]; then
    ah_info "Existing DNSTT keypair preserved; clients keep the same server public key."
  else
    "$DNSTT_BIN" -gen-key -privkey-file "$DNSTT_KEY" -pubkey-file "$DNSTT_PUB"
    chown root:dnstt "$DNSTT_KEY"
    chmod 0640 "$DNSTT_KEY"
    chown root:root "$DNSTT_PUB"
    chmod 0644 "$DNSTT_PUB"
  fi
  printf '%s\n' "$domain" > "$DNSTT_DOMAIN_FILE"
  chmod 0640 "$DNSTT_DOMAIN_FILE"
  chown root:dnstt "$DNSTT_DOMAIN_FILE"

  if ss -Hlun 'sport = :53' 2>/dev/null | grep -q .; then
    ah_err "UDP port 53 is already in use. No service was started; identify the existing DNS listener first."
    ss -lunp 'sport = :53' || true
    return 1
  fi
  if ! ss -Hln 'sport = :22' 2>/dev/null | grep -q .; then
    ah_warn "No TCP listener was detected on port 22. Confirm SSH listens on 127.0.0.1:22 before enabling DNSTT."
  fi

  ah_dnstt_write_service "$domain"
  systemctl daemon-reload
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 53/udp comment 'Africhome DNSTT' || ah_warn "Could not add UFW UDP 53 rule."
  fi
  ah_dnstt_dns_instructions "$domain" "$ns"
  echo
  echo "Server public key (safe to copy to clients):"
  cat "$DNSTT_PUB"
  echo
  if ! ah_dnstt_check_dns "$domain" "$ns"; then
    read -r -p "DNS checks did not pass. Continue to the service start confirmation anyway? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { ah_warn "Start skipped until DNS delegation is corrected."; return 0; }
  fi
  read -r -p "Have you opened UDP 53 at your VPS provider? Start service now? [y/N]: " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    systemctl enable --now africhome-dnstt.service
    systemctl --no-pager --full status africhome-dnstt.service || true
  else
    ah_warn "Configuration saved, but the DNSTT service was not started."
  fi
}

ah_dnstt_status() {
  if systemctl is-active --quiet africhome-dnstt.service; then
    systemctl --no-pager --full status africhome-dnstt.service
  else
    ah_warn "DNSTT service is not active."
    systemctl --no-pager status africhome-dnstt.service 2>/dev/null || true
  fi
  if [[ -s "$DNSTT_PUB" ]]; then
    echo "Server public key:"
    cat "$DNSTT_PUB"
  fi
}

dnstt_menu() {
  local choice
  while true; do
    echo
    echo "===== DNSTT DNS TUNNEL ====="
    echo "1) Install and configure DNSTT server"
    echo "2) Service status and public key"
    echo "3) Restart DNSTT service"
    echo "4) Stop DNSTT service"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) ah_dnstt_configure ;;
      2) ah_dnstt_status ;;
      3) ah_require_root && systemctl restart africhome-dnstt.service ;;
      4) ah_require_root && systemctl stop africhome-dnstt.service ;;
      0) return 0 ;;
      *) ah_warn "Invalid choice." ;;
    esac
    ah_pause
  done
}
