#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
modules=("$ROOT/modules/ssh_users.sh" "$ROOT/modules/protocol_users.sh" "$ROOT/modules/hysteria_users.sh")
required=(
  ssh.account.create ssh.account.lock ssh.account.unlock ssh.account.expiry
  protocol.account.create protocol.account.renew protocol.account.revoke protocol.account.expire
  hysteria.account.create hysteria.account.revoke hysteria.account.expire
)
for event in "${required[@]}"; do
  if ! grep -Fq "ah_audit_log $event success" "${modules[@]}"; then
    echo "Missing audit event: $event" >&2
    exit 1
  fi
done
# Audit call arguments must remain fixed literals, never variables or credentials.
if grep -En 'ah_audit_log[[:space:]]+[^[:space:]]*[$]' "${modules[@]}"; then
  echo "Dynamic data found in an audit event call." >&2
  exit 1
fi
echo "Account-management audit integration validation passed."
