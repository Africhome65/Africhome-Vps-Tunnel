#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ah_warn() { :; }
ah_err() { :; }
ah_info() { :; }
ah_ok() { :; }
# Load only the DNSTT module's pure validation functions.
# shellcheck source=../modules/dnstt.sh
. "$ROOT_DIR/modules/dnstt.sh"

passed=0
failed=0

expect_true() {
  local description="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$description"
    ((passed += 1))
  else
    printf 'FAIL: %s\n' "$description" >&2
    ((failed += 1))
  fi
}

expect_false() {
  local description="$1"
  shift
  if "$@"; then
    printf 'FAIL: %s\n' "$description" >&2
    ((failed += 1))
  else
    printf 'PASS: %s\n' "$description"
    ((passed += 1))
  fi
}

expect_true "accepts a delegated tunnel zone" ah_dnstt_valid_domain t.example.com
expect_true "accepts a multi-label public domain" ah_dnstt_valid_domain ns1.example.co.uk
expect_false "rejects an empty domain" ah_dnstt_valid_domain ""
expect_false "rejects consecutive dots" ah_dnstt_valid_domain bad..example.com
expect_false "rejects a leading hyphen" ah_dnstt_valid_domain -bad.example.com
expect_false "rejects shell metacharacters in a domain" ah_dnstt_valid_domain 't.example.com;id'

expect_true "accepts Google UDP DNS" ah_dnstt_valid_resolver udp 8.8.8.8:53
expect_true "accepts bracketed IPv6 UDP DNS" ah_dnstt_valid_resolver udp '[2001:4860:4860::8888]:53'
expect_true "accepts a DoT hostname and port" ah_dnstt_valid_resolver dot dns.google:853
expect_true "accepts an HTTPS DoH endpoint" ah_dnstt_valid_resolver doh https://dns.google/dns-query
expect_false "rejects an unsupported transport" ah_dnstt_valid_resolver tcp 8.8.8.8:53
expect_false "rejects port zero" ah_dnstt_valid_resolver udp 8.8.8.8:0
expect_false "rejects ports above 65535" ah_dnstt_valid_resolver udp 8.8.8.8:65536
expect_true "parses leading-zero ports as decimal" ah_dnstt_valid_resolver udp 8.8.8.8:00053
expect_false "rejects a non-HTTPS DoH endpoint" ah_dnstt_valid_resolver doh http://dns.google/dns-query

printf '\nDNSTT validation tests: %d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
