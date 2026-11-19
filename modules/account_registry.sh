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
  printf '%-20s %-16s %-10s %-20s %-30s %s\n' "ACCOUNT ID" "LABEL" "SERVICE" "EXPIRES (UTC)" "ACCOUNT STATUS" "HOST SERVICE"
  while IFS=$'\t' read -r id label service expiry status; do
    if [[ "$expiry" == "0" ]]; then expiry_display="Never"
    elif [[ "$expiry" =~ ^[0-9]+$ ]]; then
      expiry_display="$(date -u -d "@$expiry" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "Unknown")"
      if (( expiry <= $(date +%s) )) && [[ "$status" == "active" ]]; then status="expired (cleanup pending)"; fi
    else expiry_display="Unknown"; fi
    host_state="$(ar_host_service_state "$service")"
    printf '%-20.20s %-16.16s %-10.10s %-20.20s %-30.30s %s\n' "$id" "$label" "$service" "$expiry_display" "$status" "$host_state"
  done < <(jq -r '.accounts[] as $a | $a.services[] | [$a.id,$a.label,.service,($a.expires_at|tostring),.status] | @tsv' "$AR_REGISTRY")
  printf '\nNote: this view shows accounts registered in Africhome metadata only. It does not discover unmanaged native accounts. Host service state is a current systemd check, not a connectivity test.\n'
}

# Compare registry metadata with local account metadata. This function is
# strictly read-only and deliberately never reads credential fields.

# Read-only reconciliation across Africhome metadata, native configs, and NSS.
# Only account labels/tags/usernames are emitted; credentials are never printed.
ar_reconcile() {
  ar_validate_readonly || return 1
  local protocol_db="${AR_PROTOCOL_DB:-/etc/africhome-protocol-users.json}"
  local hysteria_db="${AR_HYSTERIA_DB:-/etc/africhome-hysteria-users.json}"
  local xray_config="${AR_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
  local hysteria_config="${AR_HYSTERIA_CONFIG:-/etc/hysteria/config.yaml}"
  local account_id service name ref status display_name native_users=""
  local local_only=0 registry_only=0 native_only=0 stale_local=0 ssh_candidates=0 skipped=0
  local xray_ok=0 hysteria_ok=0 db_match native_match

  printf '\n=== READ-ONLY ACCOUNT RECONCILIATION ===\n'
  printf '%-12s %-24s %s\n' "SOURCE" "ACCOUNT" "FINDING"

  if [[ -r "$protocol_db" ]] && jq -e 'type == "array"' "$protocol_db" >/dev/null 2>&1; then
    while IFS='|' read -r account_id service name ref; do
      [[ -n "$service" && "$ref" != "-" ]] || continue
      if [[ "$account_id" == "-" ]] || ! jq -e --arg id "$account_id" --arg svc "$service" --arg ref "$ref" \
        'any(.accounts[]; .id == $id and any(.services[]; .service == $svc and .ref == $ref))' \
        "$AR_REGISTRY" >/dev/null 2>&1; then
        printf '%-12s %-24.24s %s\n' "XRAY/$service" "$name" "local metadata exists; registry entry missing"
        ((local_only+=1))
      fi
    done < <(jq -r '.[] | [(.account_id // "-"), .protocol, .name, (.email // "-")] | join("|")' "$protocol_db")
  else
    printf '%-12s %-24s %s\n' "XRAY DB" "-" "local metadata unavailable/invalid; skipped"
    ((skipped+=1))
  fi

  if [[ -r "$hysteria_db" ]] && jq -e 'type == "array"' "$hysteria_db" >/dev/null 2>&1; then
    while IFS='|' read -r account_id name; do
      [[ -n "$name" ]] || continue
      if [[ "$account_id" == "-" ]] || ! jq -e --arg id "$account_id" --arg ref "$name" \
        'any(.accounts[]; .id == $id and any(.services[]; .service == "hysteria" and .ref == $ref))' \
        "$AR_REGISTRY" >/dev/null 2>&1; then
        printf '%-12s %-24.24s %s\n' "HYSTERIA DB" "$name" "local metadata exists; registry entry missing"
        ((local_only+=1))
      fi
    done < <(jq -r '.[] | [(.account_id // "-"), .username] | join("|")' "$hysteria_db")
  else
    printf '%-12s %-24s %s\n' "HYSTERIA DB" "-" "local metadata unavailable/invalid; skipped"
    ((skipped+=1))
  fi

  if [[ -r "$xray_config" ]] && jq -e 'type == "object" and (.inbounds | type == "array")' "$xray_config" >/dev/null 2>&1; then
    xray_ok=1
    while IFS='|' read -r service ref; do
      [[ -n "$ref" ]] || continue
      db_match=0
      [[ ! -r "$protocol_db" ]] || jq -e --arg svc "$service" --arg ref "$ref" \
        'any(.[]; .protocol == $svc and .email == $ref)' "$protocol_db" >/dev/null 2>&1 && db_match=1
      if (( db_match == 0 )) && ! jq -e --arg svc "$service" --arg ref "$ref" \
        'any(.accounts[]; any(.services[]; .service == $svc and .ref == $ref))' "$AR_REGISTRY" >/dev/null 2>&1; then
        printf '%-12s %-24.24s %s\n' "XRAY/$service" "$ref" "native client is not registered or in local metadata"
        ((native_only+=1))
      fi
    done < <(jq -r '.inbounds[] | select(.protocol == "vless" or .protocol == "vmess" or .protocol == "trojan") | .protocol as $p | .settings.clients[]? | select((.email // "") != "") | [$p,.email] | join("|")' "$xray_config")

    if [[ -r "$protocol_db" ]]; then
      while IFS='|' read -r service name ref; do
        [[ -n "$service" && "$ref" != "-" ]] || continue
        if ! jq -e --arg svc "$service" --arg ref "$ref" \
          'any(.inbounds[]; .protocol == $svc and any(.settings.clients[]?; .email == $ref))' \
          "$xray_config" >/dev/null 2>&1; then
          printf '%-12s %-24.24s %s\n' "XRAY/$service" "$name" "local metadata record is absent from native config"
          ((stale_local+=1))
        fi
      done < <(jq -r '.[] | [.protocol,.name,(.email // "-")] | join("|")' "$protocol_db")
    fi
  else
    printf '%-12s %-24s %s\n' "XRAY CONFIG" "-" "native config unavailable/invalid; skipped"
    ((skipped+=1))
  fi

  if [[ -r "$hysteria_config" ]] && command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    native_users="$(python3 - "$hysteria_config" <<'PY'
import sys, yaml
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        data = yaml.safe_load(stream)
    auth = data.get("auth", {}) if isinstance(data, dict) else {}
    if not isinstance(auth, dict) or auth.get("type") != "userpass":
        raise SystemExit(3)
    users = auth.get("userpass", {})
    if not isinstance(users, dict):
        raise SystemExit(4)
    for username in users:
        print(username)
except Exception:
    raise SystemExit(5)
PY
)" && hysteria_ok=1 || hysteria_ok=0

    if (( hysteria_ok == 1 )); then
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        db_match=0
        [[ ! -r "$hysteria_db" ]] || jq -e --arg ref "$name" 'any(.[]; .username == $ref)' "$hysteria_db" >/dev/null 2>&1 && db_match=1
        if (( db_match == 0 )) && ! jq -e --arg ref "$name" \
          'any(.accounts[]; any(.services[]; .service == "hysteria" and .ref == $ref))' "$AR_REGISTRY" >/dev/null 2>&1; then
          printf '%-12s %-24.24s %s\n' "HYSTERIA" "$name" "native user is not registered or in local metadata"
          ((native_only+=1))
        fi
      done <<< "$native_users"

      if [[ -r "$hysteria_db" ]]; then
        while IFS='|' read -r account_id name; do
          [[ -n "$name" ]] || continue
          if ! grep -Fxq -- "$name" <<< "$native_users"; then
            printf '%-12s %-24.24s %s\n' "HYSTERIA DB" "$name" "local metadata record is absent from native config"
            ((stale_local+=1))
          fi
        done < <(jq -r '.[] | [(.account_id // "-"), .username] | join("|")' "$hysteria_db")
      fi
    else
      printf '%-12s %-24s %s\n' "HYSTERIA CONFIG" "-" "unsupported auth type or invalid YAML; skipped"
      ((skipped+=1))
    fi
  else
    printf '%-12s %-24s %s\n' "HYSTERIA CONFIG" "-" "config or Python YAML support unavailable; skipped"
    ((skipped+=1))
  fi

  while IFS='|' read -r account_id service ref status; do
    [[ -n "$ref" ]] || continue
    case "$service" in
      vless|vmess|trojan)
        db_match=1
        if [[ -r "$protocol_db" ]]; then
          db_match=0
          jq -e --arg id "$account_id" --arg svc "$service" --arg ref "$ref" \
            'any(.[]; .account_id == $id and .protocol == $svc and .email == $ref)' "$protocol_db" >/dev/null 2>&1 && db_match=1
        fi
        native_match=1
        if (( xray_ok == 1 )); then
          native_match=0
          jq -e --arg svc "$service" --arg ref "$ref" \
            'any(.inbounds[]; .protocol == $svc and any(.settings.clients[]?; .email == $ref))' "$xray_config" >/dev/null 2>&1 && native_match=1
        fi
        if [[ "$status" != "revoked" && "$status" != "expired" ]] && { (( db_match == 0 )) || (( native_match == 0 )); }; then
          display_name="$(jq -r --arg id "$account_id" '.accounts[] | select(.id == $id) | .label' "$AR_REGISTRY")"
          printf '%-12s %-24.24s %s\n' "XRAY/$service" "$display_name" "registry record missing from local metadata and/or native config"
          ((registry_only+=1))
        fi ;;
      hysteria)
        db_match=1
        if [[ -r "$hysteria_db" ]]; then
          db_match=0
          jq -e --arg id "$account_id" --arg ref "$ref" \
            'any(.[]; .account_id == $id and .username == $ref)' "$hysteria_db" >/dev/null 2>&1 && db_match=1
        fi
        native_match=1
        if (( hysteria_ok == 1 )); then
          native_match=0
          grep -Fxq -- "$ref" <<< "$native_users" && native_match=1
        fi
        if [[ "$status" != "revoked" && "$status" != "expired" ]] && { (( db_match == 0 )) || (( native_match == 0 )); }; then
          printf '%-12s %-24.24s %s\n' "HYSTERIA" "$ref" "registry record missing from local metadata and/or native config"
          ((registry_only+=1))
        fi ;;
      ssh)
        if ! getent passwd "$ref" >/dev/null 2>&1 && [[ "$status" != "revoked" && "$status" != "expired" ]]; then
          printf '%-12s %-24.24s %s\n' "SSH" "$ref" "registry entry has no matching Linux user"
          ((registry_only+=1))
        fi ;;
    esac
  done < <(jq -r '.accounts[] as $a | $a.services[] | [$a.id,.service,.ref,.status] | join("|")' "$AR_REGISTRY")

  while IFS=: read -r name _ uid _ _ _ shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= 1000 )) || continue
    [[ "$shell" != */nologin && "$shell" != */false ]] || continue
    if ! jq -e --arg ref "$name" 'any(.accounts[]; any(.services[]; .service == "ssh" and .ref == $ref))' "$AR_REGISTRY" >/dev/null 2>&1; then
      printf '%-12s %-24.24s %s\n' "SSH" "$name" "interactive Linux user not registered (review candidate)"
      ((ssh_candidates+=1))
    fi
  done < <(getent passwd 2>/dev/null || true)

  printf 'Native-only=%s, stale-local=%s\n' "$native_only" "$stale_local"
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
    echo "2) Reconcile accounts with native configs (read-only)"
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
