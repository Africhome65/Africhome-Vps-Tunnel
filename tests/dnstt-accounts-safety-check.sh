#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT_DIR/modules/dnstt_users.sh"
MENU="$ROOT_DIR/menu.sh"

[[ -s "$MODULE" ]] || { echo "Missing DNSTT account module." >&2; exit 1; }
bash -n "$MODULE"
bash -n "$MENU"

# Source-only validation must not require root or mutate system accounts.
bash -c '
  set -Eeuo pipefail
  source "$1"
  dt_valid_username customer_01
  ! dt_valid_username root
  ! dt_valid_username "bad name"
' _ "$MODULE"

grep -q 'useradd --create-home --shell /bin/bash --groups "$DT_GROUP"' "$MODULE"
grep -q 'chage --expiredate' "$MODULE"
grep -q 'usermod --lock --expiredate 1970-01-02' "$MODULE"
grep -q 'openssl rand -hex 16' "$MODULE"
grep -q 'option="-udp"' "$MODULE"
grep -q 'option="-dot"' "$MODULE"
grep -q 'option="-doh"' "$MODULE"

# Customer passwords must never be written to a persistent credential file.
if grep -E -q 'PASSWORD=.*>|\.cred|africhome.*password.*\.db' "$MODULE"; then
  echo "DNSTT module appears to persist customer passwords." >&2
  exit 1
fi

grep -q 'modules/dnstt_users.sh' "$MENU"
grep -q 'dnstt_users_menu' "$MENU"
grep -q 'input hidden' "$MODULE"
grep -q 'Confirm your password' "$MODULE"
grep -q 'root-owned regular file with mode 0600' "$MODULE"
grep -q 'root-owned regular file with mode 0644' "$MODULE"
for entry in '26) bash "$BASE_DIR/scripts/install-dnstt.sh"' '27) bash "$BASE_DIR/scripts/configure-dnstt-domain.sh"' '28) bash "$BASE_DIR/scripts/install-dnstt-service.sh"' '29) dnstt_users_menu'; do
  grep -Fq "$entry" "$MENU" || {
    echo "Missing DNSTT menu action: $entry" >&2
    exit 1
  }
done
grep -Fq '"$INSTALL_DIR/scripts/install-dnstt.sh"' "$ROOT_DIR/install.sh"
grep -Fq '"$INSTALL_DIR/scripts/configure-dnstt-domain.sh"' "$ROOT_DIR/install.sh"
grep -Fq '"$INSTALL_DIR/scripts/install-dnstt-service.sh"' "$ROOT_DIR/install.sh"

echo "DNSTT customer-account and resolver safety checks passed."
