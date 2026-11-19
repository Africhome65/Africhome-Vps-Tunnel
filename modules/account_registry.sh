#!/usr/bin/env bash
# Central metadata registry. It stores no passwords, private keys, or client URIs.
set -Eeuo pipefail

AR_BASE_DIR="${AR_BASE_DIR:-/var/lib/africhome/accounts}"
AR_REGISTRY="${AR_REGISTRY:-$AR_BASE_DIR/registry.json}"
AR_LOCK="${AR_LOCK:-/run/lock/africhome-account-registry.lock}"

ar_require_tools() {
  command -v jq >/dev/null 2>&1 || { echo "[FAIL] jq is required." >&2; return 1; }
  command -v flock >/dev/null 2>&1 || { echo "[FAIL] flock is required." >&2; return 1; }
}

ar_init() {
  ar_require_tools || return 1
  install -d -m 700 "$AR_BASE_DIR"
  if [[ ! -e "$AR_REGISTRY" ]]; then
    local tmp
    tmp="$(mktemp "${AR_REGISTRY}.XXXXXX")" || return 1
    printf '{"schema_version":1,"accounts":[]}\n' > "$tmp"
    chmod 600 "$tmp"
    if ! mv -n "$tmp" "$AR_REGISTRY"; then rm -f "$tmp"; return 1; fi
  fi
  [[ -f "$AR_REGISTRY" && ! -L "$AR_REGISTRY" ]] || {
    echo "[FAIL] Registry must be a regular non-symlink file." >&2; return 1;
  }
  jq -e '.schema_version == 1 and (.accounts | type == "array")' "$AR_REGISTRY" >/dev/null 2>&1 || {
    echo "[FAIL] Registry is invalid; refusing to overwrite it." >&2; return 1;
  }
  chmod 600 "$AR_REGISTRY"
}

ar_lock() {
  install -d -m 755 "$(dirname "$AR_LOCK")"
  exec 8>"$AR_LOCK"
  flock -n 8 || { echo "[WARN] Another registry operation is running." >&2; return 1; }
}

ar_valid_id() { [[ "${1:-}" =~ ^[A-Za-z0-9_-]{8,64}$ ]]; }
ar_valid_service() { [[ "${1:-}" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]; }
ar_valid_ref() { [[ -n "${1:-}" && "${#1}" -le 128 && "$1" != *$'\n'* ]]; }
ar_valid_expiry() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Register only after a protocol adapter has successfully created and verified
# the native service account. "ref" is a non-secret service-side identifier.
ar_register_service() {
  local account_id="$1" label="$2" service="$3" service_ref="$4" expires_at="$5"
  ar_valid_id "$account_id" && ar_valid_service "$service" &&
    ar_valid_ref "$service_ref" && ar_valid_expiry "$expires_at" || {
      echo "[FAIL] Invalid registry fields." >&2; return 1;
    }
  [[ -n "$label" && "${#label}" -le 64 && "$label" != *$'\n'* ]] || {
    echo "[FAIL] Invalid account label." >&2; return 1;
  }
  ar_init || return 1
  ar_lock || return 1
  local tmp now
  now="$(date +%s)"
  tmp="$(mktemp "${AR_REGISTRY}.XXXXXX")" || return 1
  if ! jq --arg id "$account_id" --arg label "$label" --arg service "$service" \
      --arg ref "$service_ref" --argjson expiry "$expires_at" --argjson now "$now" '
    .accounts |= (
      if any(.[]; .id == $id) then
        map(if .id == $id then
          .label = $label
          | .expires_at = $expiry
          | (.services // []) as $services
          | .services = (
              if any($services[]; .service == $service and .ref == $ref) then
                ($services | map(if .service == $service and .ref == $ref then
                  .status = "active" | .updated_at = $now
                else . end))
              else $services + [{service:$service, ref:$ref, status:"active", updated_at:$now}]
              end
            )
        else . end)
      else . + [{id:$id, label:$label, created_at:$now, expires_at:$expiry,
                 services:[{service:$service, ref:$ref, status:"active", updated_at:$now}]}]
      end
    )
  ' "$AR_REGISTRY" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$AR_REGISTRY"
}

ar_set_service_status() {
  local account_id="$1" service="$2" service_ref="$3" status="$4"
  ar_valid_id "$account_id" && ar_valid_service "$service" && ar_valid_ref "$service_ref" || return 1
  case "$status" in active|suspended|expired|revoked|error) ;; *) return 1 ;; esac
  ar_init || return 1
  ar_lock || return 1
  jq -e --arg id "$account_id" --arg s "$service" --arg r "$service_ref" \
    'any(.accounts[]; .id == $id and any(.services[]; .service == $s and .ref == $r))' \
    "$AR_REGISTRY" >/dev/null || { echo "[FAIL] Service account not found." >&2; return 1; }
  local tmp now
  now="$(date +%s)"
  tmp="$(mktemp "${AR_REGISTRY}.XXXXXX")" || return 1
  jq --arg id "$account_id" --arg s "$service" --arg r "$service_ref" \
    --arg status "$status" --argjson now "$now" '
    .accounts |= map(if .id == $id then
      .services |= map(if .service == $s and .ref == $r then
        .status = $status | .updated_at = $now
      else . end)
    else . end)
  ' "$AR_REGISTRY" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$AR_REGISTRY"
}

ar_host_service_state() {
  local service="${1:-}" unit=""
  case "$service" in
    ssh) unit="ssh.service"; systemctl is-active --quiet "$unit" 2>/dev/null || {
      unit="sshd.service"
      systemctl is-active --quiet "$unit" 2>/dev/null || { echo "inactive"; return 0; }
    } ;;
    vless|vmess|trojan) unit="xray.service" ;;
    hysteria) unit="hysteria-server.service" ;;
    *) echo "not-mapped"; return 0 ;;
  esac
  if systemctl is-active --quiet "$unit" 2>/dev/null; then echo "active"
  elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then echo "inactive"
  else echo "not-installed"
  fi
}

ar_dashboard() {
  ar_init || return 1
  local account_count service_count expired_count id label service expiry status host_state expiry_display
  account_count="$(jq '.accounts | length' "$AR_REGISTRY")" || return 1
  service_count="$(jq '[.accounts[].services[]] | length' "$AR_REGISTRY")" || return 1
  expired_count="$(jq '[.accounts[].services[] as $s | select($s.status == "active") | .] | length' "$AR_REGISTRY")"
  # Expiry is shared at account level, so count each expired account once.
  printf '\n=== AFRICHOME ACCOUNT DASHBOARD ===\n'
  printf 'Registered accounts: %s | Service entries: %s | Expired accounts: %s\n' "$account_count" "$service_count" "$expired_count"
  printf '%-20s %-16s %-10s %-20s %-20s %s\n' "ACCOUNT ID" "LABEL" "SERVICE" "EXPIRES (UTC)" "ACCOUNT STATUS" "HOST SERVICE"
  while IFS=\t' read -r id label service expiry status; do
    if [[ "$expiry" == "0" ]]; then expiry_display="Never"
    elif [[ "$expiry" =~ ^[0-9]+$ ]]; then
      expiry_display="$(date -u -d "@$expiry" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "Unknown")"
      if (( expiry <= $(date +%s) )) && [[ "$status" == "active" ]]; then status="expired (cleanup pending)"; fi
    else expiry_display="Unknown"; fi
    host_state="$(ar_host_service_state "$service")"
    printf '%-20.20s %-16.16s %-10.10s %-20.20s %-20.20s %s\n' "$id" "$label" "$service" "$expiry_display" "$status" "$host_state"
  done < <(jq -r '.accounts[] as $a | $a.services[] | [$a.id,$a.label,.service,($a.expires_at|tostring),.status] | @tsv' "$AR_REGISTRY")
  printf '\nNote: this view shows accounts registered in Africhome metadata only. It does not discover unmanaged native accounts. Host service state is a current systemd check, not a connectivity test.\n'
}

ar_list() { ar_dashboard; }

ar_menu() {
  while true; do
    echo
    echo "----- Unified Account Registry -----"
    echo "1) Refresh unified account dashboard (read-only)"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) ar_dashboard; read -r -p "Press Enter to continue..." _ ;;
      0) return ;;
      *) echo "[WARN] Invalid choice." ;;
    esac
  done
}
