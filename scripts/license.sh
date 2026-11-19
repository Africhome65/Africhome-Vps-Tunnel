#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_KEY="$SCRIPT_DIR/keys/license-public.pem"
LICENSE_DIR="/etc/africhome"
LICENSE_FILE="$LICENSE_DIR/license.token"
fail(){ echo "[LICENCE ERROR] $*" >&2; exit 1; }
machine_fingerprint() {
  [[ -r /etc/machine-id ]] || fail "This VPS has no readable /etc/machine-id."
  local machine_id
  machine_id="$(tr -d '[:space:]' </etc/machine-id)"
  [[ "$machine_id" =~ ^[a-fA-F0-9]{32}$ ]] || fail "The VPS machine ID is invalid."
  printf '%s' "$machine_id" | sha256sum | awk '{print $1}'
}
verify_token() {
  local token="$1" payload_b64 signature_b64 extra tmp payload
  [[ -r "$PUBLIC_KEY" ]] || fail "The Africhome licence public key is missing."
  command -v openssl >/dev/null 2>&1 || fail "OpenSSL is required to verify the licence. Install it, then rerun the installer."
  command -v base64 >/dev/null 2>&1 || fail "The base64 utility is required."
  command -v sha256sum >/dev/null 2>&1 || fail "The sha256sum utility is required."
  [[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] || fail "The licence key must be a single line."
  IFS='.' read -r payload_b64 signature_b64 extra <<<"$token"
  [[ -n "$payload_b64" && -n "$signature_b64" && -z "${extra:-}" ]] || fail "Invalid licence-key format."
  tmp="$(mktemp -d)" || fail "Could not create temporary verification workspace."
  trap 'rm -rf "$tmp"' RETURN
  printf '%s' "$payload_b64" | base64 -d >"$tmp/payload" 2>/dev/null || fail "Invalid licence payload encoding."
  printf '%s' "$signature_b64" | base64 -d >"$tmp/signature" 2>/dev/null || fail "Invalid licence signature encoding."
  openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY" -rawin -in "$tmp/payload" -sigfile "$tmp/signature" >/dev/null 2>&1 || fail "Licence signature is invalid."
  payload="$(cat "$tmp/payload")"
  [[ "$payload" == AFRICHOME-LICENSE-V1$'\n'id=* ]] || fail "Unsupported licence format."
  [[ "$(printf '%s\n' "$payload" | wc -l)" -eq 4 ]] || fail "Malformed licence payload."
  local licence_id expiry fingerprint expected
  licence_id="$(printf '%s\n' "$payload" | sed -n '2s/^id=//p')"
  expiry="$(printf '%s\n' "$payload" | sed -n '3s/^expires=//p')"
  fingerprint="$(printf '%s\n' "$payload" | sed -n '4s/^fingerprint=//p')"
  [[ "$licence_id" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || fail "Invalid licence ID."
  [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "Invalid licence expiry date."
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || fail "Invalid VPS fingerprint."
  date -u -d "$expiry" '+%Y-%m-%d' 2>/dev/null | grep -Fxq "$expiry" || fail "Invalid licence expiry date."
  [[ "$(date -u '+%Y-%m-%d')" < "$expiry" || "$(date -u '+%Y-%m-%d')" == "$expiry" ]] || fail "Licence expired on $expiry (UTC)."
  expected="$(machine_fingerprint)"
  [[ "$fingerprint" == "$expected" ]] || fail "This licence belongs to a different VPS."
  printf '%s' "$licence_id"
}
case "${1:-verify}" in
  fingerprint) machine_fingerprint ;;
  verify)
    [[ "${EUID}" -eq 0 ]] || fail "Run the installer as root."
    printf 'Enter your Africhome VPS licence key: ' >/dev/tty
    IFS= read -r -s token </dev/tty || fail "Could not read licence key."
    printf '\n' >/dev/tty
    licence_id="$(verify_token "$token")"
    install -d -o root -g root -m 0700 "$LICENSE_DIR"
    umask 077
    printf '%s\n' "$token" >"$LICENSE_FILE"
    unset token
    chown root:root "$LICENSE_FILE"
    chmod 0600 "$LICENSE_FILE"
    echo "Licence accepted: $licence_id"
    ;;
  *) fail "Usage: $0 [verify|fingerprint]" ;;
esac
