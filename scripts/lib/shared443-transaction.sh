#!/usr/bin/env bash
# Transactional apply helper for the Africhome shared TCP/443 candidate.

shared443_restore_file() {
  local backup="$1" destination="$2" tmp
  tmp="$(mktemp "$(dirname -- "$destination")/.africhome-restore.XXXXXX")" || return 1
  if ! cp -a -- "$backup" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
}

shared443_apply_transaction() {
  local candidate_dir="$1" xray_config="$2" haproxy_config="$3" vmess_state="$4"
  local backup_root="$5" xray_service="$6" haproxy_service="$7" strict_owner="${8:-1}"
  local backup_dir="" xray_tmp="" haproxy_tmp="" state_tmp="" xray_group="" haproxy_enabled_state=""
  local xray_was_active=0 haproxy_was_active=0 haproxy_was_enabled=0
  local xray_changed=0 haproxy_changed=0 vmess_state_existed=0 vmess_state_changed=0 rollback_ok=1
  local file listeners

  [[ -d "$candidate_dir" && ! -L "$candidate_dir" ]] || { echo "Candidate directory must be a real directory." >&2; return 1; }
  [[ "$(stat -c '%a' "$candidate_dir")" == "700" ]] || { echo "Candidate directory must have mode 0700." >&2; return 1; }
  if (( strict_owner )) && [[ "$(stat -c '%u' "$candidate_dir")" != "0" ]]; then
    echo "Candidate directory must be root-owned." >&2; return 1
  fi
  for file in xray-config.json haproxy-443.cfg tls-routes.json vmess-state.env; do
    [[ -f "$candidate_dir/$file" && ! -L "$candidate_dir/$file" ]] || { echo "Candidate file is missing or unsafe: $file" >&2; return 1; }
    [[ "$(stat -c '%a' "$candidate_dir/$file")" == "600" ]] || { echo "Candidate file must have mode 0600: $file" >&2; return 1; }
    if (( strict_owner )) && [[ "$(stat -c '%u' "$candidate_dir/$file")" != "0" ]]; then
      echo "Candidate file must be root-owned: $file" >&2; return 1
    fi
  done
  for file in "$xray_config" "$haproxy_config"; do
    [[ -f "$file" && ! -L "$file" ]] || { echo "Active configuration is missing or unsafe: $file" >&2; return 1; }
  done
  [[ -d "$(dirname -- "$vmess_state")" && ! -L "$(dirname -- "$vmess_state")" ]] || { echo "VMess state directory is missing or unsafe." >&2; return 1; }
  if [[ -e "$vmess_state" || -L "$vmess_state" ]]; then
    [[ -f "$vmess_state" && ! -L "$vmess_state" ]] || { echo "Existing VMess state is not a regular non-symlink file." >&2; return 1; }
    [[ "$(stat -c '%a' "$vmess_state")" == "600" ]] || { echo "Existing VMess state must have mode 0600." >&2; return 1; }
    if (( strict_owner )) && [[ "$(stat -c '%u' "$vmess_state")" != "0" ]]; then
      echo "Existing VMess state must be root-owned." >&2; return 1
    fi
    vmess_state_existed=1
  fi
  command -v xray >/dev/null 2>&1 || { echo "Xray binary is required." >&2; return 1; }
  command -v haproxy >/dev/null 2>&1 || { echo "HAProxy binary is required." >&2; return 1; }
  command -v ss >/dev/null 2>&1 || { echo "ss is required for TCP/443 listener checks." >&2; return 1; }

  systemctl is-active --quiet "$xray_service" || { echo "Xray service must be active before shared-443 migration." >&2; return 1; }
  xray_was_active=1
  if systemctl is-active --quiet "$haproxy_service"; then haproxy_was_active=1; fi
  haproxy_enabled_state="$(systemctl is-enabled "$haproxy_service" 2>/dev/null || true)"
  case "$haproxy_enabled_state" in
    enabled) haproxy_was_enabled=1 ;;
    disabled) haproxy_was_enabled=0 ;;
    *) echo "HAProxy unit must be persistently enabled or disabled (not static/runtime-enabled/masked)." >&2; return 1 ;;
  esac
  xray_group="$(systemctl show -p Group --value "$xray_service" 2>/dev/null || true)"
  [[ -n "$xray_group" ]] || xray_group="root"
  getent group "$xray_group" >/dev/null 2>&1 || { echo "Xray service group does not exist: $xray_group" >&2; return 1; }

  xray run -test -config "$candidate_dir/xray-config.json" || { echo "Xray rejected the candidate config." >&2; return 1; }
  haproxy -c -f "$candidate_dir/haproxy-443.cfg" || { echo "HAProxy rejected the candidate config." >&2; return 1; }

  if (( strict_owner )); then
    install -d -o root -g root -m 0700 "$backup_root" || return 1
  else
    install -d -m 0700 "$backup_root" || return 1
  fi
  [[ -d "$backup_root" && ! -L "$backup_root" ]] || { echo "Backup root is unsafe." >&2; return 1; }
  backup_dir="$(mktemp -d "$backup_root/africhome-vmess-shared443.XXXXXX")" || return 1
  chmod 0700 "$backup_dir"
  cp -a -- "$xray_config" "$backup_dir/xray-config.json" || { echo "Could not back up active Xray config." >&2; return 1; }
  cp -a -- "$haproxy_config" "$backup_dir/haproxy.cfg" || { echo "Could not back up active HAProxy config." >&2; return 1; }
  if (( vmess_state_existed )); then
    cp -a -- "$vmess_state" "$backup_dir/vmess-state.env" || { echo "Could not back up existing VMess state." >&2; return 1; }
  fi
  printf 'xray_service=%s\nxray_was_active=%s\nhaproxy_service=%s\nhaproxy_was_active=%s\nhaproxy_enabled_state=%s\nvmess_state_existed=%s\n' \
    "$xray_service" "$xray_was_active" "$haproxy_service" "$haproxy_was_active" "$haproxy_enabled_state" "$vmess_state_existed" > "$backup_dir/service-state.txt"
  chmod 0600 "$backup_dir/service-state.txt"

  xray_tmp="$(mktemp "$(dirname -- "$xray_config")/.africhome-xray-shared443.XXXXXX")" || return 1
  if (( strict_owner )); then
    install -o root -g "$xray_group" -m 0640 "$candidate_dir/xray-config.json" "$xray_tmp" || { rm -f -- "$xray_tmp"; return 1; }
  else
    install -m 0640 "$candidate_dir/xray-config.json" "$xray_tmp" || { rm -f -- "$xray_tmp"; return 1; }
  fi
  mv -f -- "$xray_tmp" "$xray_config" || { rm -f -- "$xray_tmp"; return 1; }
  xray_tmp=""
  xray_changed=1
  if ! systemctl restart "$xray_service" || ! systemctl is-active --quiet "$xray_service"; then
    echo "Xray failed after shared-443 candidate apply." >&2
    rollback_ok=0
  fi

  if (( rollback_ok )); then
    if ! listeners="$(ss -H -ltnp 'sport = :443' 2>/dev/null)"; then
      echo "Could not inspect TCP/443 after moving Xray backends to loopback." >&2
      rollback_ok=0
    elif [[ -n "$listeners" ]]; then
      echo "TCP/443 is still occupied after moving Xray backends to loopback." >&2
      rollback_ok=0
    fi
  fi

  if (( rollback_ok )); then
    haproxy_tmp="$(mktemp "$(dirname -- "$haproxy_config")/.africhome-haproxy-shared443.XXXXXX")" || rollback_ok=0
    if (( rollback_ok )); then
      if (( strict_owner )); then
        install -o root -g root -m 0644 "$candidate_dir/haproxy-443.cfg" "$haproxy_tmp" || rollback_ok=0
      else
        install -m 0644 "$candidate_dir/haproxy-443.cfg" "$haproxy_tmp" || rollback_ok=0
      fi
    fi
    if (( rollback_ok )); then
      mv -f -- "$haproxy_tmp" "$haproxy_config" || rollback_ok=0
      if (( rollback_ok )); then
        haproxy_tmp=""
        haproxy_changed=1
      fi
    fi
  fi

  if (( rollback_ok )); then
    if (( ! haproxy_was_enabled )); then systemctl enable "$haproxy_service" || rollback_ok=0; fi
    if (( rollback_ok )); then
      systemctl restart "$haproxy_service" && systemctl is-active --quiet "$haproxy_service" || rollback_ok=0
    fi
  fi
  if (( rollback_ok )); then
    if ! listeners="$(ss -H -ltnp 'sport = :443' 2>/dev/null)"; then
      echo "Could not verify the HAProxy TCP/443 listener." >&2
      rollback_ok=0
    elif [[ -z "$listeners" || "$listeners" != *haproxy* ]]; then
      echo "HAProxy did not establish its own TCP/443 listener." >&2
      rollback_ok=0
    fi
  fi

  if (( rollback_ok )); then
    state_tmp="$(mktemp "$(dirname -- "$vmess_state")/.africhome-vmess-state.XXXXXX")" || rollback_ok=0
    if (( rollback_ok )); then
      if (( strict_owner )); then
        install -o root -g root -m 0600 "$candidate_dir/vmess-state.env" "$state_tmp" || rollback_ok=0
      else
        install -m 0600 "$candidate_dir/vmess-state.env" "$state_tmp" || rollback_ok=0
      fi
    fi
    if (( rollback_ok )); then
      mv -f -- "$state_tmp" "$vmess_state" || rollback_ok=0
      if (( rollback_ok )); then
        state_tmp=""
        vmess_state_changed=1
      fi
    fi
  fi

  if (( rollback_ok )); then
    rm -f -- "${xray_tmp:-}" "${haproxy_tmp:-}" "${state_tmp:-}"
    echo "Shared TCP/443 configuration applied."
    echo "Protected pre-change backup: $backup_dir"
    return 0
  fi

  echo "Apply failed; restoring the previous Xray and HAProxy configuration." >&2
  if (( haproxy_changed )); then
    shared443_restore_file "$backup_dir/haproxy.cfg" "$haproxy_config" || rollback_ok=0
  fi
  if (( xray_changed )); then
    shared443_restore_file "$backup_dir/xray-config.json" "$xray_config" || rollback_ok=0
  fi
  if (( vmess_state_changed )); then
    if (( vmess_state_existed )); then
      shared443_restore_file "$backup_dir/vmess-state.env" "$vmess_state" || rollback_ok=0
    else
      rm -f -- "$vmess_state" || rollback_ok=0
    fi
  fi
  systemctl daemon-reload || rollback_ok=0
  if (( xray_was_active )); then
    systemctl restart "$xray_service" || rollback_ok=0
  else
    systemctl stop "$xray_service" >/dev/null 2>&1 || true
  fi
  if (( haproxy_was_active )); then
    systemctl restart "$haproxy_service" || rollback_ok=0
  else
    systemctl stop "$haproxy_service" >/dev/null 2>&1 || true
  fi
  if (( haproxy_was_enabled )); then
    systemctl enable "$haproxy_service" || rollback_ok=0
  else
    systemctl disable "$haproxy_service" >/dev/null 2>&1 || rollback_ok=0
  fi
  rm -f -- "${xray_tmp:-}" "${haproxy_tmp:-}" "${state_tmp:-}"
  if (( rollback_ok )); then
    echo "Rollback completed. Protected backup retained at $backup_dir." >&2
  else
    echo "CRITICAL: rollback is incomplete. Protected backup retained at $backup_dir." >&2
  fi
  return 1
}
