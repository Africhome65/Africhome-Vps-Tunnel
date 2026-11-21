#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'sudo rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/admin" "$TMP/keys"
cp "$ROOT/scripts/license.sh" "$TMP/scripts/license.sh"
cp "$ROOT/admin/issue-license.sh" "$TMP/admin/issue-license.sh"
chmod 0755 "$TMP/scripts/license.sh" "$TMP/admin/issue-license.sh"

# Use an isolated public key and state directory; never touch /etc/africhome.
openssl genpkey -algorithm ED25519 -out "$TMP/test-private.pem"
chmod 0600 "$TMP/test-private.pem"
openssl pkey -in "$TMP/test-private.pem" -pubout -out "$TMP/keys/license-public.pem"
sed -i "s|LICENSE_DIR=\"/etc/africhome\"|LICENSE_DIR=\"$TMP/state\"|" "$TMP/scripts/license.sh"
FINGERPRINT="$(bash "$TMP/scripts/license.sh" fingerprint)"
VALID_TOKEN="$(bash "$TMP/admin/issue-license.sh" "$TMP/test-private.pem" TEST-LICENCE "$FINGERPRINT")"

write_token() {
  printf '%s\n' "$1" | sudo tee "$TMP/state/license.token" >/dev/null
  sudo chown root:root "$TMP/state/license.token"
  sudo chmod 0600 "$TMP/state/license.token"
}
verify_ok() {
  sudo bash "$TMP/scripts/license.sh" verify >/dev/null 2>&1
}
expect_fail() {
  local label="$1"
  shift
  if "$@"; then
    echo "FAIL: $label unexpectedly succeeded" >&2
    exit 1
  fi
  echo "PASS: $label"
}

sudo install -d -o root -g root -m 0700 "$TMP/state"
write_token "$VALID_TOKEN"
verify_ok
echo "PASS: valid machine-bound Ed25519 licence"

write_token "not-a-valid-token"
expect_fail "malformed token rejected" verify_ok

IFS='.' read -r PAYLOAD_B64 SIGNATURE_B64 <<< "$VALID_TOKEN"
printf '%s' "$PAYLOAD_B64" | base64 -d > "$TMP/payload"
printf 'tampered' >> "$TMP/payload"
TAMPERED_PAYLOAD="$(base64 -w0 "$TMP/payload").$SIGNATURE_B64"
write_token "$TAMPERED_PAYLOAD"
expect_fail "tampered payload rejected" verify_ok

openssl genpkey -algorithm ED25519 -out "$TMP/other-private.pem"
chmod 0600 "$TMP/other-private.pem"
openssl pkeyutl -sign -inkey "$TMP/other-private.pem" -rawin -in "$TMP/payload" -out "$TMP/other-signature"
TAMPERED_SIGNATURE="$(base64 -w0 "$TMP/payload").$(base64 -w0 "$TMP/other-signature")"
write_token "$TAMPERED_SIGNATURE"
expect_fail "tampered signature rejected" verify_ok

WRONG_TOKEN="$(bash "$TMP/admin/issue-license.sh" "$TMP/test-private.pem" WRONG-VPS "$(printf '%064d' 0)")"
write_token "$WRONG_TOKEN"
expect_fail "wrong VPS fingerprint rejected" verify_ok

printf 'AFRICHOME-LICENSE-V1\nid=OLD-LICENCE\nexpires=2020-01-01\nfingerprint=%s\n' "$FINGERPRINT" > "$TMP/expired-payload"
openssl pkeyutl -sign -inkey "$TMP/test-private.pem" -rawin -in "$TMP/expired-payload" -out "$TMP/expired-signature"
EXPIRED_TOKEN="$(base64 -w0 "$TMP/expired-payload").$(base64 -w0 "$TMP/expired-signature")"
write_token "$EXPIRED_TOKEN"
expect_fail "expired legacy V1 licence rejected" verify_ok

# The issuer must reject a key that does not match the public key in this checkout.
expect_fail "mismatched signing key rejected" bash "$TMP/admin/issue-license.sh" "$TMP/other-private.pem" OTHER-LICENCE "$FINGERPRINT"

chmod 0644 "$TMP/test-private.pem"
expect_fail "over-permissive signing key rejected" bash "$TMP/admin/issue-license.sh" "$TMP/test-private.pem" TEST-LICENCE "$FINGERPRINT"
chmod 0600 "$TMP/test-private.pem"
ln -s "$TMP/test-private.pem" "$TMP/private-key-symlink.pem"
expect_fail "signing-key symlink rejected" bash "$TMP/admin/issue-license.sh" "$TMP/private-key-symlink.pem" TEST-LICENCE "$FINGERPRINT"

echo "Licence validation tests passed."
