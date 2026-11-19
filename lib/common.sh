#!/usr/bin/env bash
ah_info(){ printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ah_ok(){ printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
ah_warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
ah_err(){ printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }
ah_pause(){ read -r -p "Press Enter to continue..." _; }
ah_require_root(){
  if [[ "${EUID}" -ne 0 ]]; then ah_err "Run this menu as root (sudo africhome)."; return 1; fi
}
ah_apt_install(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y "$@"
}

# Append a fixed event code and result only; never pass credentials or raw input.
AH_AUDIT_LOG="${AH_AUDIT_LOG:-/var/log/africhome/admin-actions.log}"
ah_audit_log() {
  local event="${1:-}" result="${2:-}"
  [[ "$event" =~ ^[a-z][a-z0-9_.-]{1,63}$ ]] || return 1
  [[ "$result" == success || "$result" == failure || "$result" == cancelled ]] || return 1
  [[ "${EUID}" -eq 0 ]] || return 1
  local dir
  dir="$(dirname -- "$AH_AUDIT_LOG")"
  install -d -o root -g root -m 0700 "$dir" || return 1
  [[ ! -L "$AH_AUDIT_LOG" ]] || return 1
  if [[ -e "$AH_AUDIT_LOG" ]]; then
    [[ -f "$AH_AUDIT_LOG" ]] || return 1
    chown root:root "$AH_AUDIT_LOG" && chmod 0600 "$AH_AUDIT_LOG" || return 1
  else
    install -o root -g root -m 0600 /dev/null "$AH_AUDIT_LOG" || return 1
  fi
  printf '%s event=%s result=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$event" "$result" >> "$AH_AUDIT_LOG"
}
