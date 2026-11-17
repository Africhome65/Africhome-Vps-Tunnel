#!/usr/bin/env bash
set -Eeuo pipefail
BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$BASE_DIR/lib/common.sh" && -f "$BASE_DIR/modules/security.sh" && -f "$BASE_DIR/modules/ssh_users.sh" && -f "$BASE_DIR/modules/wireguard.sh" ]] || {
  echo "Africhome files are incomplete. Re-run the installer." >&2
  exit 1
}
. "$BASE_DIR/lib/common.sh"
. "$BASE_DIR/modules/security.sh"
. "$BASE_DIR/modules/ssh_users.sh"
. "$BASE_DIR/modules/wireguard.sh"

while true; do
  clear
  echo "======================================"
  echo "       AFRICHOME VPS TUNNEL"
  echo "       Terminal Management"
  echo "======================================"
  echo "1) System information"
  echo "2) Security management"
  echo "3) SSH account management"
  echo "4) WireGuard management"
  echo "5) Other protocols (under development)"
  echo "6) Installation information"
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
    4) wg_menu ;;
    5) echo "SlowDNS SSH, VMess, VLESS, Trojan and Shadowsocks are not implemented yet."; ah_pause ;;
    6) echo "Install path: $BASE_DIR"; echo "Update: re-run the repository installer after updates are published."; ah_pause ;;
    0) exit 0 ;;
    *) ah_warn "Invalid choice."; sleep 1 ;;
  esac
done
