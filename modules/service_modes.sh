#!/usr/bin/env bash
# Africhome service-mode catalogue. Describes requested modes and constraints;
# it does not install, configure, or start any service.
set -Eeuo pipefail

af_mode_rows(){
  cat <<'ROWS'
SSH|Direct SSL|tcp|443|TLS wrapper required; raw sshd is not SNI-routable
SSH|Payload Direct|tcp|80|Payload handler and documented client payload required
SSH|Payload Proxy|tcp|80|Authenticated proxy handler; 443 may be used only with TLS wrapper
SSH|Payload + Proxy + SNI|tcp|443|TLS wrapper with unique SNI; port 80 requires HTTP payload routing
SSH|Payload + Proxy|tcp|80|Authenticated payload/proxy handler required
V2Ray|SSL (VLESS)|tcp|443|TLS-compatible Xray inbound; SNI routing required when sharing
V2Ray|Payload Proxy (VLESS)|tcp|80|HTTP transport and explicit Host/path/payload definition required
V2Ray|Direct|tcp|80|Dedicated raw inbound; cannot share without a reliable discriminator
V2Ray|WebSocket|tcp|443|WebSocket path routing and TLS/SNI design required
V2Ray|VLESS REALITY|tcp|443|Preserve existing listener; unchanged passthrough only
Trojan|TLS|tcp|443|TLS passthrough with unique SNI or tested TLS termination
Trojan|TLS|tcp|80|Only with an explicitly compatible wrapper; ordinary TLS normally uses 443
OpenVPN|Direct TLS/SNI|tcp|443|TLS wrapper required; native OpenVPN is not assumed to be TLS/SNI
OpenVPN|WebSocket|tcp|80|WebSocket bridge and compatible client required
OpenVPN|Direct TCP|tcp|1194|Native OpenVPN module supports TCP; provider firewall and routing remain separate
OpenVPN|Direct TCP|tcp|80|Possible with native module on a free port; shared-port routing is not integrated
OpenVPN|Direct TCP|tcp|443|Possible with native module on a free port; shared-port routing is not integrated
OpenVPN|Direct UDP|udp|1194|Native OpenVPN module supports UDP; provider firewall and routing remain separate
OpenVPN|TLS + Payload + Proxy + SNI|tcp|443|Wrapper and client interoperability must be proven
UDP|Direct (custom port)|udp|custom|One service per socket unless a tested multiplexer exists
Hysteria 2|UDP|udp|custom|Preserve existing deployment and configured UDP range
DNSTT|DNS tunnel|udp|custom|Preserve existing DNSTT config; independent of TCP router
ROWS
}

af_modes_menu(){
  while true; do
    echo
    echo "===== AFRICHOME SERVICE MODE CATALOGUE ====="
    echo "Native OpenVPN direct mode is implemented; wrapper and shared-port modes remain pending."
    printf '%-12s | %-28s | %-8s | %-7s | %s\n' "SERVICE" "MODE" "TRANSPORT" "PORT" "REQUIREMENT"
    printf '%s\n' "---------------------------------------------------------------------------------------------------------------"
    af_mode_rows | while IFS='|' read -r service mode transport port note; do
      printf '%-12s | %-28s | %-8s | %-7s | %s\n' "$service" "$mode" "$transport" "$port" "$note"
    done
    echo
    echo "0) Back"
    read -r -p "Press Enter or 0 to return: " choice
    [[ "$choice" == 0 || -z "$choice" ]] && return 0
  done
}
