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


ar_validate_readonly() {
  command -v jq >/dev/null 2>&1 || { echo "[FAIL] jq is required." >&2; return 1; }
  [[ -f "$AR_REGISTRY" && ! -L "$AR_REGISTRY" ]] || {
    echo "[FAIL] Registry is missing or is not a regular non-symlink file." >&2; return 1;
  }
  jq -e '.schema_version == 1 and (.accounts | type == "array")' "$AR_REGISTRY" >/dev/null 2>&1 || {
    echo "[FAIL] Registry is invalid; refusing to modify it." >&2; return 1;
  }
}

ar_host_service_state() {
  local service="${1:-}" unit=""
  case "$service" in
    ssh)
      for unit in ssh.service sshd.service; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then echo "active"; return 0; fi
      done
      if systemctl is-enabled --quiet ssh.service 2>/dev/null || systemctl is-enabled --quiet sshd.service 2>/dev/null; then
        echo "inactive"
      else
        echo "not-installed"
      fi ;;
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
  ar_validate_readonly || return 1
  local account_count service_count expired_count id label service expiry status host_state expiry_display
  account_count="$(jq '.accounts | length' "$AR_REGISTRY")" || return 1
  service_count="$(jq '[.accounts[].services[]] | length' "$AR_REGISTRY")" || return 1
  expired_count="$(jq '[.accounts[] | select(.expires_at != 0 and .expires_at <= now)] | length' "$AR_REGISTRY")" || return 1
  printf '\n=== AFRICHOME ACCOUNT DASHBOARD ===\n'
  printf 'Registered accounts: %s | Service entries: %s | Expired accounts: %s\n' "$account_count" "$service_count" "$expired_count"
  printf '%-20s %-16s %-10s %-20s %-20s %s\n' "ACCOUNT ID" "LABEL" "SERVICE" "EXPIRES (UTC)" "ACCOUNT STATUS" "HOST SERVICE"
  while IFS=$'\t' read -r id label service expiry status; do
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

# Compare registry metadata with local account metadata. This function is
# strictly read-only and deliberately never reads credential fields.
ar_reconcile() {
  ar_validate_readonly || return 1
  local protocol_db="${AR_PROTOCOL_DB:-/etc/africhome-protocol-users.json}"
  local hysteria_db="${AR_HYSTERIA_DB:-/etc/africhome-hysteria-users.json}"
  local account_id service name ref status display_name
  local local_only=0 registry_only=0 ssh_candidates=0 skipped=0

  printf '\n=== READ-ONLY ACCOUNT RECONCILIATION ===\n'
  printf '%-12s %-24s %s\n' "SOURCE" "ACCOUNT" "FINDING"

  if [[ -r "$protocol_db" ]] && jq -e 'type == "array"' "$protocol_db" >/dev/null 2>&1; then
    while IFS=$'\t' read -r account_id service name ref; do
      [[ -n "$service" && -n "$ref" ]] || continue
      if [[ -z "$account_id" ]] || ! jq -e --arg id "$account_id" --arg svc "$service" --arg ref "$ref" \
        'any(.accounts[]; .id == $id and any(.services[]; .service == $svc and .ref == $ref))' \
        "$AR_REGISTRY" >/dev/null 2>&1; then
        printf '%-12s %-24.24s %s\n' "XRAY/$service" "$name" "local metadata exists; registry entry missing"
        ((local_only+=1))
      fi
    done < <(jq -r '.[] | [(.account_id // ""), .protocol, .name, .email] | @tsv' "$protocol_db")
  else
    printf '%-12s %-24s %s\n' "XRAY" "-" "local metadata unavailable/invalid; skipped"
    ((skipped+=1))
  fi

  if [[ -r "$hysteria_db" ]] && jq -e 'type == "array"' "$hysteria_db" >/dev/null 2>&1; then
    while IFS=$'\t' read -r account_id name; do
      [[ -n "$name" ]] || continue
      if [[ -z "$account_id" ]] || ! jq -e --arg id "$account_id" --arg ref "$name" \
        'any(.accounts[]; .id == $id and any(.services[]; .service == "hysteria" and .ref == $ref))' \
        "$AR_REGISTRY" >/dev/null 2>&1; then
        printf '%-12s %-24.24s %s\n' "HYSTERIA" "$name" "local metadata exists; registry entry missing"
        ((local_only+=1))
      fi
    done < <(jq -r '.[] | [(.account_id // ""), .username] | @tsv' "$hysteria_db")
  else
    printf '%-12s %-24s %s\n' "HYSTERIA" "-" "local metadata unavailable/invalid; skipped"
    ((skipped+=1))
  fi

  while IFS=$'\t' read -r account_id service ref status; do
    [[ -n "$ref" ]] || continue
    case "$service" in
      vless|vmess|trojan)
        if [[ -r "$protocol_db" ]] && jq -e --arg id "$account_id" --arg svc "$service" --arg ref "$ref" \
          'any(.[]; .account_id == $id and .protocol == $svc and .email == $ref)' "$protocol_db" >/dev/null 2>&1; then :
        elif [[ "$status" == "revoked" || "$status" == "expired" ]]; then :
        else
          display_name="$(jq -r --arg id "$account_id" '.accounts[] | select(.id == $id) | .label' "$AR_REGISTRY")"
          printf '%-12s %-24.24s %s\n' "XRAY/$service" "$display_name" "registry entry has no matching local record"
          ((registry_only+=1))
        fi ;;
      hysteria)
        if [[ -r "$hysteria_db" ]] && jq -e --arg id "$account_id" --arg ref "$ref" \
          'any(.[]; .account_id == $id and .username == $ref)' "$hysteria_db" >/dev/null 2>&1; then :
        elif [[ "$status" == "revoked" || "$status" == "expired" ]]; then :
        else
          printf '%-12s %-24.24s %s\n' "HYSTERIA" "$ref" "registry entry has no matching local record"
          ((registry_only+=1))
        fi ;;
      ssh)
        if getent passwd "$ref" >/dev/null 2>&1; then :
        elif [[ "$status" == "revoked" || "$status" == "expired" ]]; then :
        else
          printf '%-12s %-24.24s %s\n' "SSH" "$ref" "registry entry has no matching Linux user"
          ((registry_only+=1))
        fi ;;
    esac
  done < <(jq -r '.accounts[] as $a | $a.services[] | [$a.id,.service,.ref,.status] | @tsv' "$AR_REGISTRY")

  while IFS=: read -r name _ uid _ _ _ shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= 1000 )) || continue
    [[ "$shell" != */nologin && "$shell" != */false ]] || continue
    if ! jq -e --arg ref "$name" \
      'any(.accounts[]; any(.services[]; .service == "ssh" and .ref == $ref))' \
      "$AR_REGISTRY" >/dev/null 2>&1; then
      printf '%-12s %-24.24s %s\n' "SSH" "$name" "interactive Linux user not registered (review candidate)"
      ((ssh_candidates+=1))
    fi
  done < <(getent passwd 2>/dev/null || true)

  printf '\nSummary: local-only=%s, registry-only=%s, unregistered SSH candidates=%s, skipped sources=%s\n' \
    "$local_only" "$registry_only" "$ssh_candidates" "$skipped"
  printf 'Read-only report: no accounts, registry records, or service configurations were changed. SSH candidates may be ordinary Linux users.\n'
}

ar_list() { ar_dashboard; }

ar_menu() {
  while true; do
    echo
    echo "----- Unified Account Registry -----"
    echo "1) Refresh unified account dashboard (read-only)"
    echo "2) Reconcile native accounts against registry (read-only)"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) ar_dashboard; read -r -p "Press Enter to continue..." _ ;;
      2) ar_reconcile; read -r -p "Press Enter to continue..." _ ;;
      0) return ;;
      *) echo "[WARN] Invalid choice." ;;
    esac
  done
}
