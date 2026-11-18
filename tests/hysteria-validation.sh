#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# The module only declares functions when sourced; no installer or system changes run.
# shellcheck source=../modules/hysteria.sh
. "$ROOT_DIR/modules/hysteria.sh"

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

hy2_write_renewal_hook "$hook_file" "vpn.example.com"
bash -n "$hook_file" || { echo "FAIL: generated renewal hook syntax"; ((fail+=1)); }
grep -Fxq 'DOMAIN="vpn.example.com"' "$hook_file" || { echo "FAIL: renewal hook domain"; ((fail+=1)); }
grep -Fq 'install -o hysteria -g hysteria -m 640' "$hook_file" || { echo "FAIL: renewal hook certificate permissions"; ((fail+=1)); }
grep -Fq 'mv -f "$tmp_cert" "$DEST/fullchain.pem"' "$hook_file" || { echo "FAIL: renewal hook atomic certificate replacement"; ((fail+=1)); }
grep -Fq 'mv -f "$tmp_key" "$DEST/privkey.pem"' "$hook_file" || { echo "FAIL: renewal hook atomic key replacement"; ((fail+=1)); }
grep -Fq 'systemctl restart hysteria-server.service' "$hook_file" || { echo "FAIL: renewal hook service restart"; ((fail+=1)); }
if [[ -x "$hook_file" ]]; then
  echo "PASS: renewal hook is executable"
  ((pass+=1))
else
  echo "FAIL: renewal hook is not executable" >&2
  ((fail+=1))
fi

printf '\nHysteria validation tests: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
