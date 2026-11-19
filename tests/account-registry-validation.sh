#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/modules/account_registry.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
AR_BASE_DIR="$tmp_dir/state"
AR_REGISTRY="$AR_BASE_DIR/registry.json"
AR_LOCK="$tmp_dir/registry.lock"

ar_init
ar_register_service "acct_test_0001" "alice" "vless" "vless-email-001" 0
ar_register_service "acct_test_0001" "alice" "trojan" "trojan-email-001" 0
[[ "$(jq '.accounts | length' "$AR_REGISTRY")" == "1" ]]
[[ "$(jq '.accounts[0].services | length' "$AR_REGISTRY")" == "2" ]]
ar_register_service "acct_test_0001" "alice" "vless" "vless-email-001" 12345
[[ "$(jq '.accounts[0].services | length' "$AR_REGISTRY")" == "2" ]]
[[ "$(jq -r '.accounts[0].expires_at' "$AR_REGISTRY")" == "12345" ]]
ar_set_service_status "acct_test_0001" "vless" "vless-email-001" "suspended"
[[ "$(jq -r '.accounts[0].services[] | select(.service == "vless") | .status' "$AR_REGISTRY")" == "suspended" ]]
[[ "$(stat -c '%a' "$AR_REGISTRY")" == "600" ]]
if ar_register_service "bad id" "alice" "vless" "vless-email-002" 0; then
  echo "Invalid account ID was accepted." >&2; exit 1
fi
if grep -Eiq 'password|private_key|client_uri|credential' "$AR_REGISTRY"; then
  echo "Registry unexpectedly contains a secret-like field." >&2; exit 1
fi

# Dashboard is read-only, reports expiry and host-service state, and hides
# native service references and credentials.
mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1:$3" in
  is-active:xray.service|is-active:ssh.service) exit 0 ;;
  is-enabled:hysteria-server.service) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$tmp_dir/bin/systemctl"
PATH="$tmp_dir/bin:$PATH"
ar_register_service "acct_test_0002" "olduser" "hysteria" "private-native-ref" 12345
dashboard="$(ar_dashboard)"
grep -Fq "AFRICHOME ACCOUNT DASHBOARD" <<< "$dashboard"
grep -Fq "Registered accounts: 2" <<< "$dashboard"
grep -Fq "olduser" <<< "$dashboard"
grep -Fq "expired (cleanup pending)" <<< "$dashboard"
grep -Fq "active" <<< "$dashboard"
grep -Fq "inactive" <<< "$dashboard"
grep -Fq "does not discover unmanaged native accounts" <<< "$dashboard"
if grep -Fq "private-native-ref" <<< "$dashboard" || grep -Eiq 'password|credential|private_key|client_uri' <<< "$dashboard"; then
  echo "Dashboard exposed a native reference or secret-like field." >&2; exit 1
fi

echo "Central account registry and dashboard validation passed."
