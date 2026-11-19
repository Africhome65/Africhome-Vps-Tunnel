#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT/install.sh"
bash -n "$FILE"

line_of(){
  local pattern="$1" line
  line="$(grep -nF "$pattern" "$FILE" | head -n1 | cut -d: -f1)"
  [[ -n "$line" ]] || { echo "Missing installer safeguard: $pattern" >&2; exit 1; }
  printf '%s' "$line"
}

root_check="$(line_of '[[ "$EUID" -eq 0 ]]')"
os_check="$(line_of 'case "$OS_ID" in')"
symlink_check="$(line_of 'if [[ -L "$INSTALL_DIR" ]]')"
checkout_check="$(line_of 'if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR/.git" ]]')"
clean_check="$(line_of 'git -C "$INSTALL_DIR" status --porcelain --untracked-files=all')"
license_check="$(line_of 'bash "$SCRIPT_DIR/scripts/license.sh" verify')"
apt_update="$(line_of 'apt-get update')"
fetch_reset="$(line_of 'git -C "$INSTALL_DIR" reset --hard')"

(( root_check < os_check && os_check < symlink_check ))
(( symlink_check < checkout_check && checkout_check < clean_check ))
(( clean_check < license_check && license_check < apt_update ))
(( license_check < fetch_reset && apt_update < fetch_reset ))

grep -Fq '[[ -r "$SCRIPT_DIR/scripts/license.sh" ]]' "$FILE"
grep -Fq 'git -C "$INSTALL_DIR" status --porcelain --untracked-files=all' "$FILE"
echo "Installer ordering and overwrite safeguards validation passed."
