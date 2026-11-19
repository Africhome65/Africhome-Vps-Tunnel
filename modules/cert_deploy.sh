#!/usr/bin/env bash
# Transactional certificate deployment for fixed Africhome service paths.
set -Eeuo pipefail
CD_CONFIG=/etc/africhome/cert-deploy.json
CD_LEGACY_HOOK=/etc/letsencrypt/renewal-hooks/deploy/africhome-hysteria.sh

cd_init() {
  command -v jq >/dev/null || { ah_err "jq is required."; return 1; }
  if [[ ! -e "$CD_CONFIG" ]]; then install -d -m 700 /etc/africhome; printf "[]\n" > "$CD_CONFIG"; chmod 600 "$CD_CONFIG"; fi
  [[ -f "$CD_CONFIG" && ! -L "$CD_CONFIG" ]] || { ah_err "Unsafe deploy registry."; return 1; }
  jq -e 'type=="array" and all(.[]; (.service=="xray" or .service=="hysteria"))' "$CD_CONFIG" >/dev/null || { ah_err "Invalid deploy registry."; return 1; }
}

cd_target_add() {
  local domain service cert key owner group unit tmp
  domain="$(printf "%s" "$1" | tr "[:upper:]" "[:lower:]")"; service="$2"
  dm_valid_domain "$domain" || { ah_err "Invalid domain."; return 1; }
  case "$service" in
    xray) cert=/etc/xray/certs/fullchain.pem; key=/etc/xray/certs/privkey.pem; owner=root; group=xray; unit=xray.service ;;
    hysteria) cert=/etc/hysteria/certs/fullchain.pem; key=/etc/hysteria/certs/privkey.pem; owner=hysteria; group=hysteria; unit=hysteria-server.service ;;
    *) ah_err "Unsupported service."; return 1 ;;
  esac
  cd_init || return 1
  jq -e --arg d "$domain" --arg s "$service" 'any(.[]; .domain==$d and .service==$s)' "$CD_CONFIG" >/dev/null && { ah_warn "Target exists."; return 1; }
  tmp="$(mktemp "$(dirname "$CD_CONFIG")/.cert-deploy.XXXXXX")" || return 1
  jq --arg d "$domain" --arg s "$service" --arg c "$cert" --arg k "$key" --arg o "$owner" --arg g "$group" --arg u "$unit" '. + [{domain:$d,service:$s,cert:$c,key:$k,owner:$o,group:$g,unit:$u}]' "$CD_CONFIG" > "$tmp"
  install -m 600 "$tmp" "$CD_CONFIG"; rm -f "$tmp"
}

cd_deploy_one() {
  local lineage="$1" domain="$2" service="$3" cert="$4" key="$5" owner="$6" group="$7" unit="$8"
  local c_hash k_hash dir backup ct kt oldc=0 oldk=0
  case "$service:$cert:$key:$owner:$group:$unit" in
    "xray:/etc/xray/certs/fullchain.pem:/etc/xray/certs/privkey.pem:root:xray:xray.service" | "hysteria:/etc/hysteria/certs/fullchain.pem:/etc/hysteria/certs/privkey.pem:hysteria:hysteria:hysteria-server.service") ;;
    *) ah_err "Unapproved destination."; return 1 ;;
  esac
  [[ -s "$lineage/fullchain.pem" && -s "$lineage/privkey.pem" ]] || return 1
  openssl x509 -in "$lineage/fullchain.pem" -noout -checkhost "$domain" >/dev/null 2>&1 || { ah_err "Certificate hostname mismatch."; return 1; }
  openssl x509 -in "$lineage/fullchain.pem" -checkend 0 -noout >/dev/null 2>&1 || { ah_err "Certificate expired."; return 1; }
  c_hash="$(openssl x509 -in "$lineage/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d" " -f1)"
  k_hash="$(openssl pkey -in "$lineage/privkey.pem" -pubout -outform DER 2>/dev/null | sha256sum | cut -d" " -f1)" || return 1
  [[ -n "$c_hash" && "$c_hash" == "$k_hash" ]] || { ah_err "Certificate/key mismatch."; return 1; }
  getent passwd "$owner" >/dev/null && getent group "$group" >/dev/null || return 1
  systemctl is-active --quiet "$unit" || { ah_warn "$unit inactive; skip."; return 1; }
  dir="$(dirname "$cert")"; [[ -d "$dir" && -d "$(dirname "$key")" ]] || return 1
  backup="$(mktemp -d /var/backups/africhome-cert.XXXXXX)" || return 1; chmod 700 "$backup"
  [[ ! -e "$cert" ]] || { cp -a "$cert" "$backup/cert"; oldc=1; }
  [[ ! -e "$key" ]] || { cp -a "$key" "$backup/key"; oldk=1; }
  ct="$(mktemp "$dir/.fullchain.XXXXXX")"; kt="$(mktemp "$(dirname "$key")/.privkey.XXXXXX")"
  if ! install -o "$owner" -g "$group" -m 0640 "$lineage/fullchain.pem" "$ct" || ! install -o "$owner" -g "$group" -m 0640 "$lineage/privkey.pem" "$kt" || ! mv -f "$ct" "$cert" || ! mv -f "$kt" "$key"; then
    rm -f "$ct" "$kt"; if ((oldc)); then cp -a "$backup/cert" "$cert"; else rm -f "$cert"; fi; if ((oldk)); then cp -a "$backup/key" "$key"; else rm -f "$key"; fi; rm -rf "$backup"; return 1
  fi
  if ! systemctl restart "$unit"; then
    if ((oldc)); then cp -a "$backup/cert" "$cert"; else rm -f "$cert"; fi; if ((oldk)); then cp -a "$backup/key" "$key"; else rm -f "$key"; fi
    systemctl restart "$unit" || ah_err "Service failed after rollback."; rm -rf "$backup"; return 1
  fi
  ah_ok "$service certificate deployed. Rollback backup retained at $backup."
}

cd_deploy_lineage() {
  local lineage="$1" domain="$2" row service failed=0
  [[ -d "$lineage" ]] || return 1; dm_valid_domain "$domain" || return 1; cd_init || return 1
  while IFS= read -r row; do
    service="$(jq -r ".service" <<< "$row")"
    if [[ -e "$CD_LEGACY_HOOK" ]]; then ah_warn "Legacy hook owns Xray/Hysteria deployment; central hook skipped."; continue; fi
    cd_deploy_one "$lineage" "$domain" "$service" "$(jq -r ".cert" <<< "$row")" "$(jq -r ".key" <<< "$row")" "$(jq -r ".owner" <<< "$row")" "$(jq -r ".group" <<< "$row")" "$(jq -r ".unit" <<< "$row")" || failed=1
  done < <(jq -c --arg d "$domain" '.[]|select(.domain==$d)' "$CD_CONFIG")
  (( failed == 0 ))
}

cd_menu() {
  while true; do echo "Certificate deployment targets"; echo "1) Add Xray"; echo "2) Add Hysteria"; echo "3) List"; echo "0) Back"; read -r -p "Select: " choice
    case "$choice" in 1) read -r -p "Domain: " d; cd_target_add "$d" xray; ah_pause ;; 2) read -r -p "Domain: " d; cd_target_add "$d" hysteria; ah_pause ;; 3) cd_init && jq -r ".[]" "$CD_CONFIG"; ah_pause ;; 0) return ;; *) ah_warn "Invalid choice." ;; esac
  done
}