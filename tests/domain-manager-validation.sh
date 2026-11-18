#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DM_STATE_DIR="$TMP/domains"
export DM_DB="$DM_STATE_DIR/domains.json"
export DM_LE_DIR="$TMP/live"
. "$ROOT/modules/domain_manager.sh"

for d in example.com vpn.example.co.uk a-b.example.net; do dm_valid_domain "$d"; done
for d in "" localhost "-bad.example.com" "bad-.example.com" "bad..example.com" "bad example.com" ".example.com" "example.com."; do
  if dm_valid_domain "$d"; then echo "Invalid domain accepted: $d" >&2; exit 1; fi
done

dm_register_domain vpn.example.com
[[ "$(jq 'length' "$DM_DB")" == "1" ]]
[[ "$(jq -r '.[0].domain' "$DM_DB")" == "vpn.example.com" ]]
[[ "$(stat -c '%a' "$DM_DB")" == "600" ]]
if dm_register_domain vpn.example.com 2>/dev/null; then
  echo "Duplicate domain registration was accepted." >&2; exit 1
fi

mkdir -p "$DM_LE_DIR/vpn.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DM_LE_DIR/vpn.example.com/privkey.pem" \
  -out "$DM_LE_DIR/vpn.example.com/fullchain.pem" -days 2 \
  -subj "/CN=vpn.example.com" -addext "subjectAltName=DNS:vpn.example.com" >/dev/null 2>&1
dm_cert_check vpn.example.com >/dev/null

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/wrong.key" >/dev/null 2>&1
cp "$TMP/wrong.key" "$DM_LE_DIR/vpn.example.com/privkey.pem"
if dm_cert_check vpn.example.com >/dev/null 2>&1; then
  echo "Mismatched certificate/key pair was accepted." >&2; exit 1
fi
echo "Domain manager validation passed."
