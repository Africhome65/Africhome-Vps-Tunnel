#!/usr/bin/env bash
# Interactive DNSTT DNS identity setup. Does not edit DNS at the registrar.
set -Eeuo pipefail
[[ "$EUID" -eq 0 ]] || { echo "Run as root: sudo bash scripts/configure-dnstt-domain.sh" >&2; exit 1; }

CONFIG_DIR="/etc/africhome-dnstt"
CONFIG_FILE="$CONFIG_DIR/server.env"
if [[ -L "$CONFIG_DIR" || ( -e "$CONFIG_DIR" && ! -d "$CONFIG_DIR" ) ]]; then
  echo "DNSTT config directory must be a real directory, not a symlink." >&2
  exit 1
fi
install -d -o root -g root -m 0700 "$CONFIG_DIR"
[[ "$(stat -c '%u:%a' "$CONFIG_DIR")" == "0:700" ]] || {
  echo "DNSTT config directory must be root-owned with mode 0700." >&2
  exit 1
}

valid_fqdn() {
  local value="$1"
  [[ "$value" == "${value,,}" ]] || return 1
  [[ "$value" != .* && "$value" != *. && "$value" == *.* ]] || return 1
  [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || return 1
  (( ${#value} <= 253 ))
}

tmp=""
cleanup() { [[ -z "$tmp" || ! -e "$tmp" ]] || rm -f -- "$tmp"; }
trap cleanup EXIT

current_domain=""
current_ns=""
if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" && "$(stat -c '%u:%a' "$CONFIG_FILE")" == "0:600" ]] || {
    echo "Existing DNSTT domain config must be a root-owned regular file with mode 0600." >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  current_domain="${DNS_DOMAIN:-}"
  current_ns="${DNS_NS_HOST:-}"
fi

echo "Africhome DNSTT DNS configuration"
echo "Use DNS names that you own and have authority to edit."
echo "This saves the values locally; it does not change registrar/DNS records."
echo

while true; do
  if [[ -n "$current_domain" ]]; then
    read -r -p "Your delegated DNSTT tunnel domain [$current_domain]: " DNS_DOMAIN
    DNS_DOMAIN="${DNS_DOMAIN:-$current_domain}"
  else
    read -r -p "Your delegated DNSTT tunnel domain (e.g. tunnel.example.com): " DNS_DOMAIN
  fi
  DNS_DOMAIN="${DNS_DOMAIN,,}"
  if valid_fqdn "$DNS_DOMAIN"; then break; fi
  echo "Invalid hostname. Enter a lowercase fully-qualified DNS name (no scheme, port, spaces, or trailing dot)."
done

while true; do
  if [[ -n "$current_ns" ]]; then
    read -r -p "Your authoritative nameserver hostname [$current_ns]: " DNS_NS_HOST
    DNS_NS_HOST="${DNS_NS_HOST:-$current_ns}"
  else
    read -r -p "Your authoritative nameserver hostname (e.g. ns1.example.net): " DNS_NS_HOST
  fi
  DNS_NS_HOST="${DNS_NS_HOST,,}"
  if valid_fqdn "$DNS_NS_HOST"; then break; fi
  echo "Invalid hostname. Enter a lowercase fully-qualified DNS name (no scheme, port, spaces, or trailing dot)."
done

tmp="$(mktemp "$CONFIG_DIR/server.env.XXXXXX")"
chmod 0600 "$tmp"
{
  printf 'DNS_DOMAIN=%q\n' "$DNS_DOMAIN"
  printf 'DNS_NS_HOST=%q\n' "$DNS_NS_HOST"
} > "$tmp"
if [[ -f "$CONFIG_FILE" ]]; then
  cp -a -- "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S).$"
fi
mv -f -- "$tmp" "$CONFIG_FILE"
tmp=""
chmod 0600 "$CONFIG_FILE"

echo
echo "Saved DNSTT DNS settings to $CONFIG_FILE"
echo "Tunnel domain: $DNS_DOMAIN"
echo "Nameserver host: $DNS_NS_HOST"
echo
echo "At your DNS provider, configure the required A/host record and NS delegation."
echo "If your DNS provider requires registrar glue, create it there as well."
echo "Point the nameserver host to this VPS public IPv4 address."
echo "Open UDP 53 at both the VPS firewall and provider firewall when ready."
echo "No DNS records, firewall rules, services, or existing iodine settings were changed."
