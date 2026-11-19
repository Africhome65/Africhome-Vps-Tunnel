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

dt_valid_host() {
  local value="$1" octet
  local -a octets
  [[ -n "$value" && ${#value} -le 253 ]] || return 1
  if [[ "$value" =~ ^[0-9.]+$ ]]; then
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$value"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
      (( 10#$octet <= 255 )) || return 1
    done
    return 0
  fi
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

dt_read_domain() {
  [[ -f "$DT_DOMAIN_CONFIG" && ! -L "$DT_DOMAIN_CONFIG" && "$(stat -c '%u:%a' "$DT_DOMAIN_CONFIG" 2>/dev/null || true)" == "0:600" ]] || {
    echo "DNSTT domain config must be a root-owned regular file with mode 0600." >&2
    return 1
  }
  DT_DOMAIN="$(sed -n 's/^DNS_DOMAIN=//p' "$DT_DOMAIN_CONFIG" | head -n1)"
  [[ "$DT_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ && ${#DT_DOMAIN} -le 253 ]] || {
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
      read -r -s -p "Enter your password (input hidden): " password
      echo
      read -r -s -p "Confirm your password: " password_confirm
      echo
      [[ -n "$password" && "$password" != *:* && "$password" == "$password_confirm" ]] || {
        unset password password_confirm
        echo "Passwords must match, be non-empty, and must not contain a colon." >&2
        return 1
      }
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
    echo "Your chosen password was set successfully and was not echoed."
  fi
  printf 'Expires: %s\n' "${expiry:-Never}"
  echo "DNSTT SSH upstream (server-side): 127.0.0.1:22 by default."
  echo "After dnstt-client connects, the customer SSH client target is 127.0.0.1:7001."
  echo "The customer must use this SSH username/password, not the VPS root login."
  unset password
}


dt_trial_account_create() {
  dt_require_root || return 1
  command -v systemctl >/dev/null 2>&1 || { echo "systemd is required for timed trial expiry." >&2; return 1; }

  local hours username password expiry_at service_file timer_file service_tmp timer_tmp path
  echo "Trial duration:"
  echo "1) 1 hour"
  echo "2) 3 hours"
  echo "3) 6 hours"
  echo "4) 24 hours"
  read -r -p "Choose trial duration [1-4]: " choice
  case "$choice" in
    1) hours=1 ;;
    2) hours=3 ;;
    3) hours=6 ;;
    4) hours=24 ;;
    *) echo "Invalid trial duration." >&2; return 1 ;;
  esac

  while :; do
    username="trial$(openssl rand -hex 3)" || return 1
    id "$username" >/dev/null 2>&1 || break
  done
  password="$(openssl rand -hex 8)" || return 1
  expiry_at="$(date -d "+${hours} hours" '+%Y-%m-%d %H:%M:%S')" || return 1
  service_file="/etc/systemd/system/africhome-trial-${username}.service"
  timer_file="/etc/systemd/system/africhome-trial-${username}.timer"
  service_tmp=""
  timer_tmp=""
  for path in "$service_file" "$timer_file"; do
    [[ ! -e "$path" && ! -L "$path" ]] || {
      echo "Refusing to overwrite an existing trial unit path: $path" >&2
      return 1
    }
  done

  if ! useradd --create-home --shell /bin/bash --groups "$DT_GROUP" "$username"; then
    unset password
    echo "Could not create trial account." >&2
    return 1
  fi
  if ! printf '%s:%s\n' "$username" "$password" | chpasswd; then
    userdel --remove "$username" 2>/dev/null || true
    unset password
    echo "Trial password setup failed; account rolled back." >&2
    return 1
  fi

  service_tmp="$(mktemp "/etc/systemd/system/africhome-trial-${username}.XXXXXX.service")" || {
    userdel --remove "$username" 2>/dev/null || true
    unset password
    return 1
  }
  timer_tmp="$(mktemp "/etc/systemd/system/africhome-trial-${username}.XXXXXX.timer")" || {
    rm -f -- "$service_tmp"
    userdel --remove "$username" 2>/dev/null || true
    unset password
    return 1
  }
  cat > "$service_tmp" <<EOF
[Unit]
Description=Expire Africhome DNSTT trial account $username

[Service]
Type=oneshot
ExecStart=/usr/sbin/usermod --lock --expiredate=1970-01-02 $username
ExecStartPost=-/usr/bin/pkill -KILL -u $username
EOF
  cat > "$timer_tmp" <<EOF
[Unit]
Description=Timed expiry for Africhome DNSTT trial account $username

[Timer]
OnCalendar=$expiry_at
Persistent=true
Unit=africhome-trial-$username.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$service_tmp" "$timer_tmp"
  chown root:root "$service_tmp" "$timer_tmp"

  if ! systemd-analyze verify "$service_tmp" "$timer_tmp" >/dev/null 2>&1 ||
     ! mv -T -- "$service_tmp" "$service_file" ||
     ! mv -T -- "$timer_tmp" "$timer_file" ||
     ! systemctl daemon-reload ||
     ! systemctl enable --now "africhome-trial-$username.timer"; then
    rm -f -- "$service_tmp" "$timer_tmp" "$service_file" "$timer_file"
    systemctl daemon-reload >/dev/null 2>&1 || true
    userdel --remove "$username" 2>/dev/null || true
    unset password
    echo "Could not schedule automatic trial expiry; account creation was rolled back." >&2
    return 1
  fi

  echo
  echo "Africhome DNSTT trial account created."
  printf 'Username: %s\n' "$username"
  printf 'Password (copy it now): %s\n' "$password"
  printf 'Trial duration: %s hour(s)\n' "$hours"
  printf 'Automatic expiry: %s (VPS local time)\n' "$expiry_at"
  echo "The account will be locked and its active SSH sessions terminated at expiry."
  echo "DNSTT SSH upstream (server-side): 127.0.0.1:22 by default."
  echo "After dnstt-client connects, the customer SSH client target is 127.0.0.1:7001."
  unset password
}

dt_trial_timer_cleanup() {
  local username="$1"
  local service_file="/etc/systemd/system/africhome-trial-${username}.service"
  local timer_file="/etc/systemd/system/africhome-trial-${username}.timer"
  local unit_name="africhome-trial-${username}.timer"
  local service_name="africhome-trial-${username}.service" path

  # These paths are derived only from a validated Linux username. Never
  # follow or remove a symlink if an administrator has replaced a unit.
  for path in "$service_file" "$timer_file"; do
    [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) ]] || {
      echo "Refusing to remove an unsafe trial unit path: $path" >&2
      return 1
    }
  done
  if [[ -e "$service_file" || -e "$timer_file" ]]; then
    command -v systemctl >/dev/null 2>&1 || {
      echo "systemctl is required to safely cancel this trial timer." >&2
      return 1
    }
    systemctl disable --now "$unit_name" >/dev/null 2>&1 || {
      echo "Could not disable the trial timer $unit_name." >&2
      return 1
    }
    systemctl stop "$service_name" >/dev/null 2>&1 || true
    rm -f -- "$service_file" "$timer_file"
    systemctl daemon-reload || return 1
  fi
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
      if (( days > 0 )); then
        expiry="$(date -d "+${days} days" +%F)" || return 1
        chage --expiredate "$expiry" "$username" || return 1
      else
        chage --expiredate -1 "$username" || return 1
      fi
      dt_trial_timer_cleanup "$username" || return 1
      if [[ "$action" == 3 ]]; then usermod --unlock "$username" || return 1; fi
      echo "Account $username expiry updated: ${expiry:-Never}."
      ;;
    2)
      usermod --lock --expiredate 1970-01-02 "$username" || return 1
      dt_trial_timer_cleanup "$username" || return 1
      echo "Account $username disabled."
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
      dt_trial_timer_cleanup "$username" || return 1
      userdel --remove "$username" && echo "Account $username deleted."
      ;;
    *) echo "Invalid choice." >&2; return 1 ;;
  esac
}

dt_client_help() {
  dt_read_domain || return 1
  [[ -f "$DT_PUBLIC_KEY" && ! -L "$DT_PUBLIC_KEY" && -s "$DT_PUBLIC_KEY" && "$(stat -c '%u:%a' "$DT_PUBLIC_KEY" 2>/dev/null || true)" == "0:644" ]] || { echo "DNSTT public key must be a root-owned regular file with mode 0644; install DNSTT first." >&2; return 1; }
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
      [[ "$resolver" == *:* ]] && dt_valid_host "${resolver%:*}" && [[ "${resolver##*:}" =~ ^[0-9]{1,5}$ ]] || { echo "Enter a valid hostname-or-IPv4:port." >&2; return 1; }
      local port="${resolver##*:}"
      (( 10#$port >= 1 && 10#$port <= 65535 )) || { echo "Resolver port must be 1-65535." >&2; return 1; }
      option="-udp"
      ;;
    3)
      read -r -p "DoT resolver address (e.g. dns.google:853): " resolver
      [[ "$resolver" == *:* ]] && dt_valid_host "${resolver%:*}" && [[ "${resolver##*:}" =~ ^[0-9]{1,5}$ ]] || { echo "Enter a valid hostname:port." >&2; return 1; }
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


dt_config_export() {
  dt_require_root || return 1
  dt_read_domain || return 1
  [[ -f "$DT_PUBLIC_KEY" && ! -L "$DT_PUBLIC_KEY" && -s "$DT_PUBLIC_KEY" && "$(stat -c '%u:%a' "$DT_PUBLIC_KEY" 2>/dev/null || true)" == "0:644" ]] || { echo "DNSTT public key must be a root-owned regular file with mode 0644; install DNSTT first." >&2; return 1; }

  local username resolver mode option ssh_host ssh_port entered export_root export_dir config_file archive_file expiry
  read -r -p "DNSTT customer username: " username
  dt_valid_username "$username" || { echo "Invalid username." >&2; return 1; }
  id "$username" >/dev/null 2>&1 || { echo "User does not exist." >&2; return 1; }
  id -nG "$username" | tr ' ' '\n' | grep -qx "$DT_GROUP" || {
    echo "That user is not managed as a DNSTT customer." >&2
    return 1
  }
  [[ "$(passwd -S "$username" 2>/dev/null | awk '{print $2}')" == "P" ]] || {
    echo "This account does not currently have an active password. Reset/set its password first." >&2
    return 1
  }

  ssh_host="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  read -r -p "SSH host (public VPS IP or hostname) [${ssh_host:-required}]: " entered
  ssh_host="${entered:-$ssh_host}"
  dt_valid_host "$ssh_host" || {
    echo "Enter a valid public IP address or hostname." >&2
    return 1
  }
  ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"
  ssh_port="${ssh_port:-22}"
  read -r -p "SSH port [${ssh_port}]: " entered
  ssh_port="${entered:-$ssh_port}"
  [[ "$ssh_port" =~ ^[0-9]{1,5}$ ]] && (( 10#$ssh_port >= 1 && 10#$ssh_port <= 65535 )) || {
    echo "SSH port must be between 1 and 65535." >&2
    return 1
  }

  echo "Choose the recursive DNS resolver for dnstt-client:"
  echo "1) UDP resolver (8.8.8.8:53)"
  echo "2) Custom UDP resolver (hostname-or-IP:port)"
  echo "3) DNS-over-TLS resolver (hostname:port)"
  echo "4) DNS-over-HTTPS resolver (https:// URL)"
  read -r -p "Resolver type [1-4]: " mode
  case "$mode" in
    1) resolver="8.8.8.8:53"; option="-udp" ;;
    2)
      read -r -p "Custom UDP resolver address (hostname-or-IP:port): " resolver
      [[ "$resolver" == *:* ]] && dt_valid_host "${resolver%:*}" && [[ "${resolver##*:}" =~ ^[0-9]{1,5}$ ]] || { echo "Enter a valid hostname-or-IP:port." >&2; return 1; }
      local udp_port="${resolver##*:}"
      (( 10#$udp_port >= 1 && 10#$udp_port <= 65535 )) || { echo "Resolver port must be 1-65535." >&2; return 1; }
      option="-udp"
      ;;
    3)
      read -r -p "DoT resolver address (hostname:port): " resolver
      [[ "$resolver" == *:* ]] && dt_valid_host "${resolver%:*}" && [[ "${resolver##*:}" =~ ^[0-9]{1,5}$ ]] || { echo "Enter a valid hostname:port." >&2; return 1; }
      local dot_port="${resolver##*:}"
      (( 10#$dot_port >= 1 && 10#$dot_port <= 65535 )) || { echo "Resolver port must be 1-65535." >&2; return 1; }
      option="-dot"
      ;;
    4)
      read -r -p "DoH URL (https:// URL): " resolver
      [[ "$resolver" == https://* && "$resolver" != *[[:space:]]* ]] || { echo "Enter a valid https:// URL." >&2; return 1; }
      option="-doh"
      ;;
    *) echo "Invalid resolver type." >&2; return 1 ;;
  esac

  export_root="/root/africhome-client-configs"
  export_dir="$export_root/$username"
  config_file="$export_dir/$username-dnstt.txt"
  archive_file="$export_dir/$username-dnstt-config.tar.gz"
  install -d -m 700 "$export_root" "$export_dir" || return 1
  cp "$DT_PUBLIC_KEY" "$export_dir/server.pub" || return 1
  chmod 644 "$export_dir/server.pub"
  expiry="$(dt_expiry_label "$username")"

  cat > "$config_file" <<EOF
AFRICHOME VPS TUNNEL - CUSTOMER DNSTT CONFIGURATION
===================================================
Username: $username
Password: Enter the password supplied separately by the server administrator.
Account expiry: $expiry

DIRECT SSH FALLBACK HOST (not used by DNSTT): $ssh_host
DIRECT SSH FALLBACK PORT (not used by DNSTT): $ssh_port
SSH USERNAME: $username

AFTER DNSTT CONNECTS, SSH CLIENT TARGET: 127.0.0.1:7001

RECURSIVE DNS RESOLVER: $resolver
DNSTT TUNNEL DOMAIN: $DT_DOMAIN
DNSTT PUBLIC KEY FILE: server.pub
DNSTT PUBLIC KEY:
$(cat "$DT_PUBLIC_KEY")

DNSTT CLIENT COMMAND (run on a compatible device with dnstt-client installed):
dnstt-client $option "$resolver" -pubkey-file server.pub "$DT_DOMAIN" 127.0.0.1:7001

After the DNSTT client reports that its local listener is ready, configure your SSH client to connect to 127.0.0.1 port 7001 using the customer username and password. The direct SSH fallback host/port above are not the DNSTT connection target.
The recursive resolver is not the authoritative nameserver. DNS delegation is configured separately on the domain.

IMPORTANT:
- This is a generic DNSTT client profile, not a verified ZIVPN import file.
- Use only a client application/mode that explicitly supports DNSTT.
- The SSH password is not stored in this export; obtain it separately from the administrator.
- Never share the DNSTT server private key. The included server.pub is public.
EOF
  chmod 600 "$config_file"
  tar -czf "$archive_file" -C "$export_dir" "$username-dnstt.txt" server.pub || return 1
  chmod 600 "$archive_file"

  echo
  echo "Customer configuration export created."
  printf 'Text configuration: %s\n' "$config_file"
  printf 'Bundle (TXT + server.pub): %s\n' "$archive_file"
  echo "The export contains no SSH password or DNSTT private key."
  echo "Use an authorized secure file-transfer method to deliver the bundle."
}


dnstt_users_menu() {
  while true; do
    echo
    echo "----- DNSTT Customer Accounts / DNS Resolver -----"
    echo "1) Create customer SSH username/password with expiry"
    echo "5) Generate timed trial account (1/3/6/24 hours)"
    echo "2) List DNSTT customer accounts"
    echo "3) Manage / renew / disable / reset / delete account"
    echo "4) Show client command with custom DNS resolver"
    echo "6) Generate customer configuration export (TXT + public key)"
    echo "0) Back"
    read -r -p "Select: " choice
    case "$choice" in
      1) dt_accounts_create ;;
      2) dt_accounts_list ;;
      3) dt_accounts_manage ;;
      4) dt_client_help ;;
      5) dt_trial_account_create ;;
      6) dt_config_export ;;
      0) return ;;
      *) echo "Invalid choice." ;;
    esac
  done
}
