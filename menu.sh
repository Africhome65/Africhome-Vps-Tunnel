#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
BASE_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
[[ -f "$BASE_DIR/lib/common.sh" && -f "$BASE_DIR/modules/security.sh" && -f "$BASE_DIR/modules/ssh_users.sh" && -f "$BASE_DIR/modules/slowdns.sh" && -f "$BASE_DIR/modules/xray.sh" && -f "$BASE_DIR/modules/vmess.sh" && -f "$BASE_DIR/modules/trojan.sh" && -f "$BASE_DIR/modules/shadowsocks.sh" && -f "$BASE_DIR/modules/protocol_users.sh" ]] || {
  echo "Africhome files are incomplete. Re-run the installer." >&2
  exit 1
}
. "$BASE_DIR/lib/common.sh"
. "$BASE_DIR/modules/security.sh"
. "$BASE_DIR/modules/ssh_users.sh"
. "$BASE_DIR/modules/slowdns.sh"
. "$BASE_DIR/modules/xray.sh"
. "$BASE_DIR/modules/vmess.sh"
. "$BASE_DIR/modules/trojan.sh"
. "$BASE_DIR/modules/shadowsocks.sh"
. "$BASE_DIR/modules/protocol_users.sh"

while true; do
  clear
  echo "======================================"
  echo "       AFRICHOME VPS TUNNEL"
  echo "       Terminal Management"
  echo "======================================"
  echo "1) System information"
  echo "2) Security management"
  echo "3) SSH account management"
  echo "4) SlowDNS SSH management"
  echo "5) Xray management (VLESS REALITY)"
  echo "6) VMess management (WebSocket + TLS)"
  echo "7) Trojan management (TLS)"
  echo "8) Shadowsocks management"
  echo "9) Protocol account management (expiry)"
  echo "10) Other protocols (under development)"
  echo "11) Installation information"
  echo "0) Exit"
  read -r -p "Select an option: " choice
  case "$choice" in
    1)
      . /etc/os-release
      echo "OS: ${PRETTY_NAME:-unknown}"
      echo "Kernel: $(uname -r)"
      echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
      echo "Public IPv4: $(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || echo unavailable)"
      ah_pause
      ;;
    2) security_menu ;;
    3) ssh_users_menu ;;
    4) slowdns_menu ;;
    5) xray_menu ;;
    6) vmess_menu ;;
    7) trojan_menu ;;
    8) shadowsocks_menu ;;
    9) pu_menu ;;
    10) echo "Other protocols are not implemented yet."; ah_pause ;;
    11) echo "Install path: $BASE_DIR"; echo "Update: re-run the repository installer after updates are published."; ah_pause ;;
    0) exit 0 ;;
    *) ah_warn "Invalid choice."; sleep 1 ;;
  esac
done
