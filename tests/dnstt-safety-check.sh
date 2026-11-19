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

# Preparing the unit must not stop iodine or activate DNSTT automatically.
if grep -E -q '^[[:space:]]*systemctl[[:space:]]+(stop|disable|enable|start|restart)[[:space:]]' "$SERVICE"; then
  echo "DNSTT preparation script must not change running services." >&2
  exit 1
fi

echo "DNSTT repository safety checks passed."
