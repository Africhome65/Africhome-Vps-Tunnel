#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
BASE_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
[[ -f "$BASE_DIR/scripts/update-reality-sni.py" && -f "$BASE_DIR/scripts/openvpn-inventory.sh" && -f "$BASE_DIR/scripts/dnstt-inventory.sh" && -f "$BASE_DIR/scripts/xray-inventory.sh" && -f "$BASE_DIR/lib/common.sh" && -f "$BASE_DIR/modules/security.sh" && -f "$BASE_DIR/modules/ssh_users.sh" && -f "$BASE_DIR/modules/port_routing.sh" && -f "$BASE_DIR/modules/xray.sh" && -f "$BASE_DIR/modules/vmess.sh" && -f "$BASE_DIR/modules/trojan.sh" && -f "$BASE_DIR/modules/shadowsocks.sh" && -f "$BASE_DIR/modules/protocol_users.sh" && -f "$BASE_DIR/modules/account_registry.sh" && -f "$BASE_DIR/modules/hysteria.sh" && -f "$BASE_DIR/modules/hysteria_users.sh" && -f "$BASE_DIR/modules/domain_manager.sh" && -f "$BASE_DIR/modules/cert_deploy.sh" && -f "$BASE_DIR/modules/backup.sh" && -f "$BASE_DIR/modules/service_modes.sh" && -f "$BASE_DIR/modules/openvpn.sh" && -f "$BASE_DIR/modules/central_router.sh" ]] || {
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
. "$BASE_DIR/modules/cert_deploy.sh"
. "$BASE_DIR/modules/backup.sh"
. "$BASE_DIR/modules/service_modes.sh"
. "$BASE_DIR/modules/openvpn.sh"
. "$BASE_DIR/modules/central_router.sh"

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
  echo "13) Certificate deployment targets"
  echo "14) Installation information"
  echo "15) Backups and staged restore"
  echo "16) Requested service modes and compatibility notes"
  echo "17) Read-only Xray inbound inventory"
  echo "18) Read-only DNSTT deployment inventory"
  echo "19) Read-only OpenVPN deployment inventory"
  echo "20) OpenVPN server and certificate management"
  echo "21) Generate central HAProxy candidate (no live changes)"
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
    13) cd_menu ;;
    14) echo "Install path: $BASE_DIR"; echo "Update: re-run the repository installer after updates are published."; ah_pause ;;
    15) backup_menu ;;
    16) af_modes_menu ;;
    17) bash "$BASE_DIR/scripts/xray-inventory.sh"; ah_pause ;;
    18) bash "$BASE_DIR/scripts/dnstt-inventory.sh"; ah_pause ;;
    19) bash "$BASE_DIR/scripts/openvpn-inventory.sh"; ah_pause ;;
    20) ovpn_menu ;;
    21) cr_render_candidate; ah_pause ;;
    0) exit 0 ;;
    *) ah_warn "Invalid choice."; sleep 1 ;;
  esac
done
