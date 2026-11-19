#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../modules/port_routing.sh
. "$ROOT_DIR/modules/port_routing.sh"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass(){ printf 'PASS: %s\n' "$*"; }

for port in 1 22 443 65535 00001; do
  pr_valid_port "$port" || fail "expected valid port: $port"
done
pass "port range accepts 1..65535"

for port in '' 0 00000 65536 99999 1a +22 -1 ' 22'; do
  if pr_valid_port "$port"; then fail "accepted invalid port: [$port]"; fi
done
pass "port range rejects invalid values"

for hostname in example.com sub-domain.example.org localhost 192.0.2.1 a; do
  pr_valid_hostname "$hostname" || fail "expected valid hostname: $hostname"
done
pass "hostname validator accepts valid DNS labels"

for hostname in '' .example.com example..com example.com. -example.com example-.com 'bad host' '_service.example.com'; do
  if pr_valid_hostname "$hostname"; then fail "accepted invalid hostname: [$hostname]"; fi
done
pass "hostname validator rejects malformed labels"

long_label="$(printf '%064d' 0 | tr '0' 'a')"
if pr_valid_hostname "$long_label.example"; then fail "accepted a DNS label longer than 63 characters"; fi
pass "hostname validator enforces DNS label length"
