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
ar_register_service "acct_test_0001" "alice" "hysteria" "alice" 12345
ar_register_service "acct_test_0001" "alice" "ssh" "alice" 12345
dashboard="$(ar_dashboard)"
grep -Fq "AFRICHOME ACCOUNT DASHBOARD" <<< "$dashboard"
grep -Fq "Registered accounts: 1" <<< "$dashboard"
grep -Fq "alice" <<< "$dashboard"
grep -Fq "expired (cleanup pending)" <<< "$dashboard"
grep -Fq "active" <<< "$dashboard"
grep -Fq "inactive" <<< "$dashboard"
grep -Fq "does not discover unmanaged native accounts" <<< "$dashboard"
if grep -Fq "hy2-user-001" <<< "$dashboard" || grep -Eiq 'password|credential|private_key|client_uri' <<< "$dashboard"; then
  echo "Dashboard exposed a native reference or secret-like field." >&2; exit 1
fi


# Reconciliation compares only identifiers and labels, never credentials.
cat > "$tmp_dir/protocol-users.json" <<'EOF'
[
  {"account_id":"acct_test_0001","protocol":"vless","name":"alice","email":"vless-email-001","credential":"XRAY_SECRET_SENTINEL","expires_at":0},
  {"account_id":"acct_local_0002","protocol":"vmess","name":"orphan-vmess","email":"vmess-email-002","credential":"VMESS_SECRET_SENTINEL","expires_at":0}
]
EOF
cat > "$tmp_dir/hysteria-users.json" <<'EOF'
[
  {"account_id":"acct_test_0001","username":"alice","password":"HYSTERIA_SECRET_SENTINEL","expires_at":12345},
  {"account_id":"acct_local_0003","username":"orphan-hy2","password":"OTHER_SECRET_SENTINEL","expires_at":0}
]
EOF
cat > "$tmp_dir/passwd-fixture" <<'EOF'
alice:x:1001:1001::/home/alice:/bin/bash
bob:x:1002:1002::/home/bob:/bin/bash
svcuser:x:999:999::/nonexistent:/usr/sbin/nologin
EOF
cat > "$tmp_dir/bin/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "passwd" && -n "${2:-}" ]]; then
  awk -F: -v n="$2" '$1 == n {print; found=1} END {exit !found}' "$AR_TEST_PASSWD_FILE"
elif [[ "$1" == "passwd" ]]; then
  cat "$AR_TEST_PASSWD_FILE"
else
  exit 2
fi
EOF
chmod 700 "$tmp_dir/bin/getent"

cat > "$tmp_dir/xray-config.json" <<'EOF'
{
  "inbounds": [
    {"protocol":"vless","settings":{"clients":[
      {"email":"vless-email-001","id":"XRAY_CONFIG_SECRET"},
      {"email":"manual-vless-only","id":"MANUAL_XRAY_SECRET"}
    ]}}
  ]
}
EOF
cat > "$tmp_dir/hysteria-config.yaml" <<'EOF'
auth:
  type: userpass
  userpass:
    alice: "HYSTERIA_CONFIG_SECRET"
    orphan-hy2: "ORPHAN_HYSTERIA_SECRET"
    manual-hy2: "MANUAL_HYSTERIA_SECRET"
EOF
export AR_PROTOCOL_DB="$tmp_dir/protocol-users.json"
export AR_HYSTERIA_DB="$tmp_dir/hysteria-users.json"
export AR_XRAY_CONFIG="$tmp_dir/xray-config.json"
export AR_HYSTERIA_CONFIG="$tmp_dir/hysteria-config.yaml"
export AR_TEST_PASSWD_FILE="$tmp_dir/passwd-fixture"
cp "$AR_REGISTRY" "$tmp_dir/registry.before"
cp "$AR_PROTOCOL_DB" "$tmp_dir/protocol.before"
cp "$AR_HYSTERIA_DB" "$tmp_dir/hysteria.before"
reconciliation="$(ar_reconcile)"
grep -Fq "local metadata exists; registry entry missing" <<< "$reconciliation"
grep -Fq "registry record missing from local metadata and/or native config" <<< "$reconciliation"
grep -Fq "interactive Linux user not registered (review candidate)" <<< "$reconciliation"
grep -Fq "Summary: local-only=2, registry-only=1, unregistered SSH candidates=1, skipped sources=0" <<< "$reconciliation"
grep -Fq "Native-only=2, stale-local=1" <<< "$reconciliation"
if grep -Eiq 'XRAY_SECRET_SENTINEL|VMESS_SECRET_SENTINEL|HYSTERIA_SECRET_SENTINEL|OTHER_SECRET_SENTINEL|XRAY_CONFIG_SECRET|MANUAL_XRAY_SECRET|HYSTERIA_CONFIG_SECRET|ORPHAN_HYSTERIA_SECRET|MANUAL_HYSTERIA_SECRET|credential|password' <<< "$reconciliation"; then
  echo "Reconciliation exposed a credential or secret-like field." >&2; exit 1
fi
cmp -s "$AR_REGISTRY" "$tmp_dir/registry.before"
cmp -s "$AR_PROTOCOL_DB" "$tmp_dir/protocol.before"
cmp -s "$AR_HYSTERIA_DB" "$tmp_dir/hysteria.before"

echo "Central account registry, dashboard, and reconciliation validation passed."
