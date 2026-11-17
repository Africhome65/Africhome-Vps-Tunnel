#!/usr/bin/env bash
# Add, list, remove and expire individual VLESS, VMess and Trojan accounts.
set -Eeuo pipefail

PU_CONFIG="/usr/local/etc/xray/config.json"
PU_DB="/etc/africhome-protocol-users.json"
PU_LOCK="/run/lock/africhome-protocol-users.lock"

pu_require_tools() {
  command -v jq >/dev/null 2>&1 || ah_apt_install jq || return 1
  command -v xray >/dev/null 2>&1 || { ah_err "Install Xray first."; return 1; }
  [[ -s "$PU_CONFIG" ]] || { ah_err "Xray configuration not found."; return 1; }
  jq -e 'type == "object" and (.inbounds | type == "array")' "$PU_CONFIG" >/dev/null 2>&1 || { ah_err "Xray configuration is invalid or has no inbounds array."; return 1; }
  install -d -m 700 /etc/africhome
  [[ -e "$PU_DB" ]] || { printf '[]\n' > "$PU_DB"; chmod 600 "$PU_DB"; }
  jq -e 'type == "array"' "$PU_DB" >/dev/null 2>&1 || { ah_err "Protocol account database is invalid; refusing to overwrite it."; return 1; }
}

pu_lock() {
  command -v flock >/dev/null 2>&1 || { ah_err "flock is required."; return 1; }
  exec 9>"$PU_LOCK"
  flock -n 9 || { ah_warn "Another Africhome protocol account operation is running."; return 1; }
}

pu_add() {
  ah_require_root || return 1
  pu_require_tools || return 1
  pu_lock || return 1
  echo "Supported account types: VLESS, VMess, Trojan"
  read -r -p "Protocol [vless/vmess/trojan]: " protocol
  protocol="${protocol,,}"
  case "$protocol" in vless|vmess|trojan) ;; *) ah_err "Unsupported protocol."; return 1 ;; esac

  echo "Available $protocol inbounds:"
  jq -r --arg p "$protocol" '.inbounds[] | select(.protocol == $p) | "Port: \(.port)  Tag: \(.tag // "(untagged)")"' "$PU_CONFIG"
  read -r -p "Inbound port: " port
  [[ "$port" =~ ^[0-9]+$ ]] || { ah_err "Invalid port."; return 1; }
  jq -e --arg p "$protocol" --argjson port "$port" 'any(.inbounds[]; .protocol == $p and .port == $port)' "$PU_CONFIG" >/dev/null || { ah_err "That protocol and port are not configured."; return 1; }

  read -r -p "Account name (letters, numbers, dash, underscore): " username
  [[ "$username" =~ ^[A-Za-z0-9_-]{1,24}$ ]] || { ah_err "Invalid account name."; return 1; }
  local email credential expires expires_at backup tmp
  email="afh-${protocol}-${username}-$(date +%s)"
  if jq -e --arg e "$email" 'any(.[]; .email == $e)' "$PU_DB" >/dev/null; then
    ah_err "Account identifier already exists."; return 1
  fi
  case "$protocol" in
    vless|vmess) credential="$(xray uuid)" || return 1 ;;
    trojan) credential="$(openssl rand -hex 24)" || return 1 ;;
  esac
  read -r -p "Expiry date YYYY-MM-DD (or 'never'): " expires
  if [[ "$expires" == "never" ]]; then
    expires_at=0
  else
    [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { ah_err "Use YYYY-MM-DD or never."; return 1; }
    expires_at="$(date -d "$expires 23:59:59" +%s 2>/dev/null)" || { ah_err "Invalid expiry date."; return 1; }
    (( expires_at > $(date +%s) )) || { ah_err "Expiry must be in the future."; return 1; }
  fi

  backup="${PU_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  cp -a "$PU_CONFIG" "$backup"
  if ! jq --arg p "$protocol" --arg email "$email" --arg credential "$credential" --argjson port "$port" '
    .inbounds |= map(
      if .protocol == $p and .port == $port then
        .settings.clients = ((.settings.clients // []) + (
          if $p == "trojan" then [{"password": $credential, "email": $email}]
          elif $p == "vmess" then [{"id": $credential, "alterId": 0, "email": $email}]
          else [{"id": $credential, "email": $email}] end
        ))
      else . end
    )
  ' "$PU_CONFIG" > "$tmp"; then
    rm -f "$tmp"; ah_err "Could not update Xray config."; return 1
  fi
  install -m 600 "$tmp" "$PU_CONFIG"
  rm -f "$tmp"
  if ! xray run -test -config "$PU_CONFIG"; then
    cp -a "$backup" "$PU_CONFIG"
    ah_err "Xray validation failed; previous config restored."; return 1
  fi

  tmp="$(mktemp)"
  if ! jq --arg p "$protocol" --arg name "$username" --arg email "$email" --arg credential "$credential" --argjson port "$port" --argjson expiry "$expires_at"     '. + [{protocol:$p, name:$name, email:$email, credential:$credential, port:$port, expires_at:$expiry, created_at:(now|floor)}]' "$PU_DB" > "$tmp"; then
    rm -f "$tmp"; cp -a "$backup" "$PU_CONFIG"; ah_err "Could not update account database."; return 1
  fi
  install -m 600 "$tmp" "$PU_DB"
  rm -f "$tmp"
  if ! systemctl restart xray; then
    cp -a "$backup" "$PU_CONFIG"
    tmp="$(mktemp)"
    jq --arg e "$email" '[.[] | select(.email != $e)]' "$PU_DB" > "$tmp"
    install -m 600 "$tmp" "$PU_DB"; rm -f "$tmp"
    systemctl restart xray || true
    ah_err "Xray restart failed; config and account database rolled back."; return 1
  fi
  ah_ok "Account created."
  echo "Protocol: $protocol"
  echo "Inbound port: $port"
  echo "Account name: $username"
  echo "Client credential: $credential"
  echo "Expiry: ${expires}"
  ah_warn "Store the credential securely. Client import links must use this inbound's transport and security settings."
}

pu_list() {
  ah_require_root || return 1
  pu_require_tools || return 1
  printf '\n%-10s %-18s %-8s %-22s %s\n' "PROTOCOL" "NAME" "PORT" "EXPIRES" "STATUS"
  jq -r '.[] | [.protocol,.name,(.port|tostring),(if .expires_at == 0 then "Never" else (.expires_at|todate) end),(if .expires_at == 0 or .expires_at > now then "Active" else "Expired (pending cleanup)" end)] | @tsv' "$PU_DB" |
  while IFS=$'\t' read -r p n port expiry status; do printf '%-10s %-18s %-8s %-22s %s\n' "$p" "$n" "$port" "$expiry" "$status"; done
}

pu_remove_one() {
  local protocol="$1" port="$2" email="$3"
  local tmp
  tmp="$(mktemp)"
  if ! jq --arg p "$protocol" --arg e "$email" --argjson port "$port" '
    .inbounds |= map(if .protocol == $p and .port == $port then
      .settings.clients = [.settings.clients[]? | select(.email != $e)]
    else . end)
  ' "$PU_CONFIG" > "$tmp"; then rm -f "$tmp"; return 1; fi
  install -m 600 "$tmp" "$PU_CONFIG"
  rm -f "$tmp"
}

pu_remove() {
  ah_require_root || return 1
  pu_require_tools || return 1
  pu_lock || return 1
  pu_list
  read -r -p "Account name to remove: " name
  local record protocol port email backup tmp
  record="$(jq -c --arg n "$name" '[.[] | select(.name == $n)] | .[0] // empty' "$PU_DB")"
  [[ -n "$record" ]] || { ah_err "Account not found."; return 1; }
  protocol="$(jq -r '.protocol' <<< "$record")"
  port="$(jq -r '.port' <<< "$record")"
  email="$(jq -r '.email' <<< "$record")"
  backup="${PU_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$PU_CONFIG" "$backup"
  pu_remove_one "$protocol" "$port" "$email" || { ah_err "Could not remove account."; return 1; }
  if ! xray run -test -config "$PU_CONFIG"; then cp -a "$backup" "$PU_CONFIG"; ah_err "Validation failed; restored."; return 1; fi
  tmp="$(mktemp)"
  jq --arg e "$email" '[.[] | select(.email != $e)]' "$PU_DB" > "$tmp"
  if ! systemctl restart xray; then
    cp -a "$backup" "$PU_CONFIG"; rm -f "$tmp"
    systemctl restart xray || true
    ah_err "Xray restart failed; previous config restored."; return 1
  fi
  install -m 600 "$tmp" "$PU_DB"; rm -f "$tmp"
  ah_ok "Account $name removed."
}

pu_expire() {
  ah_require_root || return 1
  pu_require_tools || return 1
  pu_lock || return 1
  local expired record protocol port email tmp backup changed=0
  expired="$(jq -c '.[] | select(.expires_at != 0 and .expires_at <= now)' "$PU_DB")"
  [[ -n "$expired" ]] || { ah_info "No expired protocol accounts."; return 0; }
  backup="${PU_CONFIG}.africhome-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$PU_CONFIG" "$backup"
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    protocol="$(jq -r '.protocol' <<< "$record")"
    port="$(jq -r '.port' <<< "$record")"
    email="$(jq -r '.email' <<< "$record")"
    pu_remove_one "$protocol" "$port" "$email" || { cp -a "$backup" "$PU_CONFIG"; ah_err "Expiry cleanup failed; config restored."; return 1; }
    changed=1
  done <<< "$expired"
  if (( changed )); then
    if ! xray run -test -config "$PU_CONFIG"; then cp -a "$backup" "$PU_CONFIG"; ah_err "Expiry cleanup validation failed; config restored."; return 1; fi
    tmp="$(mktemp)"
    jq '[.[] | select(.expires_at == 0 or .expires_at > now)]' "$PU_DB" > "$tmp"
    if ! systemctl restart xray; then
      cp -a "$backup" "$PU_CONFIG"; rm -f "$tmp"
      systemctl restart xray || true
      ah_err "Xray restart failed; previous config restored. Expiry records were retained."; return 1
    fi
    install -m 600 "$tmp" "$PU_DB"; rm -f "$tmp"
    ah_ok "Expired protocol accounts have been removed."
  fi
}

pu_install_timer() {
  ah_require_root || return 1
  local script service timer
  script="/opt/africhome-vps-tunnel/modules/protocol_users.sh"
  [[ -r "$script" ]] || { ah_err "Install the latest Africhome release before enabling expiry automation."; return 1; }
  cat > /etc/systemd/system/africhome-expire.service <<EOF
[Unit]
Description=Expire Africhome Xray protocol accounts

[Service]
Type=oneshot
ExecStart=/bin/bash $script --expire
EOF
  cat > /etc/systemd/system/africhome-expire.timer <<'EOF'
[Unit]
Description=Daily expiry check for Africhome protocol accounts

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now africhome-expire.timer
  ah_ok "Daily protocol account expiry timer enabled."
}

pu_menu() {
  while true; do
    echo
    echo "----- Protocol Account Management -----"
    echo "1) Add VLESS / VMess / Trojan account with expiry"
    echo "2) List managed accounts"
    echo "3) Remove managed account"
    echo "4) Run expiry cleanup now"
    echo "5) Enable daily automatic expiry"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) pu_add; ah_pause ;;
      2) pu_list; ah_pause ;;
      3) pu_remove; ah_pause ;;
      4) pu_expire; ah_pause ;;
      5) pu_install_timer; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}

if [[ "${1:-}" == "--expire" ]]; then
  pu_expire
fi
