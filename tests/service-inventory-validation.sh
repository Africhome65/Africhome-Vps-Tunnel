#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/openvpn/server"
cat > "$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  list-unit-files) exit 0 ;;
  is-active) printf 'inactive\n' ;;
  *) exit 0 ;;
esac
MOCK
cat > "$TMP/bin/ss" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
cat > "$TMP/openvpn/server/server.conf" <<'CONF'
proto tcp
port 1194
dev tun
<key>
PRIVATE-KEY-MUST-NOT-APPEAR
</key>
# auth-user-pass /secret/password-file
CONF
OPENVPN_INVENTORY_DIRS="$TMP/openvpn" bash "$ROOT/scripts/openvpn-inventory.sh" > "$TMP/openvpn.out"
grep -q 'server.conf' "$TMP/openvpn.out"
grep -q 'tcp' "$TMP/openvpn.out"
grep -q '1194' "$TMP/openvpn.out"
if grep -q 'PRIVATE-KEY-MUST-NOT-APPEAR\|password-file' "$TMP/openvpn.out"; then
  echo "OpenVPN inventory leaked secret material." >&2
  exit 1
fi
cat > "$TMP/xray.json" <<'JSON'
{"inbounds":[{"tag":"safe-inbound","protocol":"vless","listen":"127.0.0.1","port":443,"streamSettings":{"network":"ws","security":"tls"},"settings":{"clients":[{"id":"UUID-MUST-NOT-APPEAR","password":"PASSWORD-MUST-NOT-APPEAR"}]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"certificates":[{"keyFile":"/secret/private.key"}]}}}]}
JSON
XRAY_CONFIG="$TMP/xray.json" bash "$ROOT/scripts/xray-inventory.sh" > "$TMP/xray.out"
grep -q 'safe-inbound' "$TMP/xray.out"
if grep -q 'UUID-MUST-NOT-APPEAR\|PASSWORD-MUST-NOT-APPEAR\|private.key' "$TMP/xray.out"; then
  echo "Xray inventory leaked secret material." >&2
  exit 1
fi
echo "OpenVPN and Xray inventory validation passed."
