#!/usr/bin/env bash
# Africhome central-router planning and validation primitives.
# This module does not install packages, write router configs, bind ports,
# alter firewall rules, or restart services.
set -Eeuo pipefail

cr_error(){ printf '[ERROR] %s\n' "$*" >&2; }
cr_info(){ printf '[INFO] %s\n' "$*"; }

cr_valid_port(){
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$port >= 1 && 10#$port <= 65535 ))
}

cr_valid_hostname(){
  local host="${1:-}"
  [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

cr_valid_backend(){
  local host="${1:-}" port="${2:-}"
  [[ "$host" == 127.0.0.1 || "$host" == "::1" ]] || cr_valid_hostname "$host" || return 1
  cr_valid_port "$port"
}

# Return the public transport required by a named Africhome service mode.
# "candidate" means the mode still requires a real compatible client/server
# integration before it may be enabled in production.
cr_mode_transport(){
  case "${1:-}" in
    ssh-direct-ssl|v2ray-ssl|v2ray-ws|trojan-tls|openvpn-tls-sni) printf 'tcp/443:candidate\n' ;;
    ssh-payload-direct|ssh-payload-proxy|v2ray-payload-proxy|v2ray-direct|trojan-direct|openvpn-ws|openvpn-payload-proxy) printf 'tcp/80:candidate\n' ;;
    openvpn-direct-tcp) printf 'tcp/1194:candidate\n' ;;
    openvpn-direct-80) printf 'tcp/80:candidate\n' ;;
    openvpn-direct-443) printf 'tcp/443:candidate\n' ;;
    openvpn-direct-udp) printf 'udp/1194:candidate\n' ;;
    hysteria2) printf 'udp/custom:candidate\n' ;;
    dnstt) printf 'udp/custom:candidate\n' ;;
    vless-reality) printf 'tcp/443:preserve-first\n' ;;
    *) return 1 ;;
  esac
}

# Validate a proposed route tuple: mode, public transport, public port,
# hostname/SNI (or "-" when not applicable), backend host and backend port.
# This checks syntax only; it does not prove protocol compatibility.
cr_validate_route(){
  local mode="${1:-}" transport="${2:-}" public_port="${3:-}"
  local hostname="${4:--}" backend_host="${5:-}" backend_port="${6:-}"
  local expected
  expected="$(cr_mode_transport "$mode")" || { cr_error "Unsupported mode: $mode"; return 1; }
  [[ "$transport" == tcp || "$transport" == udp ]] || { cr_error "Transport must be tcp or udp."; return 1; }
  cr_valid_port "$public_port" || { cr_error "Invalid public port."; return 1; }
  cr_valid_backend "$backend_host" "$backend_port" || { cr_error "Invalid backend address or port."; return 1; }
  if [[ "$hostname" != "-" ]]; then
    cr_valid_hostname "$hostname" || { cr_error "Invalid hostname/SNI."; return 1; }
  fi
  local expected_transport expected_port
  expected_transport="${expected%%/*}"
  expected_port="${expected#*/}"
  [[ "$transport" == "$expected_transport" ]] || { cr_error "$mode expects $expected_transport transport."; return 1; }
  [[ "$expected_port" == custom || "$public_port" == "$expected_port" ]] || {
    cr_error "$mode expects public port $expected_port."; return 1;
  }
  printf 'VALID-SYNTAX mode=%s public=%s/%s host=%s backend=%s:%s status=%s\n' \
    "$mode" "$transport" "$public_port" "$hostname" "$backend_host" "$backend_port" "${expected##*:}"
}

# Detect exact socket collisions in a proposed route list.
# Input rows: transport|port|hostname|mode. A TCP port may be shared only
# when both routes have distinct non-empty hostnames; UDP is never shared.
cr_check_route_collisions(){
  local input="${1:-}" line transport port hostname mode
  local -A seen=()
  while IFS='|' read -r transport port hostname mode; do
    [[ -n "$transport" && -n "$port" && -n "$mode" ]] || continue
    [[ "$transport" == tcp || "$transport" == udp ]] || { cr_error "Invalid transport in route list."; return 2; }
    cr_valid_port "$port" || { cr_error "Invalid port in route list."; return 2; }
    local key="$transport/$port"
    if [[ -n "${seen[$key]+x}" ]]; then
      if [[ "$transport" != tcp || -z "$hostname" || -z "${seen[$key]}" || "$hostname" == "${seen[$key]}" ]]; then
        cr_error "Unresolved socket collision at $key ($mode)."
        return 1
      fi
    else
      seen[$key]="$hostname"
    fi
  done <<< "$input"
  return 0
}
