#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for file in \
  "$ROOT_DIR/scripts/install-dnstt.sh" \
  "$ROOT_DIR/scripts/configure-dnstt-domain.sh" \
  "$ROOT_DIR/scripts/install-dnstt-service.sh"; do
  [[ -f "$file" ]] || { echo "Missing DNSTT script: $file" >&2; exit 1; }
  bash -n "$file"
done

# The public repository must never ship the maintainer's personal DNS names.
if grep -R -n -E 'smarty\.uk\.afriko2\.co\.uk|ns-smarty\.uk\.afriko2\.co\.uk' "$ROOT_DIR/scripts"; then
  echo "A maintainer-specific DNS name was found in an install script." >&2
  exit 1
fi

SERVICE="$ROOT_DIR/scripts/install-dnstt-service.sh"
grep -q 'EnvironmentFile=/etc/africhome-dnstt/server.env' "$SERVICE"
grep -q 'EnvironmentFile=/etc/africhome-dnstt/service.env' "$SERVICE"
grep -q 'systemctl daemon-reload' "$SERVICE"
grep -q 'root-owned directory with mode 0700' "$SERVICE"
grep -q 'private key must be a root-owned regular file with mode 0600' "$SERVICE"
grep -q 'public key must be a root-owned regular file with mode 0644' "$SERVICE"
grep -q 'refusing to replace an unsafe path' "$SERVICE"
grep -q 'trap cleanup EXIT' "$SERVICE"
grep -q 'install -o root -g root -m 0644' "$SERVICE"
grep -Fq '$(date +%Y%m%d%H%M%S).$$' "$SERVICE"

# Exercise the same address validators used by the service configurator.
VALIDATORS="$(sed -n '/^valid_ipv4() {/,/^}/p; /^valid_upstream_host() {/,/^}/p' "$SERVICE")"
[[ -n "$VALIDATORS" ]] || { echo "DNSTT address validators are missing." >&2; exit 1; }
bash -c "$VALIDATORS
valid_ipv4 '127.0.0.1'
valid_ipv4 '255.255.255.255'
if valid_ipv4 '256.1.1.1' || valid_ipv4 '999.0.0.1' || valid_ipv4 '127.0.0'; then
  echo 'Invalid IPv4 address was accepted.' >&2
  exit 1
fi
valid_upstream_host 'localhost'
valid_upstream_host 'ssh.example.net'
valid_upstream_host '127.0.0.1'
if valid_upstream_host '999.1.1.1' || valid_upstream_host 'bad..host' || valid_upstream_host '-bad.example'; then
  echo 'Invalid SSH upstream host was accepted.' >&2
  exit 1
fi
"
grep -q 'root-owned regular file with mode 0600' "$ROOT_DIR/scripts/configure-dnstt-domain.sh"
grep -q 'must be a real directory, not a symlink' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -q 'bash "$SCRIPT_DIR/scripts/license.sh" verify' "$ROOT_DIR/scripts/install-dnstt.sh"
license_line="$(grep -n 'bash "$SCRIPT_DIR/scripts/license.sh" verify' "$ROOT_DIR/scripts/install-dnstt.sh" | cut -d: -f1)"
apt_line="$(grep -n '^apt-get update' "$ROOT_DIR/scripts/install-dnstt.sh" | cut -d: -f1)"
[[ -n "$license_line" && -n "$apt_line" && "$license_line" -lt "$apt_line" ]] || { echo "DNSTT installer must verify licence before apt changes." >&2; exit 1; }

# Preparing the unit must not stop iodine or activate DNSTT automatically.
if grep -E -q '^[[:space:]]*systemctl[[:space:]]+(stop|disable|enable|start|restart)[[:space:]]' "$SERVICE"; then
  echo "DNSTT preparation script must not change running services." >&2
  exit 1
fi

echo "DNSTT repository safety checks passed."
