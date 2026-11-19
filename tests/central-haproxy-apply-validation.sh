#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/config" "$TMP/run/lock"
CANDIDATE="$TMP/candidate.cfg"
cat > "$CANDIDATE" <<'CFG'
frontend test80
    bind 0.0.0.0:80
frontend test443
    bind 0.0.0.0:443
CFG
chmod 0600 "$CANDIDATE"
cat > "$TMP/bin/haproxy" <<'MOCK'
#!/usr/bin/env bash
[[ "\${MOCK_HAPROXY_FAIL:-0}" != 1 ]]
MOCK
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  is-active) [[ -f "$MOCK_RUNNING" ]] ;;
  start) [[ "\${MOCK_FAIL_START:-0}" != 1 ]] || exit 1; touch "$MOCK_RUNNING" ;;
  stop) rm -f "$MOCK_RUNNING" ;;
  *) exit 2 ;;
esac
MOCK
cat > "$TMP/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "\${MOCK_BUSY_PORT:-}" ]]; then
  printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$MOCK_BUSY_PORT"
fi
if [[ -f "$MOCK_RUNNING" ]]; then
  printf 'LISTEN 0 128 0.0.0.0:80 0.0.0.0:*\n'
  printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n'
fi
MOCK
chmod 0700 "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export MOCK_RUNNING="$TMP/running"
export AFRICHOME_HAPROXY_CANDIDATE="$CANDIDATE"
export AFRICHOME_HAPROXY_CONFIG_DIR="$TMP/config"
export AFRICHOME_HAPROXY_CONFIG_FILE="$TMP/config/haproxy.cfg"
export AFRICHOME_HAPROXY_BACKUP_ROOT="$TMP/backups"
export AFRICHOME_HAPROXY_LOCK_FILE="$TMP/run/lock/apply.lock"
export AFRICHOME_HAPROXY_BIN="$TMP/bin/haproxy"
export AFRICHOME_SYSTEMCTL_BIN="$TMP/bin/systemctl"
export AFRICHOME_SS_BIN="$TMP/bin/ss"

printf 'original config\n' > "$AFRICHOME_HAPROXY_CONFIG_FILE"
if printf 'APPLY\n' | MOCK_BUSY_PORT=443 bash "$ROOT/scripts/apply-central-haproxy.sh" --apply; then
  echo "Expected occupied-port refusal." >&2; exit 1
fi
grep -q '^original config$' "$AFRICHOME_HAPROXY_CONFIG_FILE"
[[ ! -e "$MOCK_RUNNING" ]]

if printf 'APPLY\n' | MOCK_FAIL_START=1 bash "$ROOT/scripts/apply-central-haproxy.sh" --apply; then
  echo "Expected failed-start rollback." >&2; exit 1
fi
grep -q '^original config$' "$AFRICHOME_HAPROXY_CONFIG_FILE"
[[ ! -e "$MOCK_RUNNING" ]]

rm -f "$AFRICHOME_HAPROXY_CONFIG_FILE"
printf 'APPLY\n' | bash "$ROOT/scripts/apply-central-haproxy.sh" --apply
grep -q '^    bind 0.0.0.0:80$' "$AFRICHOME_HAPROXY_CONFIG_FILE"
grep -q '^    bind 0.0.0.0:443$' "$AFRICHOME_HAPROXY_CONFIG_FILE"
[[ -f "$MOCK_RUNNING" ]]
[[ "$(stat -c '%a' "$AFRICHOME_HAPROXY_CONFIG_FILE")" == 640 ]]
compgen -G "$TMP/backups/transaction.*" >/dev/null

echo "Central HAProxy apply transaction validation passed."
