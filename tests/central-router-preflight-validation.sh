#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/haproxy" <<'MOCK'
#!/usr/bin/env bash
[[ "${MOCK_HAPROXY_FAIL:-0}" != 1 ]]
MOCK
cat > "$TMP/bin/ss" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_SS_OUTPUT:-}"
MOCK
chmod 0755 "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
candidate="$TMP/candidate.cfg"
printf 'global\ndefaults\n' > "$candidate"
chmod 0600 "$candidate"
chown root:root "$candidate"

bash "$ROOT/scripts/central-router-preflight.sh" "$candidate" > "$TMP/clean.out"
grep -q 'No TCP listener on port 80 or 443' "$TMP/clean.out"

if MOCK_SS_OUTPUT='LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("xray",pid=123,fd=3))' \
  bash "$ROOT/scripts/central-router-preflight.sh" "$candidate" > "$TMP/busy.out" 2>&1; then
  echo "Occupied listener was accepted." >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 3 ]] || { cat "$TMP/busy.out" >&2; exit 1; }
fi
grep -q 'xray' "$TMP/busy.out"

if MOCK_HAPROXY_FAIL=1 bash "$ROOT/scripts/central-router-preflight.sh" "$candidate" >/dev/null 2>&1; then
  echo "Invalid HAProxy candidate was accepted." >&2
  exit 1
fi

ln -s "$candidate" "$TMP/candidate-link.cfg"
if bash "$ROOT/scripts/central-router-preflight.sh" "$TMP/candidate-link.cfg" >/dev/null 2>&1; then
  echo "Symlink candidate was accepted." >&2
  exit 1
fi

if grep -Eiq 'apt-get|systemctl[[:space:]]+(start|stop|restart|reload)|ufw[[:space:]]+(allow|deny|delete)|nft[[:space:]]+(add|delete|flush)|mv[[:space:]]|install[[:space:]]' "$ROOT/scripts/central-router-preflight.sh"; then
  echo "Mutating command found in read-only preflight." >&2
  exit 1
fi
echo "Central-router read-only preflight validation passed."
