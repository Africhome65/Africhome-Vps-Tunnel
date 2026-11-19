#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/etc/dnstt" "$TMP/etc/systemd/system"
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  list-unit-files) printf 'dnstt-server.service enabled\n' ;;
  is-active) printf 'active\n' ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TMP/bin/ss" <<'MOCK'
#!/usr/bin/env bash
printf 'UNCONN 0 0 0.0.0.0:5300 0.0.0.0:* users:(("dnstt-server",pid=123,fd=4))\n'
MOCK
chmod +x "$TMP/bin/"*
printf 'PRIVATE-DNSTT-KEY-MUST-NOT-APPEAR\n' > "$TMP/etc/dnstt/server.key"
printf 'PUBLIC-DNSTT-KEY-MAY-EXIST\n' > "$TMP/etc/dnstt/server.pub"
printf 'SECRET-CONFIG-MUST-NOT-APPEAR\n' > "$TMP/etc/dnstt/dnstt.conf"
printf '[Service]\nEnvironment=TOKEN=SECRET-ENV-MUST-NOT-APPEAR\n' > "$TMP/etc/systemd/system/dnstt.service"

# Run in an isolated filesystem view by replacing the inventory's fixed paths
# in a temporary copy; production script remains read-only and unchanged.
sed "s|/etc/dnstt|$TMP/etc/dnstt|g; s|/etc/systemd/system/dnstt.service|$TMP/etc/systemd/system/dnstt.service|g; s|/etc/africhome-dnstt.env|$TMP/etc/africhome-dnstt.env|g; s|/etc/africhome-dnstt.conf|$TMP/etc/africhome-dnstt.conf|g" \
  "$ROOT/scripts/dnstt-inventory.sh" > "$TMP/inventory.sh"
PATH="$TMP/bin:$PATH" bash "$TMP/inventory.sh" > "$TMP/output"
grep -q 'server.key.*PRESENT' "$TMP/output"
grep -q 'dnstt-server' "$TMP/output"
grep -q '5300' "$TMP/output"
if grep -q 'PRIVATE-DNSTT-KEY-MUST-NOT-APPEAR\|SECRET-CONFIG-MUST-NOT-APPEAR\|SECRET-ENV-MUST-NOT-APPEAR' "$TMP/output"; then
  echo "DNSTT inventory leaked private or configuration secrets." >&2
  exit 1
fi
echo "DNSTT inventory privacy validation passed."
