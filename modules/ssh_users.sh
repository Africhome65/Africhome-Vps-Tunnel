#!/usr/bin/env bash

ssh_users_create(){
  ah_require_root || return
  local username expiry
  read -r -p "New SSH username (letters, digits, _ or -): " username
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ah_err "Invalid username."; return; }
  if id "$username" >/dev/null 2>&1; then ah_err "That username already exists."; return; fi
  local days
  read -r -p "Account duration in days (0 = no expiry): " days
  [[ "$days" =~ ^[0-9]+$ ]] || { ah_err "Enter a whole number of days."; return; }
  if (( days > 36500 )); then ah_err "Maximum duration is 36500 days."; return; fi
  expiry=""
  if (( days > 0 )); then
    expiry="$(date -d "+${days} days" +%F)" || { ah_err "Could not calculate expiry date."; return; }
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
  local password password_confirm
  echo "Set a strong, unique password for $username."
  echo "WARNING: Password characters will be visible while you type."
  read -r -p "New password (visible): " password
  read -r -p "Confirm password (visible): " password_confirm
  if [[ -z "$password" || "$password" == *:* || "$password" != "$password_confirm" ]]; then
    unset password password_confirm
    userdel "$username" || true
    ah_err "Password was empty, contained an unsupported colon, or did not match; account creation was rolled back."; return
  fi
  if ! printf '%s:%s\n' "$username" "$password" | chpasswd; then
    unset password password_confirm
    userdel "$username" || true
    ah_err "Password setup failed; account creation was rolled back."; return
  fi
  unset password password_confirm
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
  read -r -p "Account duration in days from today (0 = no expiry): " days
  [[ "$days" =~ ^[0-9]+$ ]] || { ah_err "Enter a whole number of days."; return; }
  if (( days > 36500 )); then ah_err "Maximum duration is 36500 days."; return; fi
  if (( days == 0 )); then
    chage --expiredate "" "$username" && ah_ok "Expiry cleared for $username."
    return
  fi
  expiry="$(date -d "+${days} days" +%F)" || { ah_err "Could not calculate expiry date."; return; }
  chage --expiredate "$expiry" "$username" && ah_ok "Expiry set for $username: $expiry (${days} days from today)."
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
