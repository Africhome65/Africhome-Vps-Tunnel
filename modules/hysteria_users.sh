#!/usr/bin/env bash
# Per-user Hysteria 2 userpass adapter. Registry stores metadata only.
set -Eeuo pipefail

HY2_USERS_CONFIG="${HY2_USERS_CONFIG:-/etc/hysteria/config.yaml}"
HY2_USERS_DB="${HY2_USERS_DB:-/etc/africhome-hysteria-users.json}"
HY2_USERS_LOCK="${HY2_USERS_LOCK:-/run/lock/africhome-hysteria-users.lock}"
HY2_USERS_BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HY2_USERS_BASE_DIR/lib/common.sh"
. "$HY2_USERS_BASE_DIR/modules/account_registry.sh"

hy2u_require() {
  command -v python3 >/dev/null 2>&1 || { echo "[FAIL] python3 is required." >&2; return 1; }
  python3 -c 'import yaml' >/dev/null 2>&1 || {
    echo "[FAIL] python3-yaml is required (install package python3-yaml)." >&2; return 1;
  }
  command -v openssl >/dev/null 2>&1 || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  [[ -s "$HY2_USERS_CONFIG" ]] || { echo "[FAIL] Hysteria config not found." >&2; return 1; }
  [[ -e "$HY2_USERS_DB" ]] || { install -d -m 700 "$(dirname "$HY2_USERS_DB")"; printf '[]\n' > "$HY2_USERS_DB"; chmod 600 "$HY2_USERS_DB"; }
  jq -e 'type == "array"' "$HY2_USERS_DB" >/dev/null 2>&1 || {
    echo "[FAIL] Hysteria account metadata is invalid; refusing to overwrite." >&2; return 1;
  }
}

hy2u_lock() {
  install -d -m 755 "$(dirname "$HY2_USERS_LOCK")"
  exec 7>"$HY2_USERS_LOCK"
  flock -n 7 || { echo "[WARN] Another Hysteria account operation is running." >&2; return 1; }
}

hy2u_validate_username() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }

# Uses PyYAML rather than fragile text substitutions on YAML.
hy2u_yaml_change() {
  local action="$1" username="$2" password="${3:-}" staged owner group mode
  read -r owner group mode < <(stat -c '%U %G %a' "$HY2_USERS_CONFIG") || return 1
  staged="$(mktemp "${HY2_USERS_CONFIG}.africhome.XXXXXX")" || return 1
  if ! python3 - "$HY2_USERS_CONFIG" "$staged" "$action" "$username" "$password" <<'PY'
import sys, yaml
source, target, action, username, password = sys.argv[1:]
with open(source, encoding="utf-8") as f:
    data = yaml.safe_load(f)
if not isinstance(data, dict):
    raise SystemExit("Hysteria configuration must be a YAML mapping")
auth = data.get("auth")
if not isinstance(auth, dict) or auth.get("type") != "userpass":
    raise SystemExit("Only Hysteria auth.type=userpass is supported; config unchanged")
users = auth.get("userpass")
if users is None:
    users = {}
if not isinstance(users, dict):
    raise SystemExit("auth.userpass must be a mapping")
if action == "add":
    if username in users:
        raise SystemExit("That Hysteria username already exists")
    users[username] = password
elif action == "remove":
    if username not in users:
        raise SystemExit("Hysteria username not found")
    del users[username]
else:
    raise SystemExit("Unsupported action")
auth["userpass"] = users
data["auth"] = auth
with open(target, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False)
PY
  then
    rm -f "$staged"
    return 1
  fi
  install -o "$owner" -g "$group" -m "$mode" "$staged" "$staged.secure"
  mv -f "$staged.secure" "$staged"
  mv -f "$staged" "$HY2_USERS_CONFIG"
}

hy2u_add() {
  ah_require_root || return 1
  hy2u_require || return 1
  hy2u_lock || return 1
  local username password account_id days expires_at expires backup dbtmp
  read -r -p "New Hysteria username: " username
  hy2u_validate_username "$username" || { ah_err "Invalid username."; return 1; }
  if jq -e --arg n "$username" 'any(.[]; .username == $n)' "$HY2_USERS_DB" >/dev/null; then
    ah_err "That Hysteria username is already managed."; return 1
  fi
  read -r -p "Validity in days (0 = never expires): " days
  [[ "$days" =~ ^[0-9]+$ ]] && (( days <= 36500 )) || { ah_err "Enter 0-36500 days."; return 1; }
  if (( days == 0 )); then expires_at=0; expires="Never"
  else expires_at=$(( $(date +%s) + days * 86400 )); expires="$(date -u -d "@$expires_at" '+%Y-%m-%d %H:%M UTC')"; fi
  password="$(openssl rand -hex 24)" || return 1
  account_id="$(openssl rand -hex 16)" || return 1
  backup="${HY2_USERS_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$HY2_USERS_CONFIG" "$backup" || return 1
  hy2u_yaml_change add "$username" "$password" || { ah_err "Could not safely update Hysteria userpass config."; return 1; }
  if ! systemctl restart hysteria-server.service; then
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    ah_err "Hysteria restart failed; previous config restored."; return 1
  fi
  dbtmp="$(mktemp)"
  if ! jq --arg id "$account_id" --arg n "$username" --argjson exp "$expires_at"     '. + [{account_id:$id,username:$n,expires_at:$exp,created_at:(now|floor)}]' "$HY2_USERS_DB" > "$dbtmp"; then
    rm -f "$dbtmp"; cp -a "$backup" "$HY2_USERS_CONFIG"; systemctl restart hysteria-server.service || true
    ah_err "Could not update Hysteria account metadata; config restored."; return 1
  fi
  install -m 600 "$dbtmp" "$HY2_USERS_DB"; rm -f "$dbtmp"
  if ! ar_register_service "$account_id" "$username" "hysteria" "$username" "$expires_at"; then
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    ah_err "Central registry update failed; Hysteria config restored. Remove the uncommitted metadata record before retrying."; return 1
  fi
  echo "Hysteria username: $username"
  echo "Password: $password"
  echo "Expires: $expires"
  ah_warn "Save this password securely. Hysteria userpass stores passwords in the server config."
}

hy2u_list() {
  hy2u_require || return 1
  printf '%-20s %-22s %s\n' USERNAME EXPIRES STATUS
  jq -r '.[] | [.username,(if .expires_at == 0 then "Never" else (.expires_at|todateiso8601) end),(if .expires_at == 0 or .expires_at > now then "Managed" else "Expired (pending cleanup)" end)] | @tsv' "$HY2_USERS_DB" |
  while IFS=$'\t' read -r n e s; do printf '%-20s %-22s %s\n' "$n" "$e" "$s"; done
}

hy2u_remove() {
  ah_require_root || return 1
  hy2u_require || return 1
  hy2u_lock || return 1
  local username record account_id backup tmp
  read -r -p "Hysteria username to revoke: " username
  record="$(jq -c --arg n "$username" '.[] | select(.username == $n)' "$HY2_USERS_DB")"
  [[ -n "$record" ]] || { ah_err "Managed Hysteria user not found."; return 1; }
  account_id="$(jq -r '.account_id' <<< "$record")"
  backup="${HY2_USERS_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$HY2_USERS_CONFIG" "$backup"
  hy2u_yaml_change remove "$username" || return 1
  if ! systemctl restart hysteria-server.service; then
    cp -a "$backup" "$HY2_USERS_CONFIG"; systemctl restart hysteria-server.service || true
    ah_err "Hysteria restart failed; previous config restored."; return 1
  fi
  tmp="$(mktemp)"
  jq --arg n "$username" '[.[] | select(.username != $n)]' "$HY2_USERS_DB" > "$tmp"
  install -m 600 "$tmp" "$HY2_USERS_DB"; rm -f "$tmp"
  ar_set_service_status "$account_id" "hysteria" "$username" "revoked" ||
    ah_warn "Hysteria user revoked, but registry status update failed."
  ah_ok "Hysteria user $username revoked."
}

hy2u_expire() {
  ah_require_root || return 1
  hy2u_require || return 1
  hy2u_lock || return 1
  local expired username record account_id backup tmp changed=0
  expired="$(jq -c '.[] | select(.expires_at != 0 and .expires_at <= now)' "$HY2_USERS_DB")"
  [[ -n "$expired" ]] || { ah_info "No expired Hysteria users."; return 0; }
  backup="${HY2_USERS_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$HY2_USERS_CONFIG" "$backup"
  while IFS= read -r record; do
    username="$(jq -r '.username' <<< "$record")"
    hy2u_yaml_change remove "$username" || { cp -a "$backup" "$HY2_USERS_CONFIG"; ah_err "Expiry cleanup failed; config restored."; return 1; }
    changed=1
  done <<< "$expired"
  if (( changed )); then
    if ! systemctl restart hysteria-server.service; then
      cp -a "$backup" "$HY2_USERS_CONFIG"; systemctl restart hysteria-server.service || true
      ah_err "Hysteria restart failed; config restored."; return 1
    fi
    tmp="$(mktemp)"
    jq '[.[] | select(.expires_at == 0 or .expires_at > now)]' "$HY2_USERS_DB" > "$tmp"
    install -m 600 "$tmp" "$HY2_USERS_DB"; rm -f "$tmp"
    while IFS= read -r record; do
      account_id="$(jq -r '.account_id' <<< "$record")"
      username="$(jq -r '.username' <<< "$record")"
      ar_set_service_status "$account_id" "hysteria" "$username" "expired" ||
        ah_warn "Expired Hysteria user removed, but registry status update failed."
    done <<< "$expired"
    ah_ok "Expired Hysteria users removed."
  fi
}

hy2u_menu() {
  while true; do
    echo
    echo "----- Hysteria 2 User Management -----"
    echo "1) Create user (days-based expiry)"
    echo "2) List users"
    echo "3) Revoke user"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) hy2u_add; ah_pause ;;
      2) hy2u_list; ah_pause ;;
      3) hy2u_remove; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}

if [[ "${1:-}" == "--expire" ]]; then hy2u_expire; fi
