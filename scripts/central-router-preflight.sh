#!/usr/bin/env bash
# Read-only preflight for a generated Africhome HAProxy candidate.
# This script never installs, replaces, starts, reloads, or stops services.
set -Eeuo pipefail

fail(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }

[[ "$EUID" -eq 0 ]] || fail "Run this read-only preflight as root so socket ownership can be inspected."
(( $# <= 1 )) || fail "Usage: $0 [candidate-config]"
candidate="${1:-/root/africhome-haproxy-candidate.cfg}"

[[ -f "$candidate" && ! -L "$candidate" ]] || fail "Candidate must be an existing regular file, not a symlink."
[[ "$(stat -c '%u:%a' -- "$candidate" 2>/dev/null)" == "0:600" ]] || fail "Candidate must be root-owned with mode 0600."
command -v haproxy >/dev/null 2>&1 || fail "HAProxy is not installed; candidate parser validation is unavailable."
command -v ss >/dev/null 2>&1 || fail "The ss command is required for listener inspection."

info "Validating candidate syntax without changing the system."
haproxy -c -f "$candidate" || fail "HAProxy rejected the candidate configuration."

info "Inspecting current TCP listeners on ports 80 and 443."
listeners="$(ss -H -ltnp)" || fail "Could not read TCP listener inventory."
occupied="$(awk '$4 ~ /:80$/ || $4 ~ /:443$/ {print}' <<< "$listeners")"
if [[ -n "$occupied" ]]; then
  printf '%s\n' "$occupied"
  warn "At least one target port is already occupied. Do not apply this candidate; identify and design a compatible migration first."
  exit 3
fi

info "No TCP listener on port 80 or 443 was visible in this snapshot."
warn "This is only a read-only point-in-time check; it does not reserve ports or prove backend compatibility."
warn "No configuration, firewall rule, package, or service was changed."
