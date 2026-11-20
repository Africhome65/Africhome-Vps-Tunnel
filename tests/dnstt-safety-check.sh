#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for file in \
  "$ROOT_DIR/scripts/install-dnstt.sh" \
  "$ROOT_DIR/scripts/configure-dnstt-domain.sh" \
  "$ROOT_DIR/scripts/install-dnstt-service.sh"; do
  [[ -f "$file" ]] || { echo "Missing DNSTT script: $file" >&2; exit 1; }
  bash -n "$file"
done

grep -q 'trap cleanup EXIT' "$ROOT_DIR/scripts/configure-dnstt-domain.sh"
grep -Fq '$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S).$$' "$ROOT_DIR/scripts/configure-dnstt-domain.sh"
grep -Fq 'mv -f -- "$tmp" "$CONFIG_FILE"' "$ROOT_DIR/scripts/configure-dnstt-domain.sh"
# The public repository must never ship the maintainer's personal DNS names.
if grep -R -n -E 'smarty\.uk\.afriko2\.co\.uk|ns-smarty\.uk\.afriko2\.co\.uk' "$ROOT_DIR/scripts"; then
  echo "A maintainer-specific DNS name was found in an install script." >&2
  exit 1
fi

SERVICE="$ROOT_DIR/scripts/install-dnstt-service.sh"
grep -q 'EnvironmentFile=/etc/africhome-dnstt/server.env' "$SERVICE"
grep -q 'EnvironmentFile=/etc/africhome-dnstt/service.env' "$SERVICE"
grep -q 'systemctl daemon-reload' "$SERVICE"
grep -q 'root-owned directory with mode 0700' "$SERVICE"
grep -q 'private key must be a root-owned regular file with mode 0600' "$SERVICE"
grep -q 'public key must be a root-owned regular file with mode 0644' "$SERVICE"
grep -q 'refusing to replace an unsafe path' "$SERVICE"
grep -q 'trap cleanup EXIT' "$SERVICE"
grep -Fq 'chown root:root "$unit_tmp"' "$SERVICE"
grep -Fq 'chmod 0644 "$unit_tmp"' "$SERVICE"
grep -Fq '$(date +%Y%m%d%H%M%S).$' "$SERVICE"
grep -Fq 'service_config_changed=1' "$SERVICE"
grep -Fq 'unit_changed=1' "$SERVICE"
grep -Fq 'cp -a -- "$service_config_backup" "$SERVICE_CONFIG"' "$SERVICE"
grep -Fq 'cp -a -- "$unit_backup" "$UNIT_FILE"' "$SERVICE"
grep -Fq 'mktemp "/etc/systemd/system/.africhome-dnstt.service.XXXXXX"' "$SERVICE"
grep -Fq 'mv -f -- "$unit_tmp" "$UNIT_FILE"' "$SERVICE"

# Exercise the same address validators used by the service configurator.
VALIDATORS="$(sed -n '/^valid_ipv4() {/,/^}/p; /^valid_upstream_host() {/,/^}/p' "$SERVICE")"
[[ -n "$VALIDATORS" ]] || { echo "DNSTT address validators are missing." >&2; exit 1; }
bash -c "$VALIDATORS
valid_ipv4 '127.0.0.1'
valid_ipv4 '255.255.255.255'
if valid_ipv4 '256.1.1.1' || valid_ipv4 '999.0.0.1' || valid_ipv4 '127.0.0'; then
  echo 'Invalid IPv4 address was accepted.' >&2
  exit 1
fi
valid_upstream_host 'localhost'
valid_upstream_host 'ssh.example.net'
valid_upstream_host '127.0.0.1'
if valid_upstream_host '999.1.1.1' || valid_upstream_host 'bad..host' || valid_upstream_host '-bad.example'; then
  echo 'Invalid SSH upstream host was accepted.' >&2
  exit 1
fi
"
grep -q 'root-owned regular file with mode 0600' "$ROOT_DIR/scripts/configure-dnstt-domain.sh"
grep -q 'must be a real directory, not a symlink' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -q 'bash "$SCRIPT_DIR/scripts/license.sh" verify' "$ROOT_DIR/scripts/install-dnstt.sh"

# The bootstrap must fetch the fixed upstream release commit, never moving master.
grep -Fq 'DNSTT_TAG="v1.20260501.0"' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq 'DNSTT_TAG_OBJECT="8fb3b30e6dbdc9006780327c6687623534d134f5"' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq '[[ "$fetched_tag_object" == "$DNSTT_TAG_OBJECT" ]]' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq 'DNSTT_COMMIT="0c5c52a57d899c05428c116898941761a2ed83c2"' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq 'git -C "$src_stage" fetch --depth=1 origin "refs/tags/$DNSTT_TAG:refs/tags/$DNSTT_TAG"' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq '[[ "$fetched_commit" == "$DNSTT_COMMIT" ]]' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq '[[ ! -L "$DNSTT_SRC" ]]' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq '[[ ! -L "$DNSTT_SRC/.git" ]]' "$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq 'git -C "$DNSTT_SRC" status --porcelain --untracked-files=all' "$ROOT_DIR/scripts/install-dnstt.sh"
if grep -Fq 'git clone "$DNSTT_REPO"' "$ROOT_DIR/scripts/install-dnstt.sh"; then
  echo "DNSTT bootstrap must not clone the moving upstream branch." >&2
  exit 1
fi

license_line="$(grep -n 'bash "$SCRIPT_DIR/scripts/license.sh" verify' "$ROOT_DIR/scripts/install-dnstt.sh" | cut -d: -f1)"
apt_line="$(grep -n '^apt-get update' "$ROOT_DIR/scripts/install-dnstt.sh" | cut -d: -f1)"
[[ -n "$license_line" && -n "$apt_line" && "$license_line" -lt "$apt_line" ]] || { echo "DNSTT installer must verify licence before apt changes." >&2; exit 1; }

# Preparing the unit must not stop iodine or activate DNSTT automatically.
if grep -E -q '^[[:space:]]*systemctl[[:space:]]+(stop|disable|enable|start|restart)[[:space:]]' "$SERVICE"; then
  echo "DNSTT preparation script must not change running services." >&2
  exit 1
fi


# Installer replacement must have explicit rollback paths for the Go toolchain
# and for both DNSTT binaries. These assertions prevent accidental regression
# to one-way mv/install operations.
INSTALLER="$ROOT_DIR/scripts/install-dnstt.sh"
grep -Fq 'go_backup="/usr/local/go.africhome-backup.$(date +%s%N)"' "$INSTALLER"
grep -Fq 'previous toolchain could not be restored' "$INSTALLER"
grep -Fq 'Staged Go toolchain failed its version check; previous toolchain restored.' "$INSTALLER"
grep -Fq 'server_existed=0' "$INSTALLER"
grep -Fq 'client_existed=0' "$INSTALLER"
grep -Fq 'previous server/client pair restored.' "$INSTALLER"
grep -Fq 'server_new="$(mktemp /usr/local/bin/.dnstt-server.new.XXXXXX)"' "$INSTALLER"
grep -Fq 'client_new="$(mktemp /usr/local/bin/.dnstt-client.new.XXXXXX)"' "$INSTALLER"

grep -Fq 'bin_backup="$(mktemp -d /usr/local/bin/.africhome-dnstt-backup.XXXXXX)"' "$INSTALLER"
grep -Fq 'preserve_bin_backup=1' "$INSTALLER"
grep -Fq 'Protected backups retained at $bin_backup.' "$INSTALLER"
grep -Fq 'restore_binary() {' "$INSTALLER"
grep -Fq 'restore_tmp="$(mktemp "${destination}.restore.XXXXXX")"' "$INSTALLER"

grep -Fq 'Existing dnstt-server is not a regular non-symlink file.' "$INSTALLER"
grep -Fq 'Existing dnstt-client is not a regular non-symlink file.' "$INSTALLER"

echo "DNSTT repository safety checks passed."
