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
printf 'auth: {type: userpass, userpass: {}}\\n' > "$regular_config"
printf '[]\\n' > "$regular_db"
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
\necho "Hysteria userpass adapter validation passed."
