#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../modules/security.sh
. "$ROOT/modules/security.sh"

sshd(){
  [[ "${1:-}" == "-T" ]] || return 1
  printf '%s\n' 'port 2222' 'port 443' 'permitrootlogin prohibit-password'
}
ports="$(security_detect_ssh_ports)"
[[ "$ports" == "2222,443" ]] || { echo "Unexpected SSH port detection: $ports" >&2; exit 1; }
security_valid_ip "192.0.2.10"\nsecurity_valid_ip "2001:db8::10"\nif security_valid_ip "999.1.1.1"; then echo "Invalid IPv4 was accepted" >&2; exit 1; fi\nif security_valid_ip "not-an-ip"; then echo "Invalid address was accepted" >&2; exit 1; fi\n
security_torrent_rules > "${TMPDIR:-/tmp}/africhome-torrent-test.$$.nft"
trap 'rm -f "${TMPDIR:-/tmp}/africhome-torrent-test.$$.nft"' EXIT
grep -Fq 'add table inet africhome_torrent' "${TMPDIR:-/tmp}/africhome-torrent-test.$$.nft"
grep -Fq 'input tcp dport { 6881-6999, 51413 } drop' "${TMPDIR:-/tmp}/africhome-torrent-test.$$.nft"
grep -Fq 'output udp dport { 6881-6999, 51413 } drop' "${TMPDIR:-/tmp}/africhome-torrent-test.$$.nft"
! grep -Eq 'flush ruleset|delete table|hook forward|10000-45000|1-65535' "${TMPDIR:-/tmp}/africhome-torrent-test.$$.nft"
if grep -Fq 'nft delete table inet africhome_torrent' "$ROOT/modules/security.sh"; then
  # Deletion is permitted only in the explicit opt-in disable handler.
  [[ "$(grep -Fc 'nft delete table inet africhome_torrent' "$ROOT/modules/security.sh")" -eq 1 ]]
fi
echo "Security module validation passed."
