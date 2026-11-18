#!/usr/bin/env bash
# Iodine-based DNS tunnel with managed SSH customer accounts.
set -Eeuo pipefail

SD_ENV="/etc/africhome-slowdns.env"
SD_UNIT="/etc/systemd/system/africhome-slowdns.service"
SD_SERVER_IP="10.77.0.1/24"
SD_GROUP="africhome-slowdns"
SD_SPEED_MTU="1130"
SD_ACCOUNTS_DIR="/etc/africhome/slowdns-accounts"

sd_valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

sd_install() {
  ah_require_root || return 1
  ah_apt_install iodine openssh-client openssl dnsutils curl || return 1
  ah_ok "Iodine, SSH client and password generator installed."
}

# Check public DNS before starting iodine. The NS hostname may use any valid
# label (including ns-, ns1-, dns-, etc.); it is compared as a DNS name.
sd_dns_check() {
  local domain="$1" ns_host="$2"
  local a_records ns_records normalized_ns public_ip
  if ! command -v dig >/dev/null 2>&1; then
    ah_warn "dig is unavailable; install dnsutils to verify DNS."
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    ah_warn "curl is unavailable; install curl to detect this VPS public IPv4."
    return 1
  fi

  # Use the VPS's own detected public IPv4 and the system-configured DNS
  # resolver. No provider-specific resolver or administrator IP is hardcoded.
  public_ip="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [[ ! "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    ah_err "Could not detect this VPS public IPv4. Check outbound internet access and retry."
    return 1
  fi
  a_records="$(dig +time=4 +tries=1 +short A "$ns_host" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/')"
  ns_records="$(dig +time=4 +tries=1 +short NS "$domain" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"
  normalized_ns="$(printf '%s' "$ns_host" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"

  if [[ -z "$a_records" ]]; then
    ah_err "DNS check failed: $ns_host has no visible IPv4 A record."
    return 1
  fi
  if ! printf '%s\n' "$a_records" | grep -Fxq "$public_ip"; then
    ah_err "DNS check failed: $ns_host does not point to this VPS public IPv4 ($public_ip)."
    echo "  A record address(es) returned: $(printf '%s' "$a_records" | paste -sd, -)"
    return 1
  fi
  if ! printf '%s\n' "$ns_records" | grep -Fxq "$normalized_ns"; then
    ah_err "DNS check failed: $domain is not publicly delegated to $ns_host."
    if [[ -n "$ns_records" ]]; then
      echo "  NS record target(s) returned:"
      printf '  %s\n' "$ns_records"
    else
      echo "  No public NS records were returned for $domain."
    fi
    return 1
  fi
  ah_ok "A record matches this VPS public IPv4: $ns_host -> $public_ip"
  ah_ok "$domain is delegated to $ns_host."
}

sd_setup() {
  ah_require_root || return 1
  command -v iodined >/dev/null 2>&1 || { ah_warn "Install SlowDNS packages first."; return 1; }

  local old_domain="" old_password="" domain ns_host password ready
  if [[ -f "$SD_ENV" ]]; then
    # Read the existing file as data only; never source an administrator-editable file.
    old_domain="$(sed -n 's/^DNS_DOMAIN=//p' "$SD_ENV" | head -n1)"
    old_password="$(sed -n 's/^DNS_PASSWORD=//p' "$SD_ENV" | head -n1)"
    ah_warn "A SlowDNS configuration already exists."
    read -r -p "Replace its domain/nameserver settings? The existing tunnel will be stopped. [y/N]: " replace
    [[ "$replace" =~ ^[Yy]$ ]] || return 0
  fi

  if command -v ss >/dev/null 2>&1 && ss -lun | awk '$5 ~ /:53$/ {found=1} END {exit !found}'; then
    # Allow replacement only when our own service is the listener.
    if ! systemctl is-active --quiet africhome-slowdns; then
      ah_err "UDP port 53 is already in use by another service. Identify it before continuing."
      return 1
    fi
  fi

  # Each administrator supplies their own tunnel domain and nameserver host.
  # The tunnel subdomain is the NS record NAME; the nameserver host is the A record NAME.
  read -r -p "Tunnel subdomain (NS record NAME, e.g. tunnel.example.com): " domain
  sd_valid_domain "$domain" || { ah_err "Enter a valid fully-qualified tunnel subdomain."; return 1; }
  read -r -p "Nameserver host (A record NAME, e.g. ns-tunnel.example.com): " ns_host
  sd_valid_domain "$ns_host" || { ah_err "Enter a valid fully-qualified nameserver hostname."; return 1; }

  if [[ -n "$old_password" ]]; then
    read -r -s -p "Keep the existing shared tunnel password? [Y/n]: " keep
    echo
    if [[ ! "$keep" =~ ^[Nn]$ ]]; then
      password="$old_password"
    else
      read -r -s -p "New shared tunnel password (12-32 chars): " password
      echo
    fi
  else
    read -r -s -p "Create shared tunnel password (12-32 chars): " password
    echo
  fi
  [[ "$password" =~ ^[A-Za-z0-9_-]{12,32}$ ]] || { unset password; ah_err "Use 12-32 letters, numbers, underscore or dash."; return 1; }

  if [[ -f "$SD_ENV" ]]; then
    systemctl disable --now africhome-slowdns 2>/dev/null || true
    cp -a "$SD_ENV" "${SD_ENV}.backup.$(date +%Y%m%d%H%M%S)"
  fi
  install -d -m 700 /etc/africhome
  umask 077
  {
    printf 'DNS_DOMAIN=%s\n' "$domain"
    printf 'DNS_NS_HOST=%s\n' "$ns_host"
    printf 'DNS_PASSWORD=%s\n' "$password"
  } > "$SD_ENV"
  chmod 600 "$SD_ENV"
  unset password

  cat > "$SD_UNIT" <<'EOF'
[Unit]
Description=Africhome SlowDNS (iodine) tunnel server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/africhome-slowdns.env
ExecStart=/bin/bash -c 'exec /usr/sbin/iodined -f -m 1130 -P "$DNS_PASSWORD" 10.77.0.1/24 "$DNS_DOMAIN"'
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SD_UNIT"
  systemctl daemon-reload
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow 53/udp || ah_warn "Could not add UDP 53 to UFW; open it manually."
  fi

  ah_info "DNS records expected by this SlowDNS configuration:"
  echo "  A record:  $ns_host -> this VPS public IPv4 (DNS-only)"
  echo "  NS record: $domain -> $ns_host"
  echo "  Both records must be in the parent zone managed by your DNS provider."
  echo "  Firewall: allow UDP 53 at the VPS provider and UFW"
  echo "  Do not proceed until the records are saved and have propagated."
  read -r -p "Have you completed and opened UDP 53? Run public DNS verification now? [Y/n]: " ready
  if [[ ! "$ready" =~ ^[Nn]$ ]]; then
    sd_dns_check "$domain" "$ns_host" || {
      ah_warn "DNS verification did not pass. Configuration is saved, but the service will not be started."
      return 1
    }
    systemctl enable --now africhome-slowdns
    if systemctl is-active --quiet africhome-slowdns; then
      ah_ok "SlowDNS service is running."
    else
      ah_err "SlowDNS did not start. Check option 5 (status and logs)."
      return 1
    fi
  else
    ah_warn "Configuration saved; service not started. Complete DNS delegation, then use Start service."
  fi
}

sd_domain_info() {
  if [[ ! -r "$SD_ENV" ]]; then ah_warn "Configure the SlowDNS server first."; return 1; fi
  local domain ns
  domain="$(sed -n 's/^DNS_DOMAIN=//p' "$SD_ENV" | head -n1)"
  ns="$(sed -n 's/^DNS_NS_HOST=//p' "$SD_ENV" | head -n1)"
  echo "Tunnel domain: ${domain:-not set}"
  echo "Nameserver host: ${ns:-not set}"
  echo "Tunnel IP: $SD_SERVER_IP"
  echo "Tunnel password: stored securely (not displayed)"
}

sd_accounts_create() {
  ah_require_root || return 1
  [[ -r "$SD_ENV" ]] || { ah_warn "Configure the SlowDNS domain first."; return 1; }
  local username kind days expiry password public_key key_choice key_enabled=0
  read -r -p "New customer username (lowercase, digits, _ or -): " username
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ah_err "Invalid username."; return 1; }
  id "$username" >/dev/null 2>&1 && { ah_err "That Linux username already exists."; return 1; }

  echo "Account type: 1) Trial (default 1 day)  2) Normal (choose duration)"
  read -r -p "Select account type [1/2]: " kind
  case "$kind" in
    1) days=1; read -r -p "Trial duration in days [1]: " entered; [[ -n "$entered" ]] && days="$entered" ;;
    2) read -r -p "Normal account duration in days: " days ;;
    *) ah_err "Choose 1 or 2."; return 1 ;;
  esac
  [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 1 && days <= 36500 )) || { ah_err "Enter 1-36500 days."; return 1; }
  expiry="$(date -d "+${days} days" +%F)" || { ah_err "Could not calculate expiry."; return 1; }

  getent group "$SD_GROUP" >/dev/null || groupadd --system "$SD_GROUP"
  install -d -m 700 "$SD_ACCOUNTS_DIR"
  useradd --create-home --shell /bin/bash --groups "$SD_GROUP" "$username" || { ah_err "Could not create Linux account."; return 1; }
  password="$(openssl rand -hex 10)"
  if ! printf '%s:%s\n' "$username" "$password" | chpasswd || ! chage --expiredate "$expiry" "$username"; then
    userdel --remove "$username" 2>/dev/null || true
    unset password
    ah_err "Account setup failed; partial account was removed."
    return 1
  fi
  # Generate a fresh Ed25519 keypair for the customer by default. The public
  # key is installed in authorized_keys; the private key is displayed once and
  # never saved in the account directory or repository.
  read -r -p "Generate an SSH keypair for this customer now? [Y/n]: " key_choice
  if [[ ! "$key_choice" =~ ^[Nn]$ ]]; then
    local key_tmp
    key_tmp="$(mktemp -d /run/africhome-slowdns-key.XXXXXX)" || {
      userdel --remove "$username" 2>/dev/null || true
      unset password
      ah_err "Could not create a secure temporary directory for the SSH key."
      return 1
    }
    chmod 700 "$key_tmp"
    if ssh-keygen -q -t ed25519 -N "" -C "$username@africhome-slowdns" -f "$key_tmp/id_ed25519"; then
      public_key="$(cat "$key_tmp/id_ed25519.pub")"
      install -d -m 700 -o "$username" -g "$username" "/home/$username/.ssh"
      printf '%s\n' "$public_key" > "/home/$username/.ssh/authorized_keys"
      chown "$username:$username" "/home/$username/.ssh/authorized_keys"
      chmod 600 "/home/$username/.ssh/authorized_keys"
      echo
      key_enabled=1
      ah_ok "SSH keypair generated and public key installed for $username."
      echo "PRIVATE SSH KEY — copy it now and keep it secret:"
      cat "$key_tmp/id_ed25519"
      echo
      echo "PUBLIC SSH KEY:"
      printf '%s\n' "$public_key"
      echo
      echo "The private key is not saved on this VPS. Import it into the customer's SSH client."
      rm -rf -- "$key_tmp"
    else
      rm -rf -- "$key_tmp"
      userdel --remove "$username" 2>/dev/null || true
      unset password
      ah_err "SSH key generation failed. Account creation was rolled back."
      return 1
    fi
  else
    read -r -p "Paste customer's one-line SSH public key (leave blank to skip): " public_key
    if [[ -n "$public_key" ]]; then
      if ssh-keygen -lf <(printf '%s\n' "$public_key") >/dev/null 2>&1; then
        install -d -m 700 -o "$username" -g "$username" "/home/$username/.ssh"
        printf '%s\n' "$public_key" > "/home/$username/.ssh/authorized_keys"
        chown "$username:$username" "/home/$username/.ssh/authorized_keys"
        chmod 600 "/home/$username/.ssh/authorized_keys"
        key_enabled=1
        ah_ok "SSH public key installed for $username."
      else
        userdel --remove "$username" 2>/dev/null || true
        unset password
        ah_err "Invalid public key. Account creation was rolled back."
        return 1
      fi
    fi
  fi

  # again from the management menu. It is never committed to the repository.
  umask 077
  {
    printf "USERNAME=%s\n" "$username"
    printf "PASSWORD=%s\n" "$password"
    printf "EXPIRY=%s\n" "$expiry"
  } > "$SD_ACCOUNTS_DIR/$username.cred"
  chmod 600 "$SD_ACCOUNTS_DIR/$username.cred"

  local domain ns
  domain="$(sed -n 's/^DNS_DOMAIN=//p' "$SD_ENV" | head -n1)"
  ns="$(sed -n 's/^DNS_NS_HOST=//p' "$SD_ENV" | head -n1)"
  echo
  ah_ok "SlowDNS SSH account created."
  echo "========================================"
  echo "       COPY SLOWDNS ACCOUNT LOGIN"
  echo "========================================"
  printf 'USERNAME: %s\n' "$username"
  printf 'PASSWORD: %s\n' "$password"
  echo "========================================"
  echo "Account type: $([[ "$kind" == 1 ]] && echo Trial || echo Normal)"
  echo "Expires: $expiry"
  echo
  echo "CLIENT CONNECTION DETAILS"
  echo "Tunnel subdomain (NS record name): $domain"
  echo "Nameserver host (A record name): $ns"
  echo "Tunnel command (iodine shared tunnel password required): sudo iodine -f -L 1 -M 255 $domain"
  echo "Then connect: ssh $username@10.77.0.1"
  if (( key_enabled )); then
    echo "SSH public-key login: enabled; customer must use the matching private key on their device."
  else
    echo "SSH public-key login: not configured; use the generated SSH password."
  fi
  echo "Keep the SSH password private. Give the shared iodine password to authorised customers only."
  echo
  echo "Credentials are also saved root-only at: $SD_ACCOUNTS_DIR/$username.cred"
  echo "Use SlowDNS option 12 to display this account again for copying."
  unset password
  ah_warn "SSH password authentication must be enabled in your sshd policy for password login to work."
}

sd_accounts_list() {
  ah_require_root || return 1
  if ! getent group "$SD_GROUP" >/dev/null; then ah_info "No Africhome SlowDNS customer accounts yet."; return 0; fi
  printf '%-22s %-12s %-14s %-12s\n' USERNAME TYPE REMAINING STATUS
  local members name expiry status
  members="$(getent group "$SD_GROUP" | awk -F: '{print $4}' | tr ',' ' ')"
  for name in $members; do
    id "$name" >/dev/null 2>&1 || continue
    expiry="$(chage -l "$name" 2>/dev/null | awk -F': ' '/Account expires/{print $2}')"
    if [[ "$expiry" == "never" || "$expiry" == "Never" ]]; then expiry="Never"
    elif [[ -n "$expiry" ]]; then
      local expiry_ts now
      expiry_ts="$(date -d "$expiry" +%s 2>/dev/null || echo 0)"; now="$(date +%s)"
      if (( expiry_ts == 0 )); then expiry="Unknown"
      elif (( expiry_ts <= now )); then expiry="Expired"
      else expiry="$(( (expiry_ts - now + 86399) / 86400 )) days"; fi
    else expiry="Unknown"; fi
    status="$(passwd -S "$name" 2>/dev/null | awk '{print $2}')"
    printf '%-22s %-12s %-14s %-12s\n' "$name" "Managed" "$expiry" "${status:-unknown}"
  done
}

sd_accounts_credentials() {
  ah_require_root || return 1
  [[ -d "$SD_ACCOUNTS_DIR" ]] || { ah_warn "No saved SlowDNS credentials found."; return 1; }
  local username cred saved_user saved_pass saved_expiry
  read -r -p "Customer username: " username
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { ah_err "Invalid username."; return 1; }
  cred="$SD_ACCOUNTS_DIR/$username.cred"
  if [[ ! -r "$cred" ]]; then
    ah_warn "No saved password is available for $username. Passwords created before this update cannot be recovered."
    return 1
  fi
  saved_user="$(sed -n 's/^USERNAME=//p' "$cred" | head -n1)"
  saved_pass="$(sed -n 's/^PASSWORD=//p' "$cred" | head -n1)"
  saved_expiry="$(sed -n 's/^EXPIRY=//p' "$cred" | head -n1)"
  echo
  echo "========================================"
  echo "       COPY SLOWDNS ACCOUNT LOGIN"
  echo "========================================"
  printf 'USERNAME: %s\n' "$saved_user"
  printf 'PASSWORD: %s\n' "$saved_pass"
  printf 'EXPIRES:  %s\n' "$saved_expiry"
  echo "========================================"
  echo
  ah_warn "Keep these credentials private."
}

sd_accounts_change() {
  ah_require_root || return 1
  local username days expiry
  read -r -p "Managed customer username: " username
  id "$username" >/dev/null 2>&1 || { ah_err "User does not exist."; return 1; }
  id -nG "$username" | tr ' ' '\n' | grep -qx "$SD_GROUP" || { ah_err "That user is not an Africhome SlowDNS account."; return 1; }
  echo "1) Renew/change expiry  2) Lock account  3) Unlock account  4) Delete account"
  read -r -p "Select: " action
  case "$action" in
    1)
      read -r -p "Additional days to add (1-36500): " days
      [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 1 && days <= 36500 )) || { ah_err "Enter 1-36500 days."; return 1; }
      local current_expiry base_date
      current_expiry="$(chage -l "$username" 2>/dev/null | awk -F': ' '/Account expires/{print $2}')"
      if [[ "$current_expiry" == "never" || "$current_expiry" == "Never" ]]; then
        base_date="$(date +%F)"
      else
        base_date="$current_expiry"
        [[ -n "$base_date" ]] || base_date="$(date +%F)"
        if ! date -d "$base_date" +%F >/dev/null 2>&1; then ah_err "Could not read current expiry."; return 1; fi
        if [[ "$(date -d "$base_date" +%s)" -lt "$(date +%s)" ]]; then base_date="$(date +%F)"; fi
      fi
      expiry="$(date -d "$base_date +${days} days" +%F)" || return 1
      chage --expiredate "$expiry" "$username" && ah_ok "Account $username renewed by $days day(s)."
      ;;
    2) passwd -l "$username" && ah_ok "Account locked: $username" ;;
    3) passwd -u "$username" && ah_ok "Account unlocked: $username" ;;
    4)
      read -r -p "Delete $username and its home directory? [y/N]: " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || return 0
      userdel --remove "$username" && ah_ok "Deleted $username"
      ;;
    *) ah_warn "Invalid choice." ;;
  esac
}

sd_status() {
  ah_require_root || return 1
  if [[ ! -f "$SD_UNIT" ]]; then
    if command -v iodined >/dev/null 2>&1; then
      ah_info "Iodine is installed, but the Africhome SlowDNS server is not configured yet."
      echo "Next step: choose option 2 (Configure tunnel DNS records)."
    else
      ah_warn "Iodine is not installed. Choose option 1 (Install iodine) first."
    fi
    return 0
  fi
  systemctl --no-pager --full status africhome-slowdns || true
  echo
  journalctl -u africhome-slowdns -n 20 --no-pager 2>/dev/null || true
}

sd_client_help() {
  [[ -r "$SD_ENV" ]] || { ah_warn "Configure the SlowDNS server first."; return 1; }
  local domain ns
  domain="$(sed -n 's/^DNS_DOMAIN=//p' "$SD_ENV" | head -n1)"
  ns="$(sed -n 's/^DNS_NS_HOST=//p' "$SD_ENV" | head -n1)"
  echo "Tunnel subdomain (NS record name): $domain"
  echo "Nameserver host (A record name): $ns"
  echo "Client command: sudo iodine -f -L 1 -M 255 $domain"
  echo "Then connect using a managed SSH username: ssh USERNAME@10.77.0.1"
  echo "The iodine password is shared by the tunnel and is stored in the root-only server config."
  echo "Individual SSH passwords and account expiry are managed separately in this menu."
  echo "Iodine lazy mode is enabled by default; -M 255 retains the maximum upstream hostname length."
}

sd_remove() {
  ah_require_root || return 1
  read -r -p "Remove the Africhome SlowDNS service and its saved tunnel password? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || return 0
  systemctl disable --now africhome-slowdns 2>/dev/null || true
  rm -f "$SD_UNIT" "$SD_ENV"
  systemctl daemon-reload
  ah_ok "SlowDNS service files removed. Customer Linux accounts were left unchanged."
}

slowdns_menu() {
  while true; do
    echo
    echo "----- SlowDNS SSH (iodine) -----"
    echo "1) Install iodine"
    echo "2) Configure tunnel DNS (NS subdomain + A nameserver)"
    echo "3) Start service"
    echo "4) Stop service"
    echo "5) Service status and logs"
    echo "6) Show client connection instructions"
    echo "7) Remove tunnel configuration"
    echo "8) Show configured domain/nameserver"
    echo "9) Create Trial/Normal customer account"
    echo "10) List customer accounts"
    echo "11) Manage/renew/lock/delete customer account"
    echo "12) Show customer username/password"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) sd_install; ah_pause ;;
      2) sd_setup; ah_pause ;;
      3)
        if ah_require_root && [[ -r "$SD_ENV" ]]; then
          domain="$(sed -n 's/^DNS_DOMAIN=//p' "$SD_ENV" | head -n1)"
          ns_host="$(sed -n 's/^DNS_NS_HOST=//p' "$SD_ENV" | head -n1)"
          if sd_dns_check "$domain" "$ns_host"; then systemctl enable --now africhome-slowdns; fi
        else
          ah_warn "Configure SlowDNS first (option 2)."
        fi
        ah_pause
        ;;
      4) ah_require_root && systemctl disable --now africhome-slowdns; ah_pause ;;
      5) sd_status; ah_pause ;;
      6) sd_client_help; ah_pause ;;
      7) sd_remove; ah_pause ;;
      8) sd_domain_info; ah_pause ;;
      9) sd_accounts_create; ah_pause ;;
      10) sd_accounts_list; ah_pause ;;
      11) sd_accounts_change; ah_pause ;;
      12) sd_accounts_credentials; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
