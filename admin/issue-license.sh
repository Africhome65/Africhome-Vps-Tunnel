#!/usr/bin/env bash
set -Eeuo pipefail
usage() {
  echo "Usage: $0 PRIVATE_KEY.pem LICENCE_ID VPS_FINGERPRINT" >&2
  echo "Get the target VPS fingerprint with: sudo bash scripts/license.sh fingerprint" >&2
  exit 2
}
[[ $# -eq 3 ]] || usage
private_key="$1"; licence_id="$2"; fingerprint="${3,,}"
[[ -r "$private_key" ]] || { echo "Private key is not readable." >&2; exit 1; }
[[ "$licence_id" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || { echo "Licence ID must be 4-64 letters, digits, _ or -." >&2; exit 1; }
[[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || { echo "Fingerprint must be 64 hexadecimal characters." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "OpenSSL is required." >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "base64 is required." >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'AFRICHOME-LICENSE-V2\nid=%s\nfingerprint=%s\ntype=lifetime\n' "$licence_id" "$fingerprint" >"$tmp/payload"
openssl pkeyutl -sign -inkey "$private_key" -rawin -in "$tmp/payload" -out "$tmp/signature"
payload_b64="$(base64 <"$tmp/payload" | tr -d '\r\n')"
signature_b64="$(base64 <"$tmp/signature" | tr -d '\r\n')"
printf '%s.%s\n' "$payload_b64" "$signature_b64"
