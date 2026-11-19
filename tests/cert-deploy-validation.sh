#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/lib/common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export DM_STATE_DIR="$TMP/domains"
export DM_DB="$DM_STATE_DIR/domains.json"
. "$ROOT/modules/domain_manager.sh"
. "$ROOT/modules/cert_deploy.sh"
CD_CONFIG="$TMP/cert-deploy.json"
CD_LEGACY_HOOK="$TMP/no-legacy-hook"

cd_target_add vpn.example.com xray
[[ "$(jq 'length' "$CD_CONFIG")" == "1" ]]
[[ "$(jq -r '.[0].cert' "$CD_CONFIG")" == "/etc/xray/certs/fullchain.pem" ]]
[[ "$(jq -r '.[0].unit' "$CD_CONFIG")" == "xray.service" ]]
[[ "$(stat -c '%a' "$CD_CONFIG")" == "600" ]]

if cd_target_add vpn.example.com xray 2>/dev/null; then
  echo "Duplicate certificate target accepted." >&2; exit 1
fi
if cd_target_add vpn.example.com arbitrary 2>/dev/null; then
  echo "Unsupported certificate target accepted." >&2; exit 1
fi
if cd_deploy_one "$TMP" vpn.example.com xray /tmp/other/fullchain.pem /tmp/other/privkey.pem root xray xray.service 2>/dev/null; then
  echo "Unapproved destination paths accepted." >&2; exit 1
fi
echo "Certificate deployment registry validation passed."
