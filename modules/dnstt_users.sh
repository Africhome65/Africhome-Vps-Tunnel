#!/usr/bin/env bash
# DNSTT customer SSH accounts and client-side recursive DNS resolver guidance.
# DNSTT carries TCP streams; individual customer authentication is performed by SSH.
set -Eeuo pipefail

DT_GROUP="africhome-dnstt"
DT_CONFIG_DIR="/etc/africhome-dnstt"
DT_DOMAIN_CONFIG="$DT_CONFIG_DIR/server.env"
DT_PUBLIC_KEY="$DT_CONFIG_DIR/server.pub"

dt_require_root() {
  [[ "$EUID" -eq 0 ]] || { echo "Run Africhome as root." >&2; return 1; }
  command -v useradd >/dev/null 2>&1 || { echo "useradd is required." >&2; return 1; }
  command -v chage >/dev/null 2>&1 || { echo "chage is required." >&2; return 1; }
  command -v openssl >/dev/null 2>&1 || { echo "openssl is required." >&2; return 1; }
  getent group "$DT_GROUP" >/dev/null 2>&1 || groupadd --system "$DT_GROUP"
}

dt_valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != root ]]
}

dt_read_domain() {
  [[ -r "$DT_DOMAIN_CONFIG" ]] || { echo "DNSTT domain is not configured. Configure it first." >&2; return 1; }
  DT_DOMAIN="$(sed -n 's/^DNS_DOMAIN=//p' "$DT_DOMAIN_CONFIG" | head -n1)"
  [[ "$DT_DOMAIN" =~ ^[a-z0-9.-]+$ && "$DT_DOMAIN" == *.* ]] || {
    echo "Saved DNSTT domain is invalid; refusing to generate client settings." >&2
    return 1
  }
}

dt_expiry_label() {
  local expiry
  expiry="$(chage -l "$1" 2>/dev/null | awk -F': ' '/Account expires/{print $2}')"
  if [[ "$expiry" == "never" || "$expiry" == "Never" ]]; then
    printf 'Never'
  elif [[ -n "$expiry" ]] && date -d "$expiry" +%s >/dev/null 2>&1; then
    if (( $(date -d "$expiry" +%s) <= $(date +%s) )); then
      printf 'Expired (%s)' "$expiry"
    else
      printf '%s (%s days left)' "$expiry" "$(( ($(date -d "$expiry" +%s) - $(date +%s) + 86399) / 86400 ))"
    fi
  else
    printf 'Unknown'
  fi
}

dt_accounts_create() {
  dt_require_root || return 1
  local username days expiry password password_confirm password_mode
  read -r -p "New DNSTT customer SSH username: " username
  dt_valid_username "$username" || { echo "Invalid username; use lowercase letters, digits, _ or - (not root)." >&2; return 1; }
  id "$username" >/dev/null 2>&1 && { echo "That Linux username already exists." >&2; return 1; }
  read -r -p "Validity in days (1-36500, 0 = never expires): " days
  [[ "$days" =~ ^[0-9]+$ ]] && (( days <= 36500 )) || { echo "Enter 0-36500 days." >&2; return 1; }
  expiry=""
  if (( days > 0 )); then
    expiry="$(date -d "+${days} days" +%F)" || { echo "Could not calculate expiry." >&2; return 1; }
  fi

  echo "Password options:"
  echo "1) Generate a secure random password"
  echo "2) Set my own password"
  read -r -p "Choose password option [1-2]: " password_mode
  case "$password_mode" in
    1)
      password="$(openssl rand -hex 16)" || return 1
      ;;
    2)
      read -r -s -p "Enter your password (minimum 12 characters; ':' is not allowed): " password
      echo
      [[ ${#password} -ge 12 && "$password" != *:* ]] || {
        unset password
        echo "Password must be at least 12 characters and must not contain a colon." >&2
        return 1
      }
      read -r -s -p "Confirm your password: " password_confirm
      echo
      if [[ "$password" != "$password_confirm" ]]; then
        unset password password_confirm
        echo "Passwords do not match; account was not created." >&2
        return 1
      fi
      unset password_confirm
      ;;
    *)
      echo "Invalid password option; account was not created." >&2
      return 1
      ;;
  esac

  if ! useradd --create-home --shell /bin/bash --groups "$DT_GROUP" "$username"; then
    unset password
    echo "Could not create Linux account." >&2
    return 1
  fi
  if ! printf '%s:%s\n' "$username" "$password" | chpasswd; then
    userdel --remove "$username" 2>/dev/null || true
    unset password
    echo "Password setup failed; account creation was rolled back." >&2
    return 1
  fi
  if (( days > 0 )); then
    if ! chage --expiredate "$expiry" "$username"; then
      userdel --remove "$username" 2>/dev/null || true
      unset password
      echo "Expiry setup failed; account creation was rolled back." >&2
      return 1
    fi
  fi
  echo
  echo "DNSTT customer SSH account created."
  printf 'Username: %s\n' "$username"
  if [[ "$password_mode" == 1 ]]; then
    printf 'Generated password (shown once): %s\n' "$password"
  else
    echo "Password: your chosen password has been set (not displayed)."
  fi
  printf 'Expires: %s\n' "${expiry:-Never}"
  echo "SSH host: this VPS public IP or configured SSH hostname"
  echo "SSH port: 22 (unless your sshd uses another port)"
  echo "The customer must use this SSH username/password, not the VPS root login."
  unset password
}

dt_accounts_list() {
  dt_require_root || return 1
  local members username status
  members="$(getent group "$DT_GROUP" | awk -F: '{print $4}' | tr ',' ' ')"
  if [[ -z "${members// /}" ]]; then
    echo "No DNSTT customer accounts have been created."
    return 0
  fi
  printf '%-22s %-24s %-12s\n' "USERNAME" "EXPIRY" "PASSWORD"
  for username in $members; do
    id "$username" >/dev/null 2>&1 || continue
    status="$(passwd -S "$username" 2>/dev/null | awk '{print $2}')"
    printf '%-22s %-24s %-12s\n' "$username" "$(dt_expiry_label "$username")" "${status:-unknown}"
  done
}

dt_accounts_manage() {
  dt_require_root || return 1
  local username action days expiry password
  read -r -p "DNSTT customer username: " username
  dt_valid_username "$username" || { echo "Invalid username." >&2; return 1; }
  id "$username" >/dev/null 2>&1 || { echo "User does not exist." >&2; return 1; }
  id -nG "$username" | tr ' ' '\n' | grep -qx "$DT_GROUP" || {
    echo "That user is not managed as a DNSTT customer." >&2
    return 1
  }
  echo "1) Renew/set expiry  2) Disable account  3) Re-enable account  4) Reset password  5) Delete account"
  read -r -p "Select: " action
  case "$action" in
    1|3)
      read -r -p "Validity from today in days (1-36500, 0 = never): " days
      [[ "$days" =~ ^[0-9]+$ ]] && (( days <= 36500 )) || { echo "Enter 0-36500 days." >&2; return 1; }
      expiry=""
      if (( days > 0 )); then expiry="$(date -d "+${days} days" +%F)" || return 1; fi
      if [[ "$action" == 3 ]]; then usermod --unlock "$username" || return 1; fi
      chage --expiredate "${expiry}" "$username" || return 1
      echo "Account $username expiry updated: ${expiry:-Never}."
      ;;
    2)
      usermod --lock --expiredate 1970-01-02 "$username" && echo "Account $username disabled."
      ;;
    4)
      password="$(openssl rand -hex 16)" || return 1
      printf '%s:%s\n' "$username" "$password" | chpasswd || { unset password; return 1; }
      printf 'New password for %s (shown once): %s\n' "$username" "$password"
      unset password
      ;;
    5)
      read -r -p "Permanently delete $username and its home directory? [y/N]: " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || return 0
      userdel --remove "$username" && echo "Account $username deleted."
      ;;
    *) echo "Invalid choice." >&2; return 1 ;;
  esac
}

dt_client_help() {
  dt_read_domain || return 1
  [[ -s "$DT_PUBLIC_KEY" ]] || { echo "DNSTT public key is missing; install DNSTT first." >&2; return 1; }
  local mode resolver option
  echo "Choose the recursive DNS resolver used by dnstt-client:"
  echo "1) UDP resolver (default: 8.8.8.8:53)"
  echo "2) Custom UDP resolver (hostname-or-IP:port)"
  echo "3) DNS-over-TLS resolver (hostname:port)"
  echo "4) DNS-over-HTTPS resolver (https:// URL)"
  read -r -p "Resolver type [1-4]: " mode
  case "$mode" in
    1) resolver="8.8.8.8:53"; option="-udp" ;;
    2)
      read -r -p "Custom UDP resolver address (e.g. 1.1.1.1:53 or dns.example.net:53): " resolver
      [[ "$resolver" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || { echo "Enter hostname-or-IPv4:port." >&2; return 1; }
      local port="${resolver##*:}"
      (( 10#$port >= 1 && 10#$port <= 65535 )) || { echo "Resolver port must be 1-65535." >&2; return 1; }
      option="-udp"
      ;;
    3)
      read -r -p "DoT resolver address (e.g. dns.google:853): " resolver
      [[ "$resolver" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || { echo "Enter hostname:port." >&2; return 1; }
      local dot_port="${resolver##*:}"
      (( 10#$dot_port >= 1 && 10#$dot_port <= 65535 )) || { echo "Resolver port must be 1-65535." >&2; return 1; }
      option="-dot"
      ;;
    4)
      read -r -p "DoH URL (e.g. https://dns.google/dns-query): " resolver
      [[ "$resolver" == https://* && "$resolver" != *[[:space:]]* ]] || { echo "Enter an https:// URL." >&2; return 1; }
      option="-doh"
      ;;
    *) echo "Invalid resolver type." >&2; return 1 ;;
  esac
  echo
  echo "DNSTT client command (run on a compatible client with dnstt-client installed):"
  printf 'dnstt-client %s %q -pubkey-file server.pub %q 127.0.0.1:7001\n' "$option" "$resolver" "$DT_DOMAIN"
  echo
  echo "Resolver: $resolver"
  echo "Tunnel domain: $DT_DOMAIN"
  echo "The resolver above is the recursive DNS server queried by the client."
  echo "The authoritative nameserver hostname is configured separately in your DNS delegation."
  echo "The DNSTT public key authenticates the tunnel server; SSH username/password authenticates each customer."
  echo "For SSH, connect through the local listener using the customer's SSH account, never root."
  echo
  echo "Public DNSTT key:"
  cat "$DT_PUBLIC_KEY"
}

dnstt_users_menu() {
  while true; do
    echo
    echo "----- DNSTT Customer Accounts / DNS Resolver -----"
    echo "1) Create customer SSH username/password with expiry"
    echo "2) List DNSTT customer accounts"
    echo "3) Manage / renew / disable / reset / delete account"
    echo "4) Show client command with custom DNS resolver"
    echo "0) Back"
    read -r -p "Select: " choice
    case "$choice" in
      1) dt_accounts_create ;;
      2) dt_accounts_list ;;
      3) dt_accounts_manage ;;
      4) dt_client_help ;;
      0) return ;;
      *) echo "Invalid choice." ;;
    esac
  done
}
