#!/usr/bin/env bash
# Read-only Xray inbound inventory for central-router migration planning.
# Never prints credentials, UUIDs, passwords, private keys, or certificate paths.
set -Eeuo pipefail

CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"

fail(){ printf '[ERROR] %s\n' "$*" >&2; return 1; }

xray_inventory() {
  command -v jq >/dev/null 2>&1 || { fail "jq is required."; return 1; }
  [[ -r "$CONFIG" ]] || { fail "Xray config is not readable: $CONFIG"; return 1; }
  jq -e 'type == "object" and ((.inbounds // []) | type == "array")' "$CONFIG" >/dev/null \
    || { fail "Xray config is invalid or has no inbound array."; return 1; }

  printf 'Xray config: %s\n' "$CONFIG"
  printf '%-24s %-14s %-18s %-8s %-12s %-12s\n' "TAG" "PROTOCOL" "LISTEN" "PORT" "NETWORK" "SECURITY"
  jq -r '
    .inbounds[]? |
    [
      (.tag // "(untagged)"),
      (.protocol // "unknown"),
      (.listen // "0.0.0.0"),
      ((.port // 0) | tostring),
      (.streamSettings.network // "raw"),
      (.streamSettings.security // "none")
    ] | @tsv
  ' "$CONFIG" | while IFS=$'\t' read -r tag protocol listen port network security; do
    printf '%-24.24s %-14.14s %-18.18s %-8.8s %-12.12s %-12.12s\n' \
      "$tag" "$protocol" "$listen" "$port" "$network" "$security"
  done

  printf '\nSafety notes:\n'
  printf '%s\n' '- This report is read-only and deliberately omits credentials and TLS key paths.'
  printf '%s\n' '- 0.0.0.0, ::, or an empty listen address may conflict with a shared frontend.'
  printf '%s\n' '- Do not change inbound listeners until a complete backup and route review is approved.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  xray_inventory "$@"
fi
