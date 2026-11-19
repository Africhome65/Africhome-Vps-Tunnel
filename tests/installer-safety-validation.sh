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
checkout_check="$(line_of 'if [[ -e "$INSTALL_DIR" && ( ! -d "$INSTALL_DIR/.git" || -L "$INSTALL_DIR/.git" ) ]]')"
git_metadata_check="$(line_of 'if [[ -d "$INSTALL_DIR/.git" && ! -L "$INSTALL_DIR/.git" ]]')"
clean_check="$(line_of 'git -C "$INSTALL_DIR" status --porcelain --untracked-files=all')"
license_check="$(line_of 'bash "$SCRIPT_DIR/scripts/license.sh" verify')"
apt_update="$(line_of 'apt-get update')"
fetch_reset="$(line_of 'git -C "$INSTALL_DIR" reset --hard')"

(( root_check < os_check && os_check < symlink_check ))
(( symlink_check < checkout_check && checkout_check < git_metadata_check && git_metadata_check < clean_check ))
(( clean_check < license_check && license_check < apt_update ))
(( license_check < fetch_reset && apt_update < fetch_reset ))

grep -Fq '[[ -r "$SCRIPT_DIR/scripts/license.sh" ]]' "$FILE"
grep -Fq '|| -L "$INSTALL_DIR/.git"' "$FILE"
grep -Fq 'git -C "$INSTALL_DIR" status --porcelain --untracked-files=all' "$FILE"
grep -Fq 'INSTALL_BRANCH="feature/central-dnstt-integration"' "$FILE"
for dnstt_script in install-dnstt.sh configure-dnstt-domain.sh install-dnstt-service.sh; do
  expected='"$INSTALL_DIR/scripts/'"$dnstt_script"'"'
  grep -Fq "$expected" "$FILE"
done
LICENSE="$ROOT/scripts/license.sh"
bash -n "$LICENSE"
grep -Fq '[[ -L "$LICENSE_DIR" || ( -e "$LICENSE_DIR" && ! -d "$LICENSE_DIR" ) ]]' "$LICENSE"
grep -Fq '[[ -f "$LICENSE_FILE" && ! -L "$LICENSE_FILE"' "$LICENSE"
grep -Fq 'mode 0600' "$LICENSE"
ISSUER="$ROOT/admin/issue-license.sh"
bash -n "$ISSUER"
grep -Fq '[[ -f "$private_key" && ! -L "$private_key" ]]' "$ISSUER"
grep -Fq '(( (8#$key_mode & 077) == 0 ))' "$ISSUER"
grep -Fq 'cmp -s "$tmp/issuer-public.der" "$tmp/repository-public.der"' "$ISSUER"
grep -Fq 'Private key does not match this repository' "$ISSUER"
echo "Installer ordering and overwrite safeguards validation passed."
