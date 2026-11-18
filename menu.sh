#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
BASE_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
[[ -f "$BASE_DIR/lib/common.sh" && -f "$BASE_DIR/modules/security.sh" && -f "$BASE_DIR/modules/ssh_users.sh" && -f "$BASE_DIR/modules/port_routing.sh" && -f "$BASE_DIR/modules/xray.sh" && -f "$BASE_DIR/modules/vmess.sh" && -f "$BASE_DIR/modules/trojan.sh" && -f "$BASE_DIR/modules/shadowsocks.sh" && -f "$BASE_DIR/modules/protocol_users.sh" && -f "$BASE_DIR/modules/account_registry.sh" && -f "$BASE_DIR/modules/hysteria.sh" && -f "$BASE_DIR/modules/hysteria_users.sh" && -f "$BASE_DIR/modules/domain_manager.sh" ]] || {
  echo "Africhome files are incomplete. Re-run the installer." >&2
  exit 1
}
. "$BASE_DIR/lib/common.sh"
. "$BASE_DIR/modules/security.sh"
. "$BASE_DIR/modules/ssh_users.sh"
. "$BASE_DIR/modules/port_routing.sh"
. "$BASE_DIR/modules/xray.sh"
. "$BASE_DIR/modules/vmess.sh"
. "$BASE_DIR/modules/trojan.sh"
. "$BASE_DIR/modules/shadowsocks.sh"
. "$BASE_DIR/modules/protocol_users.sh"
. "$BASE_DIR/modules/account_registry.sh"
. "$BASE_DIR/modules/hysteria.sh"
. "$BASE_DIR/modules/hysteria_users.sh"
. "$BASE_DIR/modules/domain_manager.sh"

while true; do
  clear
  echo "======================================"
  echo "       AFRICHOME VPS TUNNEL"
  echo "       Terminal Management"
  echo "======================================"
  echo "1) System information"
  echo "2) Security management"
  echo "3) SSH account management"
  echo "4) Xray management (VLESS REALITY)"
  echo "5) VMess management (WebSocket + TLS)"
  echo "6) Trojan management (TLS)"
  echo "7) Shadowsocks management"
  echo "8) Protocol account management (expiry)"
  echo "9) Hysteria 2 management (custom domain + UDP port)"
  echo "10) Port & routing manager (read-only discovery)"
  echo "11) Unified account registry (Xray/SSH/Hysteria accounts)"
  echo "12) Central domain & certificate manager"
  echo "13) Installation information"
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
    4) xray_menu ;;
    5) vmess_menu ;;
    6) trojan_menu ;;
    7) shadowsocks_menu ;;
    8) pu_menu ;;
    9) hy2_menu ;;
    10) pr_port_routing_menu ;;
    11) ar_menu ;;
    12) dm_menu ;;
    13) echo "Install path: $BASE_DIR"; echo "Update: re-run the repository installer after updates are published."; ah_pause ;;
    0) exit 0 ;;
    *) ah_warn "Invalid choice."; sleep 1 ;;
  esac
done
