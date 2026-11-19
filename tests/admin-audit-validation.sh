#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export AH_AUDIT_LOG="$tmp/admin-actions.log"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
if ah_audit_log 'invalid event' success; then
  echo "Audit logger accepted an invalid event code" >&2
  exit 1
fi
if ah_audit_log valid.event invalid-result; then
  echo "Audit logger accepted an invalid result" >&2
  exit 1
fi
[[ ! -e "$AH_AUDIT_LOG" ]]
if [[ "${EUID}" -eq 0 ]]; then
  ah_audit_log security.test success
  [[ "$(stat -c '%a' "$AH_AUDIT_LOG")" == 600 ]]
  [[ "$(stat -c '%a' "$tmp")" == 700 ]]
  grep -Eq 'event=security.test result=success$' "$AH_AUDIT_LOG"
  if grep -Eq 'password|credential|secret' "$AH_AUDIT_LOG"; then
    echo "Unexpected sensitive field in audit log" >&2
    exit 1
  fi
fi
echo "Admin audit logging validation passed."
