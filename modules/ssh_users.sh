#!/usr/bin/env bash

ssh_users_create(){
  ah_require_root || return
  local username expiry
  read -r -p "New SSH username (letters, digits, _ or -): " username
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ah_err "Invalid username."; return; }
  if id "$username" >/dev/null 2>&1; then ah_err "That username already exists."; return; fi
  read -r -p "Account expiry date YYYY-MM-DD (blank = no expiry): " expiry
  if [[ -n "$expiry" ]]; then
    [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { ah_err "Use YYYY-MM-DD."; return; }
    date -d "$expiry" >/dev/null 2>&1 || { ah_err "Invalid calendar date."; return; }
    [[ "$(date -d "$expiry" +%F)" == "$expiry" ]] || { ah_err "Invalid date."; return; }
    [[ "$expiry" > "$(date +%F)" ]] || { ah_err "Expiry must be in the future."; return; }
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
  echo "Set a password for $username. Use a strong, unique password."
  if ! passwd "$username"; then
    userdel "$username" || true
    ah_err "Password setup failed; account creation was rolled back."; return
  fi
  ah_ok "SSH system account '$username' created."
  [[ -n "$expiry" ]] && ah_info "Account expiry: $expiry"
  ah_warn "This creates a Linux account; SSH daemon policy, key-only authentication, and network access still depend on your server configuration."
}

ssh_users_list(){
  printf '%-22s %-12s %-14s\n' "USERNAME" "UID" "EXPIRY"
  while IFS=: read -r name _ uid _ _ _ shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= 1000 )) || continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    local exp
    exp="$(chage -l "$name" 2>/dev/null | awk -F': ' '/Account expires/{print $2}')"
    printf '%-22s %-12s %-14s\n' "$name" "$uid" "${exp:-unknown}"
  done < <(getent passwd)
}

ssh_users_lock(){
  ah_require_root || return
  local username
  read -r -p "Username to lock: " username
  id "$username" >/dev/null 2>&1 || { ah_err "User does not exist."; return; }
  [[ "$username" != root ]] || { ah_err "Refusing to lock root from this menu."; return; }
  passwd -l "$username" && ah_ok "Password login locked for $username."
  ah_warn "Existing SSH sessions may remain active; terminate them separately if required."
}

ssh_users_unlock(){
  ah_require_root || return
  local username
  read -r -p "Username to unlock: " username
  id "$username" >/dev/null 2>&1 || { ah_err "User does not exist."; return; }
  [[ "$username" != root ]] || { ah_err "Root unlock is not managed here."; return; }
  passwd -u "$username" && ah_ok "Password login unlocked for $username."
}

ssh_users_set_expiry(){
  ah_require_root || return
  local username expiry
  read -r -p "Existing username: " username
  id "$username" >/dev/null 2>&1 || { ah_err "User does not exist."; return; }
  [[ "$username" != root ]] || { ah_err "Refusing to change root expiry."; return; }
  read -r -p "New expiry YYYY-MM-DD (or 0 for no expiry): " expiry
  if [[ "$expiry" == "0" ]]; then
    chage --expiredate "" "$username" && ah_ok "Expiry cleared for $username."
    return
  fi
  [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { ah_err "Use YYYY-MM-DD."; return; }
  date -d "$expiry" >/dev/null 2>&1 || { ah_err "Invalid date."; return; }
  [[ "$(date -d "$expiry" +%F)" == "$expiry" ]] || { ah_err "Invalid date."; return; }
  chage --expiredate "$expiry" "$username" && ah_ok "Expiry set for $username: $expiry."
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
