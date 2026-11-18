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

printf '\nHysteria validation tests: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
