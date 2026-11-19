#!/usr/bin/env bash

SSH_USERS_BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SSH_USERS_BASE_DIR/modules/account_registry.sh"

ssh_users_create(){
  ah_require_root || return
  local username expiry days expires_at account_id password password_confirm
  read -r -p "New SSH username (letters, digits, _ or -): " username
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ah_err "Invalid username."; return; }
  if id "$username" >/dev/null 2>&1; then ah_err "That username already exists."; return; fi
  read -r -p "Account duration in days (0 = no expiry): " days
  [[ "$days" =~ ^[0-9]+$ ]] || { ah_err "Enter a whole number of days."; return; }
  if (( days > 36500 )); then ah_err "Maximum duration is 36500 days."; return; fi
  expires_at=0
  expiry=""
  if (( days > 0 )); then
    expiry="$(date -d "+${days} days" +%F)" || { ah_err "Could not calculate expiry date."; return; }
    expires_at="$(date -u -d "$expiry" +%s)" || { ah_err "Could not calculate expiry timestamp."; return; }
  fi
  if ! useradd --create-home --shell /bin/bash "$username"; then
    ah_err "Could not create account."; return
  fi
  if [[ -n "$expiry" ]]; then
    if ! chage --expiredate "$expiry" "$username"; then
      userdel "$username" || true
      ah_err "Could not set expiry; account creation was rolled back."; return
    fi
  fi
  echo "Set a strong, unique password for $username."
  read -r -s -p "New password: " password
  printf '\n'
  read -r -s -p "Confirm password: " password_confirm
  printf '\n'
  if [[ -z "$password" || "$password" == *:* || "$password" != "$password_confirm" ]]; then
    unset password password_confirm
    userdel "$username" || true
    ah_err "Password was empty, unsupported, or did not match; account creation was rolled back."; return
  fi
  if ! printf '%s:%s\n' "$username" "$password" | chpasswd; then
    unset password password_confirm
    userdel "$username" || true
    ah_err "Password setup failed; account creation was rolled back."; return
  fi
  unset password password_confirm
  account_id="$(openssl rand -hex 16)" || { userdel "$username" || true; ah_err "Could not create account ID."; return; }
  if ! ar_register_service "$account_id" "$username" "ssh" "$username" "$expires_at"; then
    userdel "$username" || true
    ah_err "Could not register SSH account; account creation was rolled back."; return
  fi
  ah_audit_log ssh.account.create success 2>/dev/null || true
  ah_ok "SSH system account '$username' created and registered."
  echo "Account ID: $account_id"
  [[ -n "$expiry" ]] && ah_info "Account expiry: $expiry"
  ah_warn "This creates a Linux account; SSH daemon policy, key-only authentication, and network access still depend on your server configuration."
}

ssh_users_list(){
  printf '%-22s %-12s %-14s\n' "USERNAME" "UID" "REMAINING"
  while IFS=: read -r name _ uid _ _ _ shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= 1000 )) || continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    local exp
    exp="$(chage -l "$name" 2>/dev/null | awk -F': ' '/Account expires/{print $2}')"
    if [[ "$exp" == "never" || "$exp" == "Never" ]]; then exp="Never"
    elif [[ -n "$exp" ]]; then
      local exp_ts now
      exp_ts="$(date -d "$exp" +%s 2>/dev/null || echo 0)"; now="$(date +%s)"
      if (( exp_ts == 0 )); then exp="Unknown"
      elif (( exp_ts <= now )); then exp="Expired"
      else exp="$(( (exp_ts - now + 86399) / 86400 )) days"; fi
    else exp="Unknown"; fi
    printf '%-22s %-12s %-14s\n' "$name" "$uid" "$exp"
  done < <(getent passwd)
}

ssh_users_lock(){
  ah_require_root || return
  local username
  read -r -p "Username to lock: " username
  id "$username" >/dev/null 2>&1 || { ah_err "User does not exist."; return; }
  [[ "$username" != root ]] || { ah_err "Refusing to lock root from this menu."; return; }
  if passwd -l "$username"; then
    ah_audit_log ssh.account.lock success 2>/dev/null || true
    ah_ok "Password login locked for $username."
  else
    return 1
  fi
  ah_warn "Existing SSH sessions may remain active; terminate them separately if required."
}

ssh_users_unlock(){
  ah_require_root || return
  local username
  read -r -p "Username to unlock: " username
  id "$username" >/dev/null 2>&1 || { ah_err "User does not exist."; return; }
  [[ "$username" != root ]] || { ah_err "Root unlock is not managed here."; return; }
  if passwd -u "$username"; then
    ah_audit_log ssh.account.unlock success 2>/dev/null || true
    ah_ok "Password login unlocked for $username."
  else
    return 1
  fi
}

ssh_users_set_expiry(){
  ah_require_root || return
  local username expiry days expires_at account_id
  read -r -p "Existing username: " username
  id "$username" >/dev/null 2>&1 || { ah_err "User does not exist."; return; }
  [[ "$username" != root ]] || { ah_err "Refusing to change root expiry."; return; }
  read -r -p "Account duration in days from today (0 = no expiry): " days
  [[ "$days" =~ ^[0-9]+$ ]] || { ah_err "Enter a whole number of days."; return; }
  if (( days > 36500 )); then ah_err "Maximum duration is 36500 days."; return; fi
  expires_at=0
  if (( days == 0 )); then
    chage --expiredate "" "$username" || { ah_err "Could not clear account expiry."; return; }
    ah_ok "Expiry cleared for $username."
  else
    expiry="$(date -d "+${days} days" +%F)" || { ah_err "Could not calculate expiry date."; return; }
    expires_at="$(date -u -d "$expiry" +%s)" || { ah_err "Could not calculate expiry timestamp."; return; }
    chage --expiredate "$expiry" "$username" || { ah_err "Could not set account expiry."; return; }
    ah_ok "Expiry set for $username: $expiry (${days} days from today)."
  fi
  account_id="$(jq -r --arg n "$username" '.accounts[] | select(any(.services[]; .service == "ssh" and .ref == $n)) | .id' "$AR_REGISTRY" 2>/dev/null | head -n1)"
  [[ -n "$account_id" ]] || account_id="$(openssl rand -hex 16)"
  if ! ar_register_service "$account_id" "$username" "ssh" "$username" "$expires_at"; then
    ah_warn "SSH expiry changed, but the central registry could not be synchronized."
  fi
  ah_audit_log ssh.account.expiry success 2>/dev/null || true
}

ssh_users_menu(){
  while true; do
    clear
    echo "=== SSH ACCOUNT MANAGEMENT ==="
    echo "1) Create SSH Linux account"
    echo "2) List interactive accounts"
    echo "3) Lock account password"
    echo "4) Unlock account password"
    echo "5) Set/clear account expiry"
    echo "0) Back"
    read -r -p "Select: " choice
    case "$choice" in
      1) ssh_users_create; ah_pause ;;
      2) ssh_users_list; ah_pause ;;
      3) ssh_users_lock; ah_pause ;;
      4) ssh_users_unlock; ah_pause ;;
      5) ssh_users_set_expiry; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice."; sleep 1 ;;
    esac
  done
}
