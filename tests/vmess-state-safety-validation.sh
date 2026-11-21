#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VMESS="$ROOT/modules/vmess.sh"

# A dangling symlink has -e=false but -L=true. The add path must reject both
# existing state files and dangling links before it can write as root.
grep -Fq '[[ ! -e "$VMESS_STATE" && ! -L "$VMESS_STATE" ]]' "$VMESS" || {
  echo "VMess add must reject existing and dangling-symlink state paths." >&2
  exit 1
}
grep -Fq 'vmess_require_safe_state()' "$VMESS" || {
  echo "VMess must centralize safe state-file validation." >&2
  exit 1
}
grep -Fq 'vmess_require_safe_state || return 1' "$VMESS" || {
  echo "VMess state must be validated before client display and removal." >&2
  exit 1
}
grep -Fq "stat -c '%u:%a' \"\$VMESS_STATE\"" "$VMESS" || {
  echo "VMess state must be root-owned and mode 600 before sourcing." >&2
  exit 1
}
grep -Fq 'unsafe symlink' "$VMESS" || {
  echo "VMess state refusal should explain the unsafe symlink case." >&2
  exit 1
}
echo "VMess state-path safety validation passed."
