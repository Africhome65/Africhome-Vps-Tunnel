#!/usr/bin/env bash
# Explicitly apply a reviewed shared TCP/443 Xray + HAProxy candidate.
set -Eeuo pipefail

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || fail "Run as root."
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -r "$SCRIPT_DIR/scripts/license.sh" ]] || fail "Licence verifier is missing."
bash "$SCRIPT_DIR/scripts/license.sh" verify
[[ -r "$SCRIPT_DIR/scripts/lib/shared443-transaction.sh" ]] || fail "Shared-443 transaction helper is missing."
# shellcheck source=scripts/lib/shared443-transaction.sh
. "$SCRIPT_DIR/scripts/lib/shared443-transaction.sh"

XRAY_CONFIG="${AFRICHOME_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
HAPROXY_CONFIG="${AFRICHOME_HAPROXY_CONFIG:-/etc/haproxy/haproxy.cfg}"
VMESS_STATE="${AFRICHOME_VMESS_STATE:-/etc/africhome-vmess.env}"
BACKUP_ROOT="${AFRICHOME_SHARED443_BACKUP_ROOT:-/var/backups/africhome}"
XRAY_SERVICE="${AFRICHOME_XRAY_SERVICE:-xray.service}"
HAPROXY_SERVICE="${AFRICHOME_HAPROXY_SERVICE:-haproxy.service}"

candidate_dir="${1:-}"
if [[ -z "$candidate_dir" ]]; then
  read -r -p "Full path to the reviewed shared-443 candidate directory: " candidate_dir
fi
[[ -n "$candidate_dir" ]] || fail "Candidate directory is required."

cat <<'NOTICE'
WARNING: This operation restarts Xray, replaces the complete HAProxy configuration,
and starts/enables HAProxy. Tunnel connections will be interrupted. Review the
candidate files first. No DNS records, UFW rules or provider firewall rules are changed.
NOTICE
read -r -p "Type APPLY to proceed with the shared TCP/443 migration: " confirmation
[[ "$confirmation" == "APPLY" ]] || fail "Confirmation not received; no changes made."

shared443_apply_transaction "$candidate_dir" "$XRAY_CONFIG" "$HAPROXY_CONFIG" "$VMESS_STATE" \
  "$BACKUP_ROOT" "$XRAY_SERVICE" "$HAPROXY_SERVICE" 1
