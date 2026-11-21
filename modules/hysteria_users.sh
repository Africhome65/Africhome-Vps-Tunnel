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
  command -v jq >/dev/null 2>&1 || ah_apt_install jq || return 1
  python3 -c 'import yaml' >/dev/null 2>&1 || ah_apt_install python3-yaml || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  [[ -f "$HY2_USERS_CONFIG" && ! -L "$HY2_USERS_CONFIG" && -s "$HY2_USERS_CONFIG" ]] || {
    echo "[FAIL] Hysteria config must be a non-symlink regular file." >&2; return 1;
  }
  [[ -e "$HY2_USERS_DB" ]] || { install -d -m 700 "$(dirname "$HY2_USERS_DB")"; printf '[]\n' > "$HY2_USERS_DB"; chmod 600 "$HY2_USERS_DB"; }
  [[ -f "$HY2_USERS_DB" && ! -L "$HY2_USERS_DB" ]] || {
    echo "[FAIL] Hysteria account database must be a regular non-symlink file." >&2; return 1;
  }
  [[ -f "$HY2_USERS_DB" && ! -L "$HY2_USERS_DB" ]] || {
    echo "[FAIL] Hysteria account database must be a regular non-symlink file." >&2; return 1;
  }
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
  local username password account_id days expires_at expires backup dbtmp dbbackup
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
  backup="$(mktemp "${HY2_USERS_CONFIG}.africhome-backup.XXXXXX")"
  dbbackup="$(mktemp "${HY2_USERS_DB}.africhome-backup.XXXXXX")"
  cp -a "$HY2_USERS_CONFIG" "$backup" || return 1
  cp -a "$HY2_USERS_DB" "$dbbackup" || return 1
  hy2u_yaml_change add "$username" "$password" || { ah_err "Could not safely update Hysteria userpass config."; return 1; }
  if ! systemctl restart hysteria-server.service; then
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    ah_err "Hysteria restart failed; previous config restored."; return 1
  fi
  dbtmp="$(mktemp "${HY2_USERS_DB}.africhome.XXXXXX")" || { cp -a "$backup" "$HY2_USERS_CONFIG"; systemctl restart hysteria-server.service || true; return 1; }
  if ! jq --arg id "$account_id" --arg n "$username" --argjson exp "$expires_at"     '. + [{account_id:$id,username:$n,expires_at:$exp,created_at:(now|floor)}]' "$HY2_USERS_DB" > "$dbtmp"; then
    rm -f "$dbtmp"; cp -a "$backup" "$HY2_USERS_CONFIG"; systemctl restart hysteria-server.service || true
    ah_err "Could not update Hysteria account metadata; config restored."; return 1
  fi
  if ! install -o root -g root -m 600 "$dbtmp" "$HY2_USERS_DB"; then
    rm -f "$dbtmp"
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    ah_err "Could not commit Hysteria metadata; config restored."
    return 1
  fi
  rm -f "$dbtmp"
  if ! ar_register_service "$account_id" "$username" "hysteria" "$username" "$expires_at"; then
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    cp -a "$dbbackup" "$HY2_USERS_DB"
    ah_err "Central registry update failed; Hysteria config and local metadata were restored."; return 1
  fi
  ah_audit_log hysteria.account.create success 2>/dev/null || true
  echo "Hysteria username: $username"
  echo "Password: $password"
  echo "Expires: $expires"
  if [[ -r /etc/africhome-hysteria.env ]]; then
    # shellcheck disable=SC1091
    . /etc/africhome-hysteria.env
    printf 'Client URI: hysteria2://%s:%s@%s:%s/?sni=%s#Africhome-%s\\n' "$username" "$password" "$HY2_DOMAIN" "$HY2_PORT_SPEC" "$HY2_DOMAIN" "$username"
  fi
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
  local username record account_id previous_status backup tmp dbbackup
  read -r -p "Hysteria username to revoke: " username
  record="$(jq -c --arg n "$username" '.[] | select(.username == $n)' "$HY2_USERS_DB")"
  [[ -n "$record" ]] || { ah_err "Managed Hysteria user not found."; return 1; }
  account_id="$(jq -r '.account_id' <<< "$record")"
  ar_init || return 1
  previous_status="$(jq -r --arg id "$account_id" --arg name "$username" '.accounts[] | select(.id == $id) | .services[] | select(.service == "hysteria" and .ref == $name) | .status' "$AR_REGISTRY")"
  [[ -n "$previous_status" && "$previous_status" != "null" ]] || { ah_err "Matching Hysteria registry record not found."; return 1; }
  backup="$(mktemp "${HY2_USERS_CONFIG}.africhome-backup.XXXXXX")"
  dbbackup="$(mktemp "${HY2_USERS_DB}.africhome-backup.XXXXXX")"
  tmp="$(mktemp "${HY2_USERS_DB}.africhome.XXXXXX")" || return 1
  cp -a "$HY2_USERS_CONFIG" "$backup" || { rm -f "$tmp"; return 1; }
  cp -a "$HY2_USERS_DB" "$dbbackup" || { rm -f "$tmp"; return 1; }
  if ! jq --arg n "$username" '[.[] | select(.username != $n)]' "$HY2_USERS_DB" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  chmod 600 "$tmp"
  ar_set_service_status "$account_id" "hysteria" "$username" "revoked" || {
    rm -f "$tmp"; ah_err "Registry update failed; Hysteria account was not changed."; return 1;
  }
  if ! hy2u_yaml_change remove "$username"; then
    ar_set_service_status "$account_id" "hysteria" "$username" "$previous_status" || true
    rm -f "$tmp"; ah_err "Could not update Hysteria config; registry rollback attempted."; return 1
  fi
  if ! systemctl restart hysteria-server.service; then
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    ar_set_service_status "$account_id" "hysteria" "$username" "$previous_status" || true
    rm -f "$tmp"
    ah_err "Hysteria restart failed; config restored and registry rollback attempted."; return 1
  fi
  if ! install -o root -g root -m 600 "$tmp" "$HY2_USERS_DB"; then
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    ar_set_service_status "$account_id" "hysteria" "$username" "active" || true
    rm -f "$tmp"
    ah_err "Local metadata update failed; config restored and registry rollback attempted."; return 1
  fi
  rm -f "$tmp"
  ah_audit_log hysteria.account.revoke success 2>/dev/null || true
  ah_ok "Hysteria user $username revoked."
}

hy2u_expire() {
  ah_require_root || return 1
  hy2u_require || return 1
  hy2u_lock || return 1
  local expired username record account_id previous_status backup tmp registry_done=""
  expired="$(jq -c '.[] | select(.expires_at != 0 and .expires_at <= now)' "$HY2_USERS_DB")"
  [[ -n "$expired" ]] || { ah_info "No expired Hysteria users."; return 0; }
  backup="${HY2_USERS_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp "${HY2_USERS_DB}.africhome.XXXXXX")" || return 1
  cp -a "$HY2_USERS_CONFIG" "$backup" || { rm -f "$tmp"; return 1; }
  if ! jq '[.[] | select(.expires_at == 0 or .expires_at > now)]' "$HY2_USERS_DB" > "$tmp"; then
    rm -f "$tmp"; ah_err "Could not stage Hysteria expiry metadata."; return 1
  fi
  chmod 600 "$tmp"

  # Stage all native config edits before touching registry metadata.
  while IFS= read -r record; do
    username="$(jq -r '.username' <<< "$record")"
    if ! hy2u_yaml_change remove "$username"; then
      cp -a "$backup" "$HY2_USERS_CONFIG"
      rm -f "$tmp"
      ah_err "Expiry config update failed; previous config restored."
      return 1
    fi
  done <<< "$expired"

  # Record previous registry states so partial failures can be compensated.
  ar_init || { cp -a "$backup" "$HY2_USERS_CONFIG"; rm -f "$tmp"; return 1; }
  while IFS= read -r record; do
    account_id="$(jq -r '.account_id' <<< "$record")"
    username="$(jq -r '.username' <<< "$record")"
    previous_status="$(jq -r --arg id "$account_id" --arg name "$username" '.accounts[] | select(.id == $id) | .services[] | select(.service == "hysteria" and .ref == $name) | .status' "$AR_REGISTRY")"
    if [[ -z "$previous_status" ]]; then
      cp -a "$backup" "$HY2_USERS_CONFIG"
      while IFS='|' read -r rid rname rstatus; do
        [[ -n "$rid" ]] || continue
        ar_set_service_status "$rid" hysteria "$rname" "$rstatus" || true
      done <<< "$registry_done"
      rm -f "$tmp"
      ah_err "Registry record missing; expiry changes rolled back."
      return 1
    fi
    if ! ar_set_service_status "$account_id" hysteria "$username" expired; then
      cp -a "$backup" "$HY2_USERS_CONFIG"
      while IFS='|' read -r rid rname rstatus; do
        [[ -n "$rid" ]] || continue
        ar_set_service_status "$rid" hysteria "$rname" "$rstatus" || true
      done <<< "$registry_done"
      rm -f "$tmp"
      ah_err "Registry update failed; expiry changes rolled back where possible."
      return 1
    fi
    registry_done+="$account_id|$username|$previous_status"$'\n'
  done <<< "$expired"

  if ! systemctl restart hysteria-server.service; then
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    while IFS='|' read -r rid rname rstatus; do
      [[ -n "$rid" ]] || continue
      ar_set_service_status "$rid" hysteria "$rname" "$rstatus" || true
    done <<< "$registry_done"
    rm -f "$tmp"
    ah_err "Hysteria restart failed; config restored and registry rollback attempted."
    return 1
  fi
  if ! install -o root -g root -m 600 "$tmp" "$HY2_USERS_DB"; then
    cp -a "$backup" "$HY2_USERS_CONFIG"
    systemctl restart hysteria-server.service || true
    while IFS='|' read -r rid rname rstatus; do
      [[ -n "$rid" ]] || continue
      ar_set_service_status "$rid" hysteria "$rname" "$rstatus" || true
    done <<< "$registry_done"
    rm -f "$tmp"
    ah_err "Local metadata update failed; config restored and registry rollback attempted."
    return 1
  fi
  rm -f "$tmp"
  ah_audit_log hysteria.account.expire success 2>/dev/null || true
  ah_ok "Expired Hysteria users removed."
}

hy2u_install_timer() {
  ah_require_root || return 1
  local script="/opt/africhome-vps-tunnel/modules/hysteria_users.sh"
  [[ -r "$script" ]] || { ah_err "Install the Africhome release before enabling Hysteria expiry automation."; return 1; }
  cat > /etc/systemd/system/africhome-hysteria-expire.service <<EOF
[Unit]
Description=Expire Africhome Hysteria users

[Service]
Type=oneshot
ExecStart=/bin/bash $script --expire
EOF
  cat > /etc/systemd/system/africhome-hysteria-expire.timer <<'EOF'
[Unit]
Description=Daily expiry check for Africhome Hysteria users

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now africhome-hysteria-expire.timer
  ah_audit_log hysteria.expiry_timer.enable success 2>/dev/null || true
  ah_ok "Daily Hysteria account expiry timer enabled."
}

hy2u_menu() {
  while true; do
    echo
    echo "----- Hysteria 2 User Management -----"
    echo "1) Create user (days-based expiry)"
    echo "2) List users"
    echo "3) Revoke user"
    echo "4) Enable daily expiry automation"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) hy2u_add; ah_pause ;;
      2) hy2u_list; ah_pause ;;
      3) hy2u_remove; ah_pause ;;
      4) hy2u_install_timer; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}

if [[ "${1:-}" == "--expire" ]]; then hy2u_expire; fi
