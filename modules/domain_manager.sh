#!/usr/bin/env bash
# Central domain inventory and ACME certificate validation. Does not deploy certificates.
set -Eeuo pipefail
DM_STATE_DIR="\${DM_STATE_DIR:-/var/lib/africhome/domains}"
DM_DB="\${DM_DB:-$DM_STATE_DIR/domains.json}"
DM_LE_DIR="\${DM_LE_DIR:-/etc/letsencrypt/live}"

dm_valid_domain() {
  local domain="\${1,,}" label
  local -a labels
  [[ $(printf '%s' "$domain" | wc -c) -le 254 && "$domain" == *.* && "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
  [[ "$domain" =~ ^[a-z0-9.-]+$ ]] || return 1
  IFS='.' read -r -a labels <<< "$domain"
  for label in "\${labels[@]}"; do
    [[ \${#label} -ge 1 && \${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

dm_init() {
  command -v jq >/dev/null 2>&1 || { ah_err "jq is required."; return 1; }
  if [[ ! -e "$DM_DB" ]]; then
    install -d -o root -g root -m 700 "$DM_STATE_DIR"
    printf '[]\n' > "$DM_DB"; chmod 600 "$DM_DB"
  fi
  jq -e 'type == "array"' "$DM_DB" >/dev/null 2>&1 || { ah_err "Domain inventory is invalid; refusing to overwrite."; return 1; }
}

dm_register_domain() {
  local domain="\${1,,}" tmp
  dm_valid_domain "$domain" || { ah_err "Invalid domain name."; return 1; }
  dm_init || return 1
  jq -e --arg d "$domain" 'any(.[]; .domain == $d)' "$DM_DB" >/dev/null && { ah_warn "$domain is already registered."; return 1; }
  tmp="$(mktemp "$DM_STATE_DIR/.domains.XXXXXX")" || return 1
  jq --arg d "$domain" --arg now "$(date -u +%FT%TZ)" \
    '. + [{domain:$d,added_at:$now,dns_checked_at:$now,certificate_checked_at:null,certificate_status:"not_checked"}]' \
    "$DM_DB" > "$tmp" || { rm -f "$tmp"; return 1; }
  install -o root -g root -m 600 "$tmp" "$DM_DB"; rm -f "$tmp"
}

dm_dns_check() {
  local domain="\${1,,}" records expected actual matched=0
  dm_valid_domain "$domain" || { ah_err "Invalid domain."; return 1; }
  command -v getent >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { ah_err "getent and curl are required."; return 1; }
  records="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [[ -n "$records" ]] || { ah_err "No A/AAAA DNS records found for $domain."; return 1; }
  expected="$( { curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true; curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true; } )"
  [[ -n "$expected" ]] || { ah_err "Could not detect this VPS public IP; DNS comparison cannot be trusted."; return 1; }
  while IFS= read -r actual; do
    [[ -n "$actual" ]] || continue
    if grep -Fxq "$actual" <<< "$expected"; then matched=1
    else ah_warn "DNS address does not match detected VPS public IP: $actual"; fi
  done <<< "$records"
  (( matched == 1 )) || { ah_err "No DNS address for $domain matches this VPS. Fix DNS before issuing a certificate."; return 1; }
  printf '%s\n' "$records"
}

dm_cert_check() {
  local domain="\${1,,}" cert key cert_pub key_pub enddate
  dm_valid_domain "$domain" || { ah_err "Invalid domain."; return 1; }
  cert="$DM_LE_DIR/$domain/fullchain.pem"; key="$DM_LE_DIR/$domain/privkey.pem"
  [[ -s "$cert" && -s "$key" ]] || { ah_warn "No Let's Encrypt certificate found for $domain."; return 1; }
  openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 || { ah_err "Certificate does not cover $domain."; return 1; }
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" || return 1
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" || { ah_err "Private key cannot be read."; return 1; }
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || { ah_err "Certificate and private key do not match."; return 1; }
  openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 || { ah_err "Certificate has expired."; return 1; }
  enddate="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2-)"
  printf 'Certificate: %s\nPrivate key: %s\nExpires: %s\n' "$cert" "$key" "$enddate"
}

dm_update_status() {
  local domain="\${1,,}" status="$2" tmp
  dm_init || return 1
  tmp="$(mktemp "$DM_STATE_DIR/.domains.XXXXXX")" || return 1
  jq --arg d "$domain" --arg s "$status" --arg now "$(date -u +%FT%TZ)" \
    'map(if .domain == $d then .certificate_status=$s | .certificate_checked_at=$now else . end)' "$DM_DB" > "$tmp" || { rm -f "$tmp"; return 1; }
  install -o root -g root -m 600 "$tmp" "$DM_DB"; rm -f "$tmp"
}

dm_add() {
  ah_require_root || return 1
  local domain
  read -r -p "Domain to register (DNS must point to this VPS): " domain
  domain="\${domain,,}"
  dm_valid_domain "$domain" && dm_dns_check "$domain" >/dev/null || return 1
  dm_register_domain "$domain" || return 1
  ah_ok "$domain registered and DNS validated against this VPS."
}

dm_issue() {
  ah_require_root || return 1
  local domain email output
  read -r -p "Registered domain for certificate: " domain
  domain="\${domain,,}"
  dm_valid_domain "$domain" || { ah_err "Invalid domain."; return 1; }
  dm_init || return 1
  jq -e --arg d "$domain" 'any(.[]; .domain == $d)' "$DM_DB" >/dev/null || { ah_err "Register and DNS-validate the domain first."; return 1; }
  dm_dns_check "$domain" >/dev/null || return 1
  command -v ss >/dev/null 2>&1 || ah_apt_install iproute2 || return 1
  command -v certbot >/dev/null 2>&1 || ah_apt_install certbot || return 1
  command -v openssl >/dev/null 2>&1 || ah_apt_install openssl || return 1
  if ss -H -ltn 2>/dev/null | awk '$4 ~ /:80$/ {found=1} END{exit !found}'; then
    ah_err "TCP port 80 is occupied. HTTP-01 standalone cannot proceed; no service will be stopped."; return 1
  fi
  read -r -p "Let's Encrypt contact email: " email
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { ah_err "Enter a valid email."; return 1; }
  output="$(certbot certonly --standalone --non-interactive --agree-tos --email "$email" -d "$domain" 2>&1)" || {
    ah_err "Certificate request failed:"; printf '%s\n' "$output" | tail -n 12 >&2; return 1;
  }
  if ! dm_cert_check "$domain"; then
    dm_update_status "$domain" "validation_failed" || true
    ah_err "Certificate validation failed; do not deploy it."; return 1
  fi
  dm_update_status "$domain" "valid" || return 1
  ah_ok "Certificate issued and validated. No service configuration was changed."
}

dm_list() {
  dm_init || return 1
  printf '%-38s %-18s %s\n' DOMAIN CERTIFICATE DNS/CERT_CHECK
  jq -r '.[] | [.domain,.certificate_status,.dns_checked_at] | @tsv' "$DM_DB" |
    while IFS=$'\t' read -r d s t; do printf '%-38s %-18s %s\n' "$d" "$s" "$t"; done
  command -v certbot >/dev/null 2>&1 && { echo; certbot certificates 2>/dev/null | sed -n '/Certificate Name:/p;/Expiry Date:/p'; }
}

dm_check() {
  ah_require_root || return 1
  local domain
  read -r -p "Domain to check: " domain
  domain="\${domain,,}"
  dm_dns_check "$domain" >/dev/null || return 1
  dm_cert_check "$domain" || { dm_update_status "$domain" "invalid" || true; return 1; }
  dm_update_status "$domain" "valid" || return 1
  ah_ok "DNS and certificate checks passed for $domain."
}

dm_menu() {
  while true; do
    echo
    echo "----- Central Domain & Certificate Manager -----"
    echo "1) Register domain and validate DNS"
    echo "2) Issue Let's Encrypt certificate (HTTP-01)"
    echo "3) List registered domains and certificates"
    echo "4) Check DNS, certificate hostname, expiry and key match"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) dm_add; ah_pause ;;
      2) dm_issue; ah_pause ;;
      3) dm_list; ah_pause ;;
      4) dm_check; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
