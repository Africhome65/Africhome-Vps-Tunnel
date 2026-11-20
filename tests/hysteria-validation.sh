#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The module only declares functions when sourced; no installer or system changes run.
# shellcheck source=../modules/hysteria.sh
. "$ROOT_DIR/modules/hysteria.sh"

# Hysteria supply chain is pinned to a release-commit installer and checksummed assets.
grep -Fq 'HY2_VERSION="v2.14.0"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'HY2_INSTALLER_COMMIT="c2b181e0b0e72b077e4b0b7297735af14d1f9929"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'HY2_INSTALLER_BLOB_SHA="0120aa8e9fab0974be2e4f2340b6efb15f88e361"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'fc25edff9948708cb00a4ff01f3bccde677660aca050133bb1ad46c6860362d2' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'e7c52241299fe85aba11e9d36e85d8d88ddbb5799ac0e33d272219d20e313bab' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq '50a7a9ac1ab0660ebfae0651f03faa234c7d99d0701806e10a7f5060857647ab' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'a30c618690b4aecf521c10ea2ec199aa13cff54696d3cecd5fa4502abdb2985a' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'git hash-object "$installer"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'bash "$installer" --local "$binary"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'sha256sum -c' "$ROOT_DIR/modules/hysteria.sh"

grep -Fq 'backup_dir="$(mktemp -d /var/backups/africhome-hysteria-install.XXXXXX)"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'Protected backups retained at $backup_dir.' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'getent group hysteria' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'chown root:hysteria "$HY2_CONFIG"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'chmod 0640 "$HY2_CONFIG"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'chown root:hysteria "$config_tmp"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'chmod 0640 "$config_tmp"' "$ROOT_DIR/modules/hysteria.sh"

# First-time and replacement setup must back up and restore every active file.
grep -Fq 'hy2_restore_path() {' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'hy2_restore_setup_transaction() {' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'hy2_restore_setup_transaction "$backup_dir"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'backup_dir="$(mktemp -d /var/backups/africhome-hysteria-setup.XXXXXX)"' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'files_touched=1' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'hy2_setup_rollback() {' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'systemctl is-enabled --quiet hysteria-server.service' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'systemctl is-active --quiet hysteria-server.service' "$ROOT_DIR/modules/hysteria.sh"

grep -Fq 'old_service_active=0' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'if (( old_service_active )); then' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'systemctl disable hysteria-server.service >/dev/null 2>&1 || rollback_ok=0' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'ufw_http_added=0' "$ROOT_DIR/modules/hysteria.sh"
grep -Fq 'ufw --force delete allow 80/tcp' "$ROOT_DIR/modules/hysteria.sh"

grep -Fq 'Protected backups retained at $backup_dir.' "$ROOT_DIR/modules/hysteria.sh"



pass=0
fail=0

check_valid() {
  local label="$1" fn="$2" value="$3"
  if "$fn" "$value"; then
    printf 'PASS: %s\n' "$label"
    ((pass+=1))
  else
    printf 'FAIL: %s (unexpected rejection: %s)\n' "$label" "$value" >&2
    ((fail+=1))
  fi
}

check_invalid() {
  local label="$1" fn="$2" value="$3"
  if "$fn" "$value"; then
    printf 'FAIL: %s (unexpected acceptance: %s)\n' "$label" "$value" >&2
    ((fail+=1))
  else
    printf 'PASS: %s\n' "$label"
    ((pass+=1))
  fi
}

check_valid "normal domain" hy2_valid_domain "vpn.example.com"
check_valid "uppercase domain" hy2_valid_domain "VPN.Example.COM"
check_valid "maximum-length DNS label" hy2_valid_domain "$(printf '%063d' 0 | tr '0' 'a').example"
check_invalid "single-label domain" hy2_valid_domain "localhost"
check_invalid "domain without dot" hy2_valid_domain "vpn"
check_invalid "empty DNS label" hy2_valid_domain "vpn..example.com"
check_invalid "leading dot" hy2_valid_domain ".vpn.example"
check_invalid "trailing dot" hy2_valid_domain "vpn.example."
check_invalid "label starts with hyphen" hy2_valid_domain "-vpn.example"
check_invalid "label ends with hyphen" hy2_valid_domain "vpn-.example"
check_invalid "underscore in domain" hy2_valid_domain "vpn_node.example.com"
check_invalid "label longer than 63 characters" hy2_valid_domain "$(printf '%064d' 0 | tr '0' 'a').example"
check_invalid "domain longer than 253 characters" hy2_valid_domain "$(printf '%063d' 0 | tr '0' 'a').$(printf '%063d' 0 | tr '0' 'b').$(printf '%063d' 0 | tr '0' 'c').$(printf '%063d' 0 | tr '0' 'd').$(printf '%063d' 0 | tr '0' 'e').$(printf '%063d' 0 | tr '0' 'f').example"

check_valid "single UDP port" hy2_valid_port_spec "443"
check_valid "lowest UDP port" hy2_valid_port_spec "1"
check_valid "highest UDP port" hy2_valid_port_spec "65535"
check_valid "port hopping range" hy2_valid_port_spec "20000-30000"
check_valid "range ending at 65535" hy2_valid_port_spec "65534-65535"
check_invalid "port zero" hy2_valid_port_spec "0"
check_invalid "port above 65535" hy2_valid_port_spec "65536"
check_invalid "range starts at zero" hy2_valid_port_spec "0-100"
check_invalid "descending range" hy2_valid_port_spec "30000-20000"
check_invalid "same-port range" hy2_valid_port_spec "443-443"
check_invalid "range starts at 65535" hy2_valid_port_spec "65535-65535"
check_invalid "non-numeric port" hy2_valid_port_spec "https"
check_invalid "too many digits" hy2_valid_port_spec "123456"
check_invalid "malformed range" hy2_valid_port_spec "1000-2000-3000"


# Mock socket inventory so failure and exact-port behavior are deterministic.
ah_err() { printf '[mock error] %s\\n' "$*" >&2; }
SS_MODE="free"
ss() {
  case "$SS_MODE:$*" in
    fail-udp:*lunp*) return 1 ;;
    fail-tcp:*ltn*) return 1 ;;
    udp-busy:*lunp*) printf '%s\\n' 'UNCONN 0 0 0.0.0.0:24000 0.0.0.0:*' ;;
    tcp-busy:*ltn*) printf '%s\\n' 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*' ;;
    near-port:*lunp*) printf '%s\\n' 'UNCONN 0 0 0.0.0.0:21194 0.0.0.0:*' ;;
    *) : ;;
  esac
}
check_listener_result() {
  local label="$1" expected="$2" first="${3:-1194}" last="${4:-${3:-1194}}" actual=0
  hy2_check_listener_conflicts "$first" "$last" || actual=1
  if [[ "$actual" == "$expected" ]]; then
    printf 'PASS: %s\\n' "$label"
    ((pass+=1))
  else
    printf 'FAIL: %s (expected refusal=%s, got=%s)\\n' "$label" "$expected" "$actual" >&2
    ((fail+=1))
  fi
}
SS_MODE="free"; check_listener_result "free requested ports accepted" 0
SS_MODE="fail-udp"; check_listener_result "UDP inventory failure refuses setup" 1
SS_MODE="fail-tcp"; check_listener_result "TCP inventory failure refuses setup" 1
SS_MODE="udp-busy"; check_listener_result "UDP listener in requested range blocks setup" 1 24000 24000
SS_MODE="tcp-busy"; check_listener_result "TCP port 80 listener blocks setup" 1
SS_MODE="near-port"; check_listener_result "nearby UDP port 21194 does not collide with 1194" 0
unset -f ss ah_err

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
config_file="$tmp_dir/config.yaml"
hook_file="$tmp_dir/renewal-hook.sh"
test_password="unit-test-only-not-a-real-secret"

hy2_write_config "$config_file" "24000-25000" "/tmp/hysteria-certs" "testuser" "$test_password"
grep -Fxq 'listen: :24000-25000' "$config_file" || { echo "FAIL: generated config listen range"; ((fail+=1)); }
grep -Fxq '  cert: /tmp/hysteria-certs/fullchain.pem' "$config_file" || { echo "FAIL: generated config certificate path"; ((fail+=1)); }
grep -Fxq '  key: /tmp/hysteria-certs/privkey.pem' "$config_file" || { echo "FAIL: generated config key path"; ((fail+=1)); }
grep -Fxq '    testuser: unit-test-only-not-a-real-secret' "$config_file" || { echo "FAIL: generated config auth"; ((fail+=1)); }
if grep -q 'unit-test-only-not-a-real-secret' "$ROOT_DIR"/README.md; then
  echo "FAIL: test credential leaked into README" >&2
  ((fail+=1))
else
  echo "PASS: test credential absent from README"
  ((pass+=1))
fi

hy2_write_renewal_hook "$hook_file" "vpn.example.com" || { echo "FAIL: renewal hook generation"; exit 1; }
bash -n "$hook_file" || { echo "FAIL: generated renewal hook syntax"; ((fail+=1)); }
grep -Fxq 'DOMAIN="vpn.example.com"' "$hook_file" || { echo "FAIL: renewal hook domain"; ((fail+=1)); }
grep -Fq 'install -o hysteria -g hysteria -m 640' "$hook_file" || { echo "FAIL: renewal hook certificate permissions"; ((fail+=1)); }
grep -Fq 'mv -f -- "$tmp_cert" "$DEST/fullchain.pem"' "$hook_file" || { echo "FAIL: renewal hook atomic certificate replacement"; ((fail+=1)); }
grep -Fq 'mv -f -- "$tmp_key" "$DEST/privkey.pem"' "$hook_file" || { echo "FAIL: renewal hook atomic key replacement"; ((fail+=1)); }
grep -Fq 'openssl x509 -in "$tmp_cert" -noout' "$hook_file" || { echo "FAIL: renewal hook certificate validation"; ((fail+=1)); }
grep -Fq 'openssl pkey -in "$tmp_key" -noout' "$hook_file" || { echo "FAIL: renewal hook private-key validation"; ((fail+=1)); }
grep -Fq 'cert_pub" == "$key_pub' "$hook_file" || { echo "FAIL: renewal hook certificate/key matching"; ((fail+=1)); }
grep -Fq 'pair_touched=1' "$hook_file" || { echo "FAIL: renewal hook rollback activation"; ((fail+=1)); }
grep -Fq 'trap rollback EXIT' "$hook_file" || { echo "FAIL: renewal hook rollback trap"; ((fail+=1)); }
grep -Fq 'systemctl restart hysteria-server.service' "$hook_file" || { echo "FAIL: renewal hook service restart"; ((fail+=1)); }
if [[ -x "$hook_file" ]]; then
  echo "PASS: renewal hook is executable"
  ((pass+=1))
else
  echo "FAIL: renewal hook is not executable" >&2
  ((fail+=1))
fi

# Exercise the shared rollback helper, including a forced restore-rename failure.
restore_dir="$tmp_dir/restore"
mkdir -p "$restore_dir"
printf 'previous-content\n' > "$restore_dir/backup"
printf 'new-content\n' > "$restore_dir/target"
hy2_restore_path "$restore_dir/backup" "$restore_dir/target" 1
[[ "$(cat "$restore_dir/target")" == "previous-content" ]] || { echo "FAIL: restore helper did not restore previous content"; ((fail+=1)); }
hy2_restore_path "" "$restore_dir/target" 0
[[ ! -e "$restore_dir/target" ]] || { echo "FAIL: restore helper did not remove newly created file"; ((fail+=1)); }
printf 'protected-backup\n' > "$restore_dir/backup"
printf 'partially-applied\n' > "$restore_dir/target"
mv() { return 1; }
if hy2_restore_path "$restore_dir/backup" "$restore_dir/target" 1; then
  echo "FAIL: restore helper ignored injected rename failure" >&2
  ((fail+=1))
elif [[ "$(cat "$restore_dir/backup")" == "protected-backup" ]]; then
  echo "PASS: failed restore leaves protected backup intact"
  ((pass+=1))
else
  echo "FAIL: protected backup was lost after injected restore failure" >&2
  ((fail+=1))
fi
unset -f mv

# Exercise full Hysteria setup restoration with mocked systemd state.
setup_backup="$tmp_dir/setup-backup"
setup_live="$tmp_dir/setup-live"
mkdir -p "$setup_backup" "$setup_live/certs" "$setup_live/hooks"
printf 'previous-config\n' > "$setup_backup/config.yaml"
printf 'previous-cert\n' > "$setup_backup/fullchain.pem"
printf 'previous-key\n' > "$setup_backup/privkey.pem"
printf 'previous-hook\n' > "$setup_backup/renewal-hook.sh"
printf 'previous-state\n' > "$setup_backup/state.env"
printf 'new-config\n' > "$setup_live/config.yaml"
printf 'new-cert\n' > "$setup_live/certs/fullchain.pem"
printf 'new-key\n' > "$setup_live/certs/privkey.pem"
printf 'new-hook\n' > "$setup_live/hooks/renewal-hook.sh"
printf 'new-state\n' > "$setup_live/state.env"
systemctl() {
  printf '%s\n' "$*" >> "$tmp_dir/systemctl.log"
  return 0
}
if hy2_restore_setup_transaction "$setup_backup" "$setup_live/config.yaml" "$setup_live/certs/fullchain.pem" "$setup_live/certs/privkey.pem" "$setup_live/hooks/renewal-hook.sh" "$setup_live/state.env" 1 1 1 1 1 1 1 &&
   [[ "$(cat "$setup_live/config.yaml")" == "previous-config" ]] &&
   [[ "$(cat "$setup_live/certs/fullchain.pem")" == "previous-cert" ]] &&
   [[ "$(cat "$setup_live/certs/privkey.pem")" == "previous-key" ]] &&
   [[ "$(cat "$setup_live/hooks/renewal-hook.sh")" == "previous-hook" ]] &&
   [[ "$(cat "$setup_live/state.env")" == "previous-state" ]] &&
   grep -q '^enable hysteria-server.service
renew_src="$tmp_dir/letsencrypt/vpn.example.com"
renew_dest="$tmp_dir/hysteria-certs"
mkdir -p "$renew_src" "$renew_dest"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$renew_src/privkey.pem" -out "$renew_src/fullchain.pem" -subj "/CN=vpn.example.com" -days 1 >/dev/null 2>&1
hook_runtime="$tmp_dir/renewal-runtime.sh"
sed -e "s|^SRC=.*|SRC=\"$renew_src\"|" \
    -e "s|^DEST=.*|DEST=\"$renew_dest\"|" \
    -e 's/install -d -o hysteria -g hysteria -m 750/install -d -m 750/' \
    -e 's/install -o hysteria -g hysteria -m 640/install -m 640/' \
    -e 's/systemctl restart hysteria-server.service/:/' \
    "$hook_file" > "$hook_runtime"
chmod 0750 "$hook_runtime"
printf 'old-cert\n' > "$renew_dest/fullchain.pem"
printf 'old-key\n' > "$renew_dest/privkey.pem"
bash "$hook_runtime" || { echo "FAIL: renewal hook successful apply"; ((fail+=1)); }
if cmp -s "$renew_src/fullchain.pem" "$renew_dest/fullchain.pem" && cmp -s "$renew_src/privkey.pem" "$renew_dest/privkey.pem"; then
  echo "PASS: renewal hook applies a matching certificate/key pair"
  ((pass+=1))
else
  echo "FAIL: renewal hook did not apply the matching certificate/key pair" >&2
  ((fail+=1))
fi

# Force the second file replacement to fail after the certificate has moved.
printf 'previous-cert\n' > "$renew_dest/fullchain.pem"
printf 'previous-key\n' > "$renew_dest/privkey.pem"
hook_fail="$tmp_dir/renewal-forced-failure.sh"
sed 's|mv -f -- "$tmp_key" "$DEST/privkey.pem"|false|' "$hook_runtime" > "$hook_fail"
chmod 0750 "$hook_fail"
if bash "$hook_fail"; then
  echo "FAIL: injected key replacement failure unexpectedly succeeded" >&2
  ((fail+=1))
elif [[ "$(cat "$renew_dest/fullchain.pem")" == "previous-cert" && "$(cat "$renew_dest/privkey.pem")" == "previous-key" ]]; then
  echo "PASS: renewal hook restores the previous pair after injected second-file failure"
  ((pass+=1))
else
  echo "FAIL: renewal hook did not restore the previous pair after injected failure" >&2
  ((fail+=1))
fi

printf '\nHysteria validation tests: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
 "$tmp_dir/systemctl.log" &&
   grep -q '^restart hysteria-server.service
renew_src="$tmp_dir/letsencrypt/vpn.example.com"
renew_dest="$tmp_dir/hysteria-certs"
mkdir -p "$renew_src" "$renew_dest"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$renew_src/privkey.pem" -out "$renew_src/fullchain.pem" -subj "/CN=vpn.example.com" -days 1 >/dev/null 2>&1
hook_runtime="$tmp_dir/renewal-runtime.sh"
sed -e "s|^SRC=.*|SRC=\"$renew_src\"|" \
    -e "s|^DEST=.*|DEST=\"$renew_dest\"|" \
    -e 's/install -d -o hysteria -g hysteria -m 750/install -d -m 750/' \
    -e 's/install -o hysteria -g hysteria -m 640/install -m 640/' \
    -e 's/systemctl restart hysteria-server.service/:/' \
    "$hook_file" > "$hook_runtime"
chmod 0750 "$hook_runtime"
printf 'old-cert\n' > "$renew_dest/fullchain.pem"
printf 'old-key\n' > "$renew_dest/privkey.pem"
bash "$hook_runtime" || { echo "FAIL: renewal hook successful apply"; ((fail+=1)); }
if cmp -s "$renew_src/fullchain.pem" "$renew_dest/fullchain.pem" && cmp -s "$renew_src/privkey.pem" "$renew_dest/privkey.pem"; then
  echo "PASS: renewal hook applies a matching certificate/key pair"
  ((pass+=1))
else
  echo "FAIL: renewal hook did not apply the matching certificate/key pair" >&2
  ((fail+=1))
fi

# Force the second file replacement to fail after the certificate has moved.
printf 'previous-cert\n' > "$renew_dest/fullchain.pem"
printf 'previous-key\n' > "$renew_dest/privkey.pem"
hook_fail="$tmp_dir/renewal-forced-failure.sh"
sed 's|mv -f -- "$tmp_key" "$DEST/privkey.pem"|false|' "$hook_runtime" > "$hook_fail"
chmod 0750 "$hook_fail"
if bash "$hook_fail"; then
  echo "FAIL: injected key replacement failure unexpectedly succeeded" >&2
  ((fail+=1))
elif [[ "$(cat "$renew_dest/fullchain.pem")" == "previous-cert" && "$(cat "$renew_dest/privkey.pem")" == "previous-key" ]]; then
  echo "PASS: renewal hook restores the previous pair after injected second-file failure"
  ((pass+=1))
else
  echo "FAIL: renewal hook did not restore the previous pair after injected failure" >&2
  ((fail+=1))
fi

printf '\nHysteria validation tests: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
 "$tmp_dir/systemctl.log"; then
  echo "PASS: Hysteria setup rollback restores all files and prior enabled/active service state"
  ((pass+=1))
else
  echo "FAIL: Hysteria setup rollback did not restore files/service state" >&2
  ((fail+=1))
fi
unset -f systemctl

# A failed setup restore must return failure and leave the backup directory intact.
setup_backup_fail="$tmp_dir/setup-backup-fail"
setup_live_fail="$tmp_dir/setup-live-fail"
mkdir -p "$setup_backup_fail" "$setup_live_fail/certs" "$setup_live_fail/hooks"
printf 'protected-config\n' > "$setup_backup_fail/config.yaml"
printf 'partial-config\n' > "$setup_live_fail/config.yaml"
printf 'protected-cert\n' > "$setup_backup_fail/fullchain.pem"
printf 'partial-cert\n' > "$setup_live_fail/certs/fullchain.pem"
printf 'protected-key\n' > "$setup_backup_fail/privkey.pem"
printf 'partial-key\n' > "$setup_live_fail/certs/privkey.pem"
printf 'protected-hook\n' > "$setup_backup_fail/renewal-hook.sh"
printf 'partial-hook\n' > "$setup_live_fail/hooks/renewal-hook.sh"
printf 'protected-state\n' > "$setup_backup_fail/state.env"
printf 'partial-state\n' > "$setup_live_fail/state.env"
systemctl() { return 0; }
mv() {
  if [[ "${1:-}" == "-f" && "${2:-}" == "--" && "${4:-}" == "$setup_live_fail/config.yaml" ]]; then
    return 1
  fi
  command mv "$@"
}
if hy2_restore_setup_transaction "$setup_backup_fail" "$setup_live_fail/config.yaml" "$setup_live_fail/certs/fullchain.pem" "$setup_live_fail/certs/privkey.pem" "$setup_live_fail/hooks/renewal-hook.sh" "$setup_live_fail/state.env" 1 1 1 1 1 1 1; then
  echo "FAIL: injected Hysteria setup restore failure unexpectedly succeeded" >&2
  ((fail+=1))
elif [[ "$(cat "$setup_backup_fail/config.yaml")" == "protected-config" ]]; then
  echo "PASS: failed Hysteria setup rollback preserves protected backups"
  ((pass+=1))
else
  echo "FAIL: Hysteria setup rollback lost its protected backup" >&2
  ((fail+=1))
fi
unset -f mv
unset -f systemctl

# Exercise the pinned Hysteria installer rollback across binary, units and config.
install_backup="$tmp_dir/hy2-install-backup"
install_live="$tmp_dir/hy2-install-live"
mkdir -p "$install_backup" "$install_live"
printf 'old-binary\n' > "$install_backup/hysteria"
printf 'old-unit\n' > "$install_backup/hysteria-server.service"
printf 'old-template\n' > "$install_backup/hysteria-server@.service"
printf 'old-config\n' > "$install_backup/config.yaml"
printf 'new-binary\n' > "$install_live/hysteria"
printf 'new-unit\n' > "$install_live/hysteria-server.service"
printf 'new-template\n' > "$install_live/hysteria-server@.service"
printf 'new-config\n' > "$install_live/config.yaml"
systemctl() {
  printf '%s\n' "$*" >> "$tmp_dir/hy2-install-systemctl.log"
  return 0
}
if hy2_restore_install_transaction "$install_backup" "$install_live/hysteria" "$install_live/hysteria-server.service" "$install_live/hysteria-server@.service" "$install_live/config.yaml" 1 1 1 1 1 &&
   [[ "$(cat "$install_live/hysteria")" == "old-binary" ]] &&
   [[ "$(cat "$install_live/hysteria-server.service")" == "old-unit" ]] &&
   [[ "$(cat "$install_live/hysteria-server@.service")" == "old-template" ]] &&
   [[ "$(cat "$install_live/config.yaml")" == "old-config" ]] &&
   grep -q '^restart hysteria-server.service
renew_src="$tmp_dir/letsencrypt/vpn.example.com"
renew_dest="$tmp_dir/hysteria-certs"
mkdir -p "$renew_src" "$renew_dest"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$renew_src/privkey.pem" -out "$renew_src/fullchain.pem" -subj "/CN=vpn.example.com" -days 1 >/dev/null 2>&1
hook_runtime="$tmp_dir/renewal-runtime.sh"
sed -e "s|^SRC=.*|SRC=\"$renew_src\"|" \
    -e "s|^DEST=.*|DEST=\"$renew_dest\"|" \
    -e 's/install -d -o hysteria -g hysteria -m 750/install -d -m 750/' \
    -e 's/install -o hysteria -g hysteria -m 640/install -m 640/' \
    -e 's/systemctl restart hysteria-server.service/:/' \
    "$hook_file" > "$hook_runtime"
chmod 0750 "$hook_runtime"
printf 'old-cert\n' > "$renew_dest/fullchain.pem"
printf 'old-key\n' > "$renew_dest/privkey.pem"
bash "$hook_runtime" || { echo "FAIL: renewal hook successful apply"; ((fail+=1)); }
if cmp -s "$renew_src/fullchain.pem" "$renew_dest/fullchain.pem" && cmp -s "$renew_src/privkey.pem" "$renew_dest/privkey.pem"; then
  echo "PASS: renewal hook applies a matching certificate/key pair"
  ((pass+=1))
else
  echo "FAIL: renewal hook did not apply the matching certificate/key pair" >&2
  ((fail+=1))
fi

# Force the second file replacement to fail after the certificate has moved.
printf 'previous-cert\n' > "$renew_dest/fullchain.pem"
printf 'previous-key\n' > "$renew_dest/privkey.pem"
hook_fail="$tmp_dir/renewal-forced-failure.sh"
sed 's|mv -f -- "$tmp_key" "$DEST/privkey.pem"|false|' "$hook_runtime" > "$hook_fail"
chmod 0750 "$hook_fail"
if bash "$hook_fail"; then
  echo "FAIL: injected key replacement failure unexpectedly succeeded" >&2
  ((fail+=1))
elif [[ "$(cat "$renew_dest/fullchain.pem")" == "previous-cert" && "$(cat "$renew_dest/privkey.pem")" == "previous-key" ]]; then
  echo "PASS: renewal hook restores the previous pair after injected second-file failure"
  ((pass+=1))
else
  echo "FAIL: renewal hook did not restore the previous pair after injected failure" >&2
  ((fail+=1))
fi

printf '\nHysteria validation tests: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
 "$tmp_dir/hy2-install-systemctl.log"; then
  echo "PASS: Hysteria installer rollback restores binary, units, config and active service"
  ((pass+=1))
else
  echo "FAIL: Hysteria installer rollback did not restore all previous files" >&2
  ((fail+=1))
fi
unset -f systemctl

# An injected installer rollback rename failure must return failure and retain its backup.
install_backup_fail="$tmp_dir/hy2-install-backup-fail"
install_live_fail="$tmp_dir/hy2-install-live-fail"
mkdir -p "$install_backup_fail" "$install_live_fail"
printf 'protected-binary\n' > "$install_backup_fail/hysteria"
printf 'partial-binary\n' > "$install_live_fail/hysteria"
printf 'protected-unit\n' > "$install_backup_fail/hysteria-server.service"
printf 'partial-unit\n' > "$install_live_fail/hysteria-server.service"
printf 'protected-template\n' > "$install_backup_fail/hysteria-server@.service"
printf 'partial-template\n' > "$install_live_fail/hysteria-server@.service"
printf 'protected-config\n' > "$install_backup_fail/config.yaml"
printf 'partial-config\n' > "$install_live_fail/config.yaml"
systemctl() { return 0; }
mv() {
  if [[ "${1:-}" == "-f" && "${2:-}" == "--" && "${4:-}" == "$install_live_fail/hysteria" ]]; then
    return 1
  fi
  command mv "$@"
}
if hy2_restore_install_transaction "$install_backup_fail" "$install_live_fail/hysteria" "$install_live_fail/hysteria-server.service" "$install_live_fail/hysteria-server@.service" "$install_live_fail/config.yaml" 1 1 1 1 0; then
  echo "FAIL: injected Hysteria installer rollback failure unexpectedly succeeded" >&2
  ((fail+=1))
elif [[ "$(cat "$install_backup_fail/hysteria")" == "protected-binary" ]]; then
  echo "PASS: failed Hysteria installer rollback leaves protected backup intact"
  ((pass+=1))
else
  echo "FAIL: Hysteria installer rollback lost its protected binary backup" >&2
  ((fail+=1))
fi
unset -f mv
unset -f systemctl

# Run the generated renewal hook against temporary paths with a real cert/key.
renew_src="$tmp_dir/letsencrypt/vpn.example.com"
renew_dest="$tmp_dir/hysteria-certs"
mkdir -p "$renew_src" "$renew_dest"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$renew_src/privkey.pem" -out "$renew_src/fullchain.pem" -subj "/CN=vpn.example.com" -days 1 >/dev/null 2>&1
hook_runtime="$tmp_dir/renewal-runtime.sh"
sed -e "s|^SRC=.*|SRC=\"$renew_src\"|" \
    -e "s|^DEST=.*|DEST=\"$renew_dest\"|" \
    -e 's/install -d -o hysteria -g hysteria -m 750/install -d -m 750/' \
    -e 's/install -o hysteria -g hysteria -m 640/install -m 640/' \
    -e 's/systemctl restart hysteria-server.service/:/' \
    "$hook_file" > "$hook_runtime"
chmod 0750 "$hook_runtime"
printf 'old-cert\n' > "$renew_dest/fullchain.pem"
printf 'old-key\n' > "$renew_dest/privkey.pem"
bash "$hook_runtime" || { echo "FAIL: renewal hook successful apply"; ((fail+=1)); }
if cmp -s "$renew_src/fullchain.pem" "$renew_dest/fullchain.pem" && cmp -s "$renew_src/privkey.pem" "$renew_dest/privkey.pem"; then
  echo "PASS: renewal hook applies a matching certificate/key pair"
  ((pass+=1))
else
  echo "FAIL: renewal hook did not apply the matching certificate/key pair" >&2
  ((fail+=1))
fi

# Force the second file replacement to fail after the certificate has moved.
printf 'previous-cert\n' > "$renew_dest/fullchain.pem"
printf 'previous-key\n' > "$renew_dest/privkey.pem"
hook_fail="$tmp_dir/renewal-forced-failure.sh"
sed 's|mv -f -- "$tmp_key" "$DEST/privkey.pem"|false|' "$hook_runtime" > "$hook_fail"
chmod 0750 "$hook_fail"
if bash "$hook_fail"; then
  echo "FAIL: injected key replacement failure unexpectedly succeeded" >&2
  ((fail+=1))
elif [[ "$(cat "$renew_dest/fullchain.pem")" == "previous-cert" && "$(cat "$renew_dest/privkey.pem")" == "previous-key" ]]; then
  echo "PASS: renewal hook restores the previous pair after injected second-file failure"
  ((pass+=1))
else
  echo "FAIL: renewal hook did not restore the previous pair after injected failure" >&2
  ((fail+=1))
fi

printf '\nHysteria validation tests: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
