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
[[ -f "$private_key" && ! -L "$private_key" ]] || { echo "Private key must be a regular file, not a symlink." >&2; exit 1; }
key_owner="$(stat -c '%u' "$private_key")"
key_mode="$(stat -c '%a' "$private_key")"
[[ "$key_owner" == "$EUID" && "$key_mode" =~ ^[0-7]{3,4}$ ]] || { echo "Private key must be owned by the current user." >&2; exit 1; }
(( (8#$key_mode & 077) == 0 )) || { echo "Private key permissions are too open; remove group/other access (recommended mode: 0600)." >&2; exit 1; }
[[ "$licence_id" =~ ^[A-Za-z0-9_-]{4,64}$ ]] || { echo "Licence ID must be 4-64 letters, digits, _ or -." >&2; exit 1; }
[[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || { echo "Fingerprint must be 64 hexadecimal characters." >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "OpenSSL is required." >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "base64 is required." >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_KEY="$SCRIPT_DIR/keys/license-public.pem"
[[ -f "$PUBLIC_KEY" && ! -L "$PUBLIC_KEY" && -r "$PUBLIC_KEY" ]] || { echo "Repository licence public key is missing or unsafe." >&2; exit 1; }
openssl pkey -in "$private_key" -pubout -outform DER -out "$tmp/issuer-public.der" 2>/dev/null || { echo "Could not read an Ed25519 private signing key." >&2; exit 1; }
openssl pkey -pubin -in "$PUBLIC_KEY" -outform DER -out "$tmp/repository-public.der" 2>/dev/null || { echo "Could not read repository licence public key." >&2; exit 1; }
cmp -s "$tmp/issuer-public.der" "$tmp/repository-public.der" || { echo "Private key does not match this repository's licence public key." >&2; exit 1; }
printf 'AFRICHOME-LICENSE-V2\nid=%s\nfingerprint=%s\ntype=lifetime\n' "$licence_id" "$fingerprint" >"$tmp/payload"
openssl pkeyutl -sign -inkey "$private_key" -rawin -in "$tmp/payload" -out "$tmp/signature"
payload_b64="$(base64 <"$tmp/payload" | tr -d '\r\n')"
signature_b64="$(base64 <"$tmp/signature" | tr -d '\r\n')"
printf '%s.%s\n' "$payload_b64" "$signature_b64"
