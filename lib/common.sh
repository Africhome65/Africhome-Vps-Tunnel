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
