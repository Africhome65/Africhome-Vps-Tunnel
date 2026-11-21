#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/modules/hysteria_users.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
HY2_USERS_CONFIG="$tmp_dir/config.yaml"
HY2_USERS_DB="$tmp_dir/users.json"
HY2_USERS_LOCK="$tmp_dir/lock"
AR_BASE_DIR="$tmp_dir/registry"
AR_REGISTRY="$AR_BASE_DIR/registry.json"
AR_LOCK="$tmp_dir/registry.lock"

cat > "$HY2_USERS_CONFIG" <<'YAML'
listen: :443
tls:
  cert: /tmp/fullchain.pem
  key: /tmp/privkey.pem
auth:
  type: userpass
  userpass:
    admin: old-secret
obfs:
  type: salamander
  salamander:
    password: obfs-secret
YAML
printf '[]\n' > "$HY2_USERS_DB"
chmod 600 "$HY2_USERS_CONFIG" "$HY2_USERS_DB"

hy2u_yaml_change add alice test-password
python3 - "$HY2_USERS_CONFIG" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f: d=yaml.safe_load(f)
assert d["auth"]["type"] == "userpass"
assert d["auth"]["userpass"]["admin"] == "old-secret"
assert d["auth"]["userpass"]["alice"] == "test-password"
assert d["obfs"]["salamander"]["password"] == "obfs-secret"
PY
if hy2u_yaml_change add alice duplicate-password; then
  echo "Duplicate Hysteria username was accepted." >&2; exit 1
fi
hy2u_yaml_change remove alice
python3 - "$HY2_USERS_CONFIG" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f: d=yaml.safe_load(f)
assert "alice" not in d["auth"]["userpass"]
assert d["auth"]["userpass"]["admin"] == "old-secret"
PY
cp "$HY2_USERS_CONFIG" "$tmp_dir/before.yaml"
python3 - "$HY2_USERS_CONFIG" <<'PY'
import sys, yaml
p=sys.argv[1]
with open(p, encoding="utf-8") as f: d=yaml.safe_load(f)
d["auth"]["type"]="password"
with open(p,"w",encoding="utf-8") as f: yaml.safe_dump(d,f)
PY
cp "$HY2_USERS_CONFIG" "$tmp_dir/unsupported.yaml"
if hy2u_yaml_change add bob password; then
  echo "Unsupported auth mode was modified." >&2; exit 1
fi
cmp -s "$HY2_USERS_CONFIG" "$tmp_dir/unsupported.yaml"

# Revocation must stage metadata and update the registry before changing the
# native config, with compensating rollback paths for failures.
remove_fn="$(sed -n '/^hy2u_remove() {/,/^}/p' "$ROOT/modules/hysteria_users.sh")"
grep -Fq 'ar_set_service_status "$account_id" "hysteria" "$username" "revoked"' <<< "$remove_fn"
grep -Fq 'ar_set_service_status "$account_id" "hysteria" "$username" "$previous_status"' <<< "$remove_fn"
grep -Fq 'dbbackup=' <<< "$remove_fn"
grep -Fq 'systemctl restart hysteria-server.service' <<< "$remove_fn"


expire_fn="$(sed -n '/^hy2u_expire() {/,/^}/p' "$ROOT/modules/hysteria_users.sh")"
grep -Fq 'ar_set_service_status "$account_id" hysteria "$username" expired' <<< "$expire_fn"
grep -Fq 'previous_status=' <<< "$expire_fn"
grep -Fq 'rstatus' <<< "$expire_fn"
grep -Fq 'registry_done+=' <<< "$expire_fn"
grep -Fq 'systemctl restart hysteria-server.service' <<< "$expire_fn"
grep -Fq 'install -o root -g root -m 600 "$tmp" "$HY2_USERS_DB"' <<< "$expire_fn"


# Config and metadata paths must not follow attacker-controlled symlinks.
regular_config="$tmp_dir/regular-config.yaml"
regular_db="$tmp_dir/regular-users.json"
printf 'auth: {type: userpass, userpass: {}}\n' > "$regular_config"
printf '[]\n' > "$regular_db"
ln -s "$regular_config" "$tmp_dir/config-link.yaml"
HY2_USERS_CONFIG="$tmp_dir/config-link.yaml"
HY2_USERS_DB="$regular_db"
if hy2u_require; then
  echo "Symlinked Hysteria config was accepted." >&2; exit 1
fi
HY2_USERS_CONFIG="$regular_config"
ln -s "$regular_db" "$tmp_dir/users-link.json"
HY2_USERS_DB="$tmp_dir/users-link.json"
if hy2u_require; then
  echo "Symlinked Hysteria metadata database was accepted." >&2; exit 1
fi
ln -s "$tmp_dir/should-not-be-created.json" "$tmp_dir/dangling-users.json"
HY2_USERS_DB="$tmp_dir/dangling-users.json"
if hy2u_require; then
  echo "Dangling symlinked Hysteria metadata path was accepted." >&2; exit 1
fi
[[ ! -e "$tmp_dir/should-not-be-created.json" ]] || {
  echo "Hysteria metadata initialization followed a dangling symlink." >&2; exit 1;
}

# Exercise revocation commit and restart-failure compensation against a
# temporary registry/config/database; never touch system services.
ah_require_root() { return 0; }
systemctl() { return 0; }
# CI is non-root; preserve install behavior while neutralizing root ownership
# flags that the real root-only command enforces on a VPS.
install() {
  if [[ "${1:-}" == "-o" && "${2:-}" == "root" && "${3:-}" == "-g" && "${4:-}" == "root" ]]; then
    shift 4
  fi
  command install "$@"
}
HY2_USERS_CONFIG="$tmp_dir/remove-ok.yaml"
HY2_USERS_DB="$tmp_dir/remove-ok.json"
HY2_USERS_LOCK="$tmp_dir/remove-ok.lock"
AR_BASE_DIR="$tmp_dir/remove-ok-registry"
AR_REGISTRY="$AR_BASE_DIR/registry.json"
AR_LOCK="$tmp_dir/remove-ok-registry.lock"
cat > "$HY2_USERS_CONFIG" <<'YAML'
auth:
  type: userpass
  userpass:
    alice: alice-password
YAML
printf '[{"account_id":"acctremove01","username":"alice","expires_at":0,"created_at":1}]\n' > "$HY2_USERS_DB"
chmod 600 "$HY2_USERS_CONFIG" "$HY2_USERS_DB"
ar_register_service acctremove01 alice hysteria alice 0
ar_set_service_status acctremove01 hysteria alice suspended
printf 'alice\n' | hy2u_remove
jq -e 'length == 0' "$HY2_USERS_DB" >/dev/null
python3 - "$HY2_USERS_CONFIG" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f: d=yaml.safe_load(f)
assert "alice" not in d["auth"]["userpass"]
PY
jq -e '.accounts[] | select(.id == "acctremove01") | .services[] | select(.ref == "alice") | .status == "revoked"' "$AR_REGISTRY" >/dev/null

# A failed first restart must restore config, local metadata, and the exact
# prior registry status (suspended), not blindly mark the account active.
HY2_USERS_CONFIG="$tmp_dir/remove-fail.yaml"
HY2_USERS_DB="$tmp_dir/remove-fail.json"
HY2_USERS_LOCK="$tmp_dir/remove-fail.lock"
AR_BASE_DIR="$tmp_dir/remove-fail-registry"
AR_REGISTRY="$AR_BASE_DIR/registry.json"
AR_LOCK="$tmp_dir/remove-fail-registry.lock"
cat > "$HY2_USERS_CONFIG" <<'YAML'
auth:
  type: userpass
  userpass:
    bob: bob-password
YAML
printf '[{"account_id":"acctremove02","username":"bob","expires_at":0,"created_at":1}]\n' > "$HY2_USERS_DB"
chmod 600 "$HY2_USERS_CONFIG" "$HY2_USERS_DB"
ar_register_service acctremove02 bob hysteria bob 0
ar_set_service_status acctremove02 hysteria bob suspended
SYSTEMCTL_CALLS=0
systemctl() {
  if [[ "$*" == "restart hysteria-server.service" ]]; then
    SYSTEMCTL_CALLS=$((SYSTEMCTL_CALLS + 1))
    (( SYSTEMCTL_CALLS > 1 ))
  else
    return 0
  fi
}
if printf 'bob\n' | hy2u_remove; then
  echo "Hysteria revocation unexpectedly succeeded after a failed restart." >&2; exit 1
fi
jq -e 'length == 1 and .[0].username == "bob"' "$HY2_USERS_DB" >/dev/null
python3 - "$HY2_USERS_CONFIG" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f: d=yaml.safe_load(f)
assert d["auth"]["userpass"]["bob"] == "bob-password"
PY
jq -e '.accounts[] | select(.id == "acctremove02") | .services[] | select(.ref == "bob") | .status == "suspended"' "$AR_REGISTRY" >/dev/null

# A two-account expiry batch must acquire/release the registry lock for each
# status transition and commit the complete batch once.
HY2_USERS_CONFIG="$tmp_dir/expire.yaml"
HY2_USERS_DB="$tmp_dir/expire.json"
HY2_USERS_LOCK="$tmp_dir/expire.lock"
AR_BASE_DIR="$tmp_dir/expire-registry"
AR_REGISTRY="$AR_BASE_DIR/registry.json"
AR_LOCK="$tmp_dir/expire-registry.lock"
cat > "$HY2_USERS_CONFIG" <<'YAML'
auth:
  type: userpass
  userpass:
    carol: carol-password
    dave: dave-password
YAML
printf '[{"account_id":"acctexpire01","username":"carol","expires_at":1,"created_at":1},{"account_id":"acctexpire02","username":"dave","expires_at":1,"created_at":1}]\n' > "$HY2_USERS_DB"
chmod 600 "$HY2_USERS_CONFIG" "$HY2_USERS_DB"
ar_register_service acctexpire01 carol hysteria carol 1
ar_register_service acctexpire02 dave hysteria dave 1
ar_set_service_status acctexpire01 hysteria carol suspended
ar_set_service_status acctexpire02 hysteria dave suspended
systemctl() { return 0; }
hy2u_expire
jq -e 'length == 0' "$HY2_USERS_DB" >/dev/null
python3 - "$HY2_USERS_CONFIG" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f: d=yaml.safe_load(f)
assert d["auth"]["userpass"] == {}
PY
jq -e '[.accounts[].services[].status] == ["expired","expired"]' "$AR_REGISTRY" >/dev/null

# A failed batch restart must restore the original config/database and each
# account's exact prior registry state, including mixed active/suspended states.
HY2_USERS_CONFIG="$tmp_dir/expire-fail.yaml"
HY2_USERS_DB="$tmp_dir/expire-fail.json"
HY2_USERS_LOCK="$tmp_dir/expire-fail.lock"
AR_BASE_DIR="$tmp_dir/expire-fail-registry"
AR_REGISTRY="$AR_BASE_DIR/registry.json"
AR_LOCK="$tmp_dir/expire-fail-registry.lock"
cat > "$HY2_USERS_CONFIG" <<'YAML'
auth:
  type: userpass
  userpass:
    erin: erin-password
    frank: frank-password
YAML
printf '[{"account_id":"acctexpire03","username":"erin","expires_at":1,"created_at":1},{"account_id":"acctexpire04","username":"frank","expires_at":1,"created_at":1}]\n' > "$HY2_USERS_DB"
chmod 600 "$HY2_USERS_CONFIG" "$HY2_USERS_DB"
ar_register_service acctexpire03 erin hysteria erin 1
ar_register_service acctexpire04 frank hysteria frank 1
ar_set_service_status acctexpire03 hysteria erin suspended
SYSTEMCTL_CALLS=0
systemctl() {
  if [[ "$*" == "restart hysteria-server.service" ]]; then
    SYSTEMCTL_CALLS=$((SYSTEMCTL_CALLS + 1))
    (( SYSTEMCTL_CALLS > 1 ))
  else
    return 0
  fi
}
if hy2u_expire; then
  echo "Hysteria expiry unexpectedly succeeded after a failed restart." >&2; exit 1
fi
jq -e 'length == 2' "$HY2_USERS_DB" >/dev/null
python3 - "$HY2_USERS_CONFIG" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f: d=yaml.safe_load(f)
assert d["auth"]["userpass"] == {"erin":"erin-password", "frank":"frank-password"}
PY
jq -e '[.accounts[].services[].status] == ["suspended","active"]' "$AR_REGISTRY" >/dev/null

unset -f systemctl ah_require_root install
echo "Hysteria userpass adapter validation passed."
