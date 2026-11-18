#!/usr/bin/env bash
# Revoke expired Africhome WireGuard peers.
set -Eeuo pipefail
WG_CONF="/etc/wireguard/wg0.conf"
CLIENT_DIR="/root/africhome-wireguard-clients"
EXPORT_DIR="/home/africhome-wireguard-clients"
EXPIRY_DIR="/etc/africhome/wireguard-expiry"
[[ -d "$EXPIRY_DIR" && -s "$WG_CONF" ]] || exit 0
now="$(date +%s)"
for meta in "$EXPIRY_DIR"/*.expiry; do
  [[ -f "$meta" ]] || continue
  name="${meta##*/}"; name="${name%.expiry}"
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || continue
  expiry="$(sed -n '1p' "$meta")"
  pub="$(sed -n '2p' "$meta")"
  [[ "$pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || continue
  if [[ "$expiry" =~ ^[0-9]+$ ]]; then expiry_ts="$expiry"
  elif [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then expiry_ts="$(date -d "$expiry 23:59:59" +%s 2>/dev/null || echo 0)"
  else continue; fi
  (( expiry_ts > 0 && expiry_ts <= now )) || continue
  grep -Fq "# client:$name" "$WG_CONF" || { rm -f "$meta"; continue; }
  backup="$(mktemp)"
  tmp="$(mktemp /etc/wireguard/wg0expireXXXXXX.conf)"
  cp -a "$WG_CONF" "$backup"
  if ! awk -v marker="# client:$name" '
    $0==marker {skip=1; next}
    skip && /^# client:/ {skip=0}
    !skip {print}
  ' "$WG_CONF" > "$tmp"; then
    rm -f "$backup" "$tmp"
    continue
  fi
  chmod 600 "$tmp"
  if ! wg-quick strip "$tmp" >/dev/null 2>&1 || ! install -m 600 "$tmp" "$WG_CONF"; then
    cp -a "$backup" "$WG_CONF"
    rm -f "$backup" "$tmp"
    continue
  fi
  if systemctl is-active --quiet wg-quick@wg0; then
    wg set wg0 peer "$pub" remove || {
      cp -a "$backup" "$WG_CONF"
      rm -f "$backup" "$tmp"
      continue
    }
  fi
  rm -f "$backup" "$tmp" "$CLIENT_DIR/$name.conf" "$EXPORT_DIR/$name.conf" "$meta"
  logger -t africhome-wg-expiry "Revoked expired WireGuard client: $name"
done
