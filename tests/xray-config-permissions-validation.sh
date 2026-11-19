#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

for module in modules/vmess.sh modules/trojan.sh; do
  file="$ROOT/$module"
  bash -n "$file"
  grep -Fq 'install -m 640 -o root -g xray' "$file" || {
    echo "$module does not install Xray config as root:xray mode 640." >&2
    exit 1
  }
  if grep -Eq 'install -m 600 .*_CONFIG' "$file"; then
    echo "$module installs Xray config unreadable to the xray group." >&2
    exit 1
  fi
done

grep -Fq 'chown root:xray "$XRAY_CONFIG"' "$ROOT/modules/xray.sh"
grep -Fq 'chmod 640 "$XRAY_CONFIG"' "$ROOT/modules/xray.sh"
echo "Xray config permission validation passed."
