#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../modules/protocol_users.sh
. "$ROOT/modules/protocol_users.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
PU_CONFIG="$tmp_dir/xray.json"
printf '{"old":true}\n' > "$PU_CONFIG"
chmod 640 "$PU_CONFIG"
chown root:root "$PU_CONFIG"
source_file="$tmp_dir/new-config.json"
printf '{"new":true}\n' > "$source_file"
chmod 600 "$source_file"

pu_install_config "$source_file"
[[ "$(cat "$PU_CONFIG")" == '{"new":true}' ]]
[[ "$(stat -c '%U:%G:%a' "$PU_CONFIG")" == "root:root:640" ]]
declare -F pu_xray_can_read_config >/dev/null
echo "Protocol account config-permission validation passed."
