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
  local host="${1:-}" label
  local -a labels=()
  (( ${#host} <= 253 )) || return 1
  [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  IFS='.' read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    (( ${#label} <= 63 )) || return 1
  done
}

cr_valid_backend(){
  local host="${1:-}" port="${2:-}"
  # Shared-router backends must never bind to a public interface.
  [[ "$host" == 127.0.0.1 || "$host" == "::1" ]] || return 1
  cr_valid_port "$port"
}

# Return the public transport required by a named Africhome service mode.
# "candidate" means the mode still requires a real compatible client/server
# integration before it may be enabled in production.
cr_mode_transport(){
  case "${1:-}" in
    ssh-direct-ssl|ssh-payload-proxy-sni|v2ray-ssl|v2ray-ws|trojan-tls|openvpn-tls-sni) printf 'tcp/443:candidate\n' ;;
    ssh-payload-direct|ssh-payload-proxy|ssh-payload-proxy-only|v2ray-payload-proxy|v2ray-direct|trojan-direct|trojan-tls-80|openvpn-ws|openvpn-payload-proxy) printf 'tcp/80:candidate\n' ;;
    openvpn-direct-tcp) printf 'tcp/1194:candidate\n' ;;
    openvpn-direct-80) printf 'tcp/80:candidate\n' ;;
    openvpn-direct-443) printf 'tcp/443:candidate\n' ;;
    openvpn-direct-udp) printf 'udp/1194:candidate\n' ;;
    udp-direct|hysteria2|dnstt) printf 'udp/custom:candidate\n' ;;
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
  if [[ "$transport" == udp && "$hostname" != "-" ]]; then
    cr_error "UDP routes do not use TCP SNI/hostname matching."
    return 1
  fi
  if [[ "$hostname" != "-" ]]; then
    cr_valid_hostname "$hostname" || { cr_error "Invalid hostname/SNI."; return 1; }
  fi
  local expected_transport expected_port_status expected_port
  expected_transport="${expected%%/*}"
  expected_port_status="${expected#*/}"
  expected_port="${expected_port_status%%:*}"
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
  local input="${1:-}" transport port hostname mode key host_list
  local -A seen=()
  while IFS='|' read -r transport port hostname mode; do
    [[ -n "$transport" && -n "$port" && -n "$mode" ]] || continue
    [[ "$transport" == tcp || "$transport" == udp ]] || { cr_error "Invalid transport in route list."; return 2; }
    cr_valid_port "$port" || { cr_error "Invalid port in route list."; return 2; }
    key="$transport/$port"
    if [[ "$hostname" == "-" ]]; then hostname=""; fi
    if [[ -n "$hostname" ]]; then
      [[ "$transport" == tcp ]] || { cr_error "UDP routes cannot use hostname/SNI matching."; return 2; }
      cr_valid_hostname "$hostname" || { cr_error "Invalid hostname in route list."; return 2; }
      hostname="${hostname,,}"
    fi
    if [[ -n "${seen[$key]+x}" ]]; then
      host_list="${seen[$key]}"
      # Sharing a TCP socket is permitted only when every route has a
      # distinct, valid SNI hostname. A hostname-less route is a wildcard
      # claimant and therefore blocks all additional routes on that socket.
      if [[ "$transport" != tcp || -z "$hostname" || "$host_list" == "WILDCARD" || "$host_list" == *"|$hostname|"* ]]; then
        cr_error "Unresolved socket collision at $key ($mode)."
        return 1
      fi
      seen[$key]="$host_list$hostname|"
    else
      if [[ "$transport" == tcp && -n "$hostname" ]]; then
        seen[$key]="|$hostname|"
      else
        seen[$key]="WILDCARD"
      fi
    fi
  done <<< "$input"
  return 0
}

# Choose an available UDP port from a caller-supplied inventory.
# Arguments: first_port last_port occupied_ports_csv. This is a planning
# helper only; callers must refresh the live socket inventory before binding.
cr_pick_udp_port(){
  local first="${1:-}" last="${2:-}" occupied="${3:-}" port item
  local -A used=()
  local -a items=()
  cr_valid_port "$first" && cr_valid_port "$last" || return 2
  (( 10#$first <= 10#$last )) || return 2
  IFS=',' read -r -a items <<< "$occupied"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    cr_valid_port "$item" || return 2
    used[$((10#$item))]=1
  done
  for ((port=10#$first; port<=10#$last; port++)); do
    if [[ -z "${used[$port]+x}" ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  cr_error "No free UDP port in requested range."
  return 1
}

# Render a reviewed candidate only. This never installs or reloads HAProxy.
cr_render_candidate(){
  ah_require_root || return 1
  command -v python3 >/dev/null 2>&1 || { ah_err "python3 is required."; return 1; }
  local manifest output tmp
  output="/root/africhome-haproxy-candidate.cfg"
  [[ ! -e "$output" && ! -L "$output" ]] || {
    ah_err "Candidate already exists at $output. Review or move it manually before generating another."
    return 1
  }
  read -r -p "Path to the combined routes JSON manifest: " manifest
  [[ -n "$manifest" && -f "$manifest" && ! -L "$manifest" ]] || {
    ah_err "Manifest must be an existing regular file, not a symlink."
    return 1
  }
  [[ -f "$BASE_DIR/scripts/render-central-haproxy.py" ]] || {
    ah_err "Combined HAProxy renderer is missing."
    return 1
  }
  tmp="$(mktemp /root/.africhome-haproxy-candidate.XXXXXX)" || return 1
  if ! python3 "$BASE_DIR/scripts/render-central-haproxy.py" "$manifest" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if command -v haproxy >/dev/null 2>&1; then
    if ! haproxy -c -f "$tmp"; then
      rm -f "$tmp"
      ah_err "HAProxy rejected the candidate; no system configuration was changed."
      return 1
    fi
  else
    ah_warn "HAProxy is not installed here; candidate syntax was not checked by the HAProxy binary."
  fi
  if ! mv -n -- "$tmp" "$output" || [[ -e "$tmp" ]]; then
    rm -f "$tmp"
    ah_err "Could not safely save the candidate file."
    return 1
  fi
  ah_ok "Candidate configuration saved: $output"
  ah_warn "This file has not been applied. Do not replace /etc/haproxy/haproxy.cfg until all backends, listeners, backups and rollback steps are reviewed."
}


# Render a loopback-only VLESS REALITY backend candidate. The active config is
# read-only; output is a separate root-only file and no service is restarted.
cr_render_reality_backend_candidate(){
  ah_require_root || return 1
  command -v python3 >/dev/null 2>&1 || { ah_err "python3 is required."; return 1; }
  local source port output tmp
  source="/usr/local/etc/xray/config.json"
  output="/root/africhome-xray-reality-backend-candidate.json"
  [[ ! -e "$output" && ! -L "$output" ]] || {
    ah_err "Candidate already exists at $output. Review or move it manually before generating another."
    return 1
  }
  read -r -p "Source Xray config [$source]: " answer
  source="${answer:-$source}"
  [[ -f "$source" && ! -L "$source" ]] || {
    ah_err "Source must be an existing regular file, not a symlink."
    return 1
  }
  read -r -p "Loopback backend port [1443]: " port
  port="${port:-1443}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1024 && 10#$port <= 65535 )) || {
    ah_err "Backend port must be between 1024 and 65535."
    return 1
  }
  [[ -f "$BASE_DIR/scripts/render-reality-backend.py" ]] || {
    ah_err "REALITY backend candidate renderer is missing."
    return 1
  }
  tmp="$(mktemp /root/.africhome-xray-reality-backend.XXXXXX)" || return 1
  if ! python3 "$BASE_DIR/scripts/render-reality-backend.py" "$source" --port "$port" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if command -v xray >/dev/null 2>&1; then
    if ! xray run -test -config "$tmp"; then
      rm -f "$tmp"
      ah_err "Xray rejected the candidate; the active config was not changed."
      return 1
    fi
  else
    ah_warn "Xray is not installed; candidate parser validation was skipped."
  fi
  if ! mv -n -- "$tmp" "$output" || [[ -e "$tmp" ]]; then
    rm -f "$tmp"
    ah_err "Could not safely save the candidate file."
    return 1
  fi
  ah_ok "Loopback REALITY candidate saved: $output"
  ah_warn "This is not a migration. The active Xray config and service were not changed. Do not apply until HAProxy routing and external VLESS client compatibility are verified."
}
