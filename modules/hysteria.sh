#!/usr/bin/env bash
# Hysteria 2 server with a user-supplied domain and UDP port/range.
set -Eeuo pipefail
HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_STATE="/etc/africhome-hysteria.env"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_HOOK="/etc/letsencrypt/renewal-hooks/deploy/africhome-hysteria.sh"
HY2_VERSION="v2.14.0"
HY2_INSTALLER_COMMIT="c2b181e0b0e72b077e4b0b7297735af14d1f9929"
HY2_INSTALLER_BLOB_SHA="0120aa8e9fab0974be2e4f2340b6efb15f88e361"

hy2_valid_domain() {
  local domain="$1" label
  local -a labels
  [[ "${#domain}" -le 253 && "$domain" == *.* && "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  IFS='.' read -r -a labels <<< "$domain"
  for label in "${labels[@]}"; do
    [[ "${#label}" -ge 1 && "${#label}" -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}
hy2_valid_port_spec() {
  local spec="$1" first last
  if [[ "$spec" =~ ^[0-9]{1,5}$ ]]; then
    first="$spec"
    (( 10#$first >= 1 && 10#$first <= 65535 )) || return 1
  elif [[ "$spec" =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]]; then
    IFS=- read -r first last <<< "$spec"
    (( 10#$first >= 1 && 10#$first < 65535 && 10#$last <= 65535 && 10#$last > 10#$first )) || return 1
  else
    return 1
  fi
}


# Check both listener inventories before certificate issuance or UDP binding.
# A failed ss invocation is not evidence that a port is free.
hy2_check_listener_conflicts() {
  local first_port="$1" last_port="$2" udp_sockets tcp_sockets
  if ! udp_sockets="$(ss -H -lunp 2>/dev/null)"; then
    ah_err "Could not inspect UDP listeners; refusing to assume the requested port range is free."
    return 1
  fi
  if ! tcp_sockets="$(ss -H -ltn 2>/dev/null)"; then
    ah_err "Could not inspect TCP listeners; refusing to assume port 80 is free."
    return 1
  fi
  if awk -v first="$first_port" -v last="$last_port" '
    {
      endpoint=$4
      sub(/^.*:/, "", endpoint)
      if (endpoint ~ /^[0-9]+$/ && (endpoint + 0) >= (first + 0) && (endpoint + 0) <= (last + 0)) found=1
    }
    END {exit !found}
  ' <<< "$udp_sockets"; then
    ah_err "A UDP listener already uses a port in the requested range. Choose another range."
    return 1
  fi
  if awk '
    {
      endpoint=$4
      sub(/^.*:/, "", endpoint)
      if (endpoint == "80") found=1
    }
    END {exit !found}
  ' <<< "$tcp_sockets"; then
    ah_err "TCP port 80 is busy. Stop the conflicting web server before requesting a certificate."
    return 1
  fi
  return 0
}

hy2_write_config() {
  local output="$1" port_spec="$2" cert_dir="$3" username="$4" password="$5"
  cat > "$output" <<EOF
listen: :$port_spec
tls:
  cert: $cert_dir/fullchain.pem
  key: $cert_dir/privkey.pem
auth:
  type: userpass
  userpass:
    $username: $password
EOF
}

hy2_write_renewal_hook() {
  local output="$1" domain="$2" source_tmp target_tmp output_dir
  output_dir="$(dirname -- "$output")"
  source_tmp="$(mktemp)" || return 1
  target_tmp="$(mktemp "$output_dir/.africhome-hysteria-hook.XXXXXX")" || { rm -f -- "$source_tmp"; return 1; }
  cat > "$source_tmp" <<'HOOK'
#!/usr/bin/env bash
set -Eeuo pipefail
DOMAIN="@@DOMAIN@@"
DEST="/etc/hysteria/certs"
SRC="/etc/letsencrypt/live/$DOMAIN"
[[ -s "$SRC/fullchain.pem" && -s "$SRC/privkey.pem" ]] || exit 1
install -d -o hysteria -g hysteria -m 750 "$DEST"
[[ ! -L "$DEST/fullchain.pem" && ! -L "$DEST/privkey.pem" ]] || exit 1
tmp_cert="$(mktemp "$DEST/.fullchain.XXXXXX")"
tmp_key="$(mktemp "$DEST/.privkey.XXXXXX")"
backup_cert="$(mktemp "$DEST/.fullchain.backup.XXXXXX")"
backup_key="$(mktemp "$DEST/.privkey.backup.XXXXXX")"
had_cert=0
had_key=0
pair_touched=0
preserve_backups=0
rollback() {
  rc=$?
  rollback_ok=1
  if (( rc != 0 && pair_touched )); then
    if (( had_cert )); then cp -a -- "$backup_cert" "$DEST/fullchain.pem" || rollback_ok=0
    else rm -f -- "$DEST/fullchain.pem" || rollback_ok=0
    fi
    if (( had_key )); then cp -a -- "$backup_key" "$DEST/privkey.pem" || rollback_ok=0
    else rm -f -- "$DEST/privkey.pem" || rollback_ok=0
    fi
    systemctl restart hysteria-server.service || rollback_ok=0
    if (( ! rollback_ok )); then
      preserve_backups=1
      echo "CRITICAL: Hysteria certificate rollback failed; protected backups retained in $DEST." >&2
    fi
  fi
  rm -f -- "$tmp_cert" "$tmp_key"
  if (( ! preserve_backups )); then rm -f -- "$backup_cert" "$backup_key"; fi
  exit "$rc"
}
trap rollback EXIT
if [[ -e "$DEST/fullchain.pem" || -L "$DEST/fullchain.pem" ]]; then
  [[ -s "$DEST/fullchain.pem" && -f "$DEST/fullchain.pem" && ! -L "$DEST/fullchain.pem" ]] || exit 1
  cp -a -- "$DEST/fullchain.pem" "$backup_cert"
  had_cert=1
fi
if [[ -e "$DEST/privkey.pem" || -L "$DEST/privkey.pem" ]]; then
  [[ -s "$DEST/privkey.pem" && -f "$DEST/privkey.pem" && ! -L "$DEST/privkey.pem" ]] || exit 1
  cp -a -- "$DEST/privkey.pem" "$backup_key"
  had_key=1
fi
[[ "$had_cert" == "$had_key" ]] || { echo "Existing Hysteria certificate pair is incomplete." >&2; exit 1; }
install -o hysteria -g hysteria -m 640 "$SRC/fullchain.pem" "$tmp_cert"
install -o hysteria -g hysteria -m 640 "$SRC/privkey.pem" "$tmp_key"
openssl x509 -in "$tmp_cert" -noout
openssl pkey -in "$tmp_key" -noout
cert_pub="$(openssl x509 -in "$tmp_cert" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')"
key_pub="$(openssl pkey -in "$tmp_key" -pubout -outform DER | sha256sum | awk '{print $1}')"
[[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || { echo "Renewed Hysteria certificate and private key do not match." >&2; exit 1; }
pair_touched=1
mv -f -- "$tmp_cert" "$DEST/fullchain.pem"
mv -f -- "$tmp_key" "$DEST/privkey.pem"
systemctl restart hysteria-server.service
trap - EXIT
rm -f -- "$backup_cert" "$backup_key"
HOOK
  if ! sed "s/@@DOMAIN@@/$domain/g" "$source_tmp" > "$target_tmp" ||
     ! chmod 0750 "$target_tmp" || ! bash -n "$target_tmp" ||
     ! mv -f -- "$target_tmp" "$output"; then
    rm -f -- "$source_tmp" "$target_tmp"
    return 1
  fi
  rm -f -- "$source_tmp"
}

hy2_install() {
  ah_require_root || return 1
  command -v curl >/dev/null 2>&1 || ah_apt_install curl ca-certificates || return 1
  command -v git >/dev/null 2>&1 || ah_apt_install git || return 1
  command -v sha256sum >/dev/null 2>&1 || { ah_err "sha256sum is required."; return 1; }

  local arch asset_sha installer_url binary_url tmpdir backup_dir installer binary installer_sha
  local old_binary=0 old_unit=0 old_template=0 old_config=0 rollback_ok=1 installed_sha installed_version existing_user
  case "$(uname -m)" in
    x86_64|amd64)
      arch="amd64"
      asset_sha="fc25edff9948708cb00a4ff01f3bccde677660aca050133bb1ad46c6860362d2"
      ;;
    aarch64|arm64)
      arch="arm64"
      asset_sha="e7c52241299fe85aba11e9d36e85d8d88ddbb5799ac0e33d272219d20e313bab"
      ;;
    armv7l|armv7)
      arch="arm"
      asset_sha="50a7a9ac1ab0660ebfae0651f03faa234c7d99d0701806e10a7f5060857647ab"
      ;;
    i386|i686)
      arch="386"
      asset_sha="a30c618690b4aecf521c10ea2ec199aa13cff54696d3cecd5fa4502abdb2985a"
      ;;
    *)
      ah_err "Unsupported Hysteria architecture: $(uname -m)"
      return 1
      ;;
  esac

  if [[ -s /etc/systemd/system/hysteria-server.service ]]; then
    existing_user="$(sed -n 's/^User=//p' /etc/systemd/system/hysteria-server.service | tail -n1)"
    if [[ -n "$existing_user" && "$existing_user" != "hysteria" ]]; then
      ah_err "Existing Hysteria service runs as '$existing_user'. Africhome currently requires the official hysteria service user; refusing to change it automatically."
      return 1
    fi
    existing_user="$(sed -n 's/^Group=//p' /etc/systemd/system/hysteria-server.service | tail -n1)"
    if [[ -n "$existing_user" && "$existing_user" != "hysteria" ]]; then
      ah_err "Existing Hysteria service runs as group '$existing_user'. Africhome currently requires the official hysteria group; refusing to change it automatically."
      return 1
    fi
  fi

  tmpdir="$(mktemp -d)" || { ah_err "Could not create Hysteria install workspace."; return 1; }
  install -d -m 0700 /var/backups || { rm -rf -- "$tmpdir"; return 1; }
  backup_dir="$(mktemp -d /var/backups/africhome-hysteria-install.XXXXXX)" || { rm -rf -- "$tmpdir"; return 1; }
  chmod 0700 "$backup_dir"
  installer="$tmpdir/install_server.sh"
  binary="$tmpdir/hysteria-linux-$arch"
  installer_url="https://raw.githubusercontent.com/HyNetworks/hysteria/$HY2_INSTALLER_COMMIT/scripts/install_server.sh"
  binary_url="https://github.com/HyNetworks/hysteria/releases/download/app/$HY2_VERSION/hysteria-linux-$arch"

  if [[ -e /usr/local/bin/hysteria || -L /usr/local/bin/hysteria ]]; then
    [[ -f /usr/local/bin/hysteria && ! -L /usr/local/bin/hysteria ]] || { ah_err "Existing Hysteria executable is not a regular file."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    cp -a -- /usr/local/bin/hysteria "$backup_dir/hysteria" || { ah_err "Could not back up existing Hysteria executable."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    old_binary=1
  fi
  if [[ -e /etc/systemd/system/hysteria-server.service || -L /etc/systemd/system/hysteria-server.service ]]; then
    [[ -f /etc/systemd/system/hysteria-server.service && ! -L /etc/systemd/system/hysteria-server.service ]] || { ah_err "Existing Hysteria service unit is unsafe."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    cp -a -- /etc/systemd/system/hysteria-server.service "$backup_dir/hysteria-server.service" || { ah_err "Could not back up Hysteria service unit."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    old_unit=1
  fi
  if [[ -e /etc/systemd/system/hysteria-server@.service || -L /etc/systemd/system/hysteria-server@.service ]]; then
    [[ -f /etc/systemd/system/hysteria-server@.service && ! -L /etc/systemd/system/hysteria-server@.service ]] || { ah_err "Existing Hysteria template unit is unsafe."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    cp -a -- /etc/systemd/system/hysteria-server@.service "$backup_dir/hysteria-server@.service" || { ah_err "Could not back up Hysteria template unit."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    old_template=1
  fi
  if [[ -e "$HY2_CONFIG" || -L "$HY2_CONFIG" ]]; then
    [[ -f "$HY2_CONFIG" && ! -L "$HY2_CONFIG" ]] || { ah_err "Existing Hysteria config is unsafe."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    getent group hysteria >/dev/null 2>&1 || { ah_err "Existing Hysteria config is present but the hysteria group is missing; refusing to change its permissions."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    cp -a -- "$HY2_CONFIG" "$backup_dir/config.yaml" || { ah_err "Could not back up existing Hysteria config."; rm -rf -- "$tmpdir" "$backup_dir"; return 1; }
    old_config=1
  fi

  if ! curl -fL --retry 3 "$installer_url" -o "$installer"; then
    ah_err "Could not download the pinned Hysteria installer."
    rm -rf -- "$tmpdir" "$backup_dir"
    return 1
  fi
  installer_sha="$(git hash-object "$installer")"
  if [[ "$installer_sha" != "$HY2_INSTALLER_BLOB_SHA" ]]; then
    ah_err "Pinned Hysteria installer integrity check failed."
    rm -rf -- "$tmpdir" "$backup_dir"
    return 1
  fi
  if ! curl -fL --retry 3 "$binary_url" -o "$binary"; then
    ah_err "Could not download Hysteria $HY2_VERSION for linux/$arch."
    rm -rf -- "$tmpdir" "$backup_dir"
    return 1
  fi
  if ! printf '%s  %s\n' "$asset_sha" "$binary" | sha256sum -c -; then
    ah_err "Hysteria binary checksum mismatch; refusing to install."
    rm -rf -- "$tmpdir" "$backup_dir"
    return 1
  fi
  chmod 0755 "$binary"

  if (( old_config )); then
    chown root:hysteria "$HY2_CONFIG" && chmod 0640 "$HY2_CONFIG" || {
      cp -a -- "$backup_dir/config.yaml" "$HY2_CONFIG" || ah_err "CRITICAL: failed to restore Hysteria config permissions."
      rm -rf -- "$tmpdir" "$backup_dir"
      return 1
    }
  fi

  hy2_rollback_install() {
    local restore_tmp
    if (( old_binary )); then
      restore_tmp="$(mktemp /usr/local/bin/.hysteria.restore.XXXXXX)" || rollback_ok=0
      if (( rollback_ok )); then
        cp -a -- "$backup_dir/hysteria" "$restore_tmp" || rollback_ok=0
        (( rollback_ok )) && mv -f -- "$restore_tmp" /usr/local/bin/hysteria || rollback_ok=0
      fi
      [[ -z "${restore_tmp:-}" ]] || rm -f -- "$restore_tmp"
    else
      rm -f -- /usr/local/bin/hysteria || rollback_ok=0
    fi
    if (( old_unit )); then
      cp -a -- "$backup_dir/hysteria-server.service" /etc/systemd/system/hysteria-server.service || rollback_ok=0
    else
      rm -f -- /etc/systemd/system/hysteria-server.service || rollback_ok=0
    fi
    if (( old_template )); then
      cp -a -- "$backup_dir/hysteria-server@.service" /etc/systemd/system/hysteria-server@.service || rollback_ok=0
    else
      rm -f -- /etc/systemd/system/hysteria-server@.service || rollback_ok=0
    fi
    if (( old_config )); then
      cp -a -- "$backup_dir/config.yaml" "$HY2_CONFIG" || rollback_ok=0
    else
      rm -f -- "$HY2_CONFIG" || rollback_ok=0
    fi
    systemctl daemon-reload || rollback_ok=0
    systemctl restart hysteria-server.service >/dev/null 2>&1 || true
    rm -rf -- "$tmpdir"
    if (( rollback_ok )); then
      rm -rf -- "$backup_dir"
      ah_err "Hysteria installation failed; previous executable and service units were restored."
    else
      ah_err "CRITICAL: Hysteria installation and rollback failed. Protected backups retained at $backup_dir."
    fi
    return 1
  }

  ah_info "Installing pinned Hysteria $HY2_VERSION using its verified official installer..."
  if ! bash "$installer" --local "$binary"; then
    hy2_rollback_install
    return 1
  fi
  if ! getent passwd hysteria >/dev/null 2>&1 || ! getent group hysteria >/dev/null 2>&1 ||
     [[ ! -f "$HY2_CONFIG" || -L "$HY2_CONFIG" ]] ||
     ! chown root:hysteria "$HY2_CONFIG" || ! chmod 0640 "$HY2_CONFIG"; then
    ah_err "Hysteria service user, group, or protected config permissions are not ready."
    hy2_rollback_install
    return 1
  fi
  [[ -f /usr/local/bin/hysteria && ! -L /usr/local/bin/hysteria ]] || {
    hy2_rollback_install
    return 1
  }
  installed_sha="$(sha256sum /usr/local/bin/hysteria | awk '{print $1}')"
  installed_version="$(/usr/local/bin/hysteria version 2>&1 || true)"
  if [[ "$installed_sha" != "$asset_sha" || "$installed_version" != *"$HY2_VERSION"* ]]; then
    ah_err "Installed Hysteria binary did not match the pinned release."
    hy2_rollback_install
    return 1
  fi

  rm -rf -- "$tmpdir" "$backup_dir"
  ah_ok "Verified Hysteria $HY2_VERSION installed for linux/$arch."
}

hy2_setup() {
  ah_require_root || return 1
  command -v hysteria >/dev/null 2>&1 || { ah_warn "Install Hysteria 2 first."; return 1; }
  command -v certbot >/dev/null 2>&1 || ah_apt_install certbot || return 1
  command -v ss >/dev/null 2>&1 || ah_apt_install iproute2 || return 1
  command -v openssl >/dev/null 2>&1 || ah_apt_install openssl || return 1
  local domain email port_spec first_port last_port ufw_port_spec username password backup="" config_tmp hook_tmp replace
  read -r -p "Your domain (DNS A/AAAA must point to this VPS): " domain
  domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
  hy2_valid_domain "$domain" || { ah_err "Invalid domain name."; return 1; }
  read -r -p "UDP port or port-hopping range [443]: " port_spec
  [[ -n "$port_spec" ]] || port_spec="443"
  hy2_valid_port_spec "$port_spec" || { ah_err "Use a UDP port 1-65535 or range such as 20000-30000."; return 1; }
  first_port="$(printf '%s' "$port_spec" | cut -d- -f1)"
  last_port="$(printf '%s' "$port_spec" | awk -F- '{print $NF}')"
  ufw_port_spec="$port_spec"
  if [[ "$port_spec" == *-* ]]; then
    ufw_port_spec="$first_port:$last_port"
    if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
      ah_info "Installing nftables for Hysteria port hopping..."
      ah_apt_install nftables || return 1
    fi
  fi
  read -r -p "Email for Let's Encrypt: " email
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { ah_err "Enter a valid email address."; return 1; }
  read -r -p "Hysteria username [africhome]: " username
  [[ -n "$username" ]] || username="africhome"
  [[ "$username" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { ah_err "Invalid username."; return 1; }
  password="$(openssl rand -hex 24)" || { ah_err "Could not generate password."; return 1; }

  if [[ -e "$HY2_CONFIG" ]]; then
    backup="$HY2_CONFIG.africhome-backup-$(date +%Y%m%d%H%M%S)"
    cp -a "$HY2_CONFIG" "$backup" || { ah_err "Could not back up existing Hysteria config."; return 1; }
    ah_warn "Existing config backup: $backup"
    read -r -p "Replace existing Hysteria config? [y/N]: " replace
    [[ "$replace" =~ ^[Yy]$ ]] || { ah_info "Existing config left unchanged."; return 1; }
  fi
  hy2_check_listener_conflicts "$first_port" "$last_port" || return 1

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow 80/tcp || ah_warn "Could not add TCP 80 to UFW; certificate issuance/renewal may fail."
  fi
  ah_info "Requesting a certificate. DNS must point to this VPS and inbound TCP 80 must be reachable."
  certbot certonly --standalone --non-interactive --agree-tos --email "$email" -d "$domain" || {
    ah_err "Certificate issuance failed. Check DNS and TCP 80 in UFW/provider firewall."; return 1;
  }
  [[ -s "/etc/letsencrypt/live/$domain/fullchain.pem" && -s "/etc/letsencrypt/live/$domain/privkey.pem" ]] || {
    ah_err "Certificate files were not created."; return 1;
  }
  getent passwd hysteria >/dev/null 2>&1 || { ah_err "Hysteria service user missing. Re-run the official installer."; return 1; }
  getent group hysteria >/dev/null 2>&1 || { ah_err "Hysteria service group missing. Re-run the official installer."; return 1; }
  install -d -o hysteria -g hysteria -m 750 "$HY2_CERT_DIR"
  install -o hysteria -g hysteria -m 640 "/etc/letsencrypt/live/$domain/fullchain.pem" "$HY2_CERT_DIR/fullchain.pem"
  install -o hysteria -g hysteria -m 640 "/etc/letsencrypt/live/$domain/privkey.pem" "$HY2_CERT_DIR/privkey.pem"

  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  hy2_write_renewal_hook "$HY2_HOOK" "$domain"

  config_tmp="$(mktemp)"
  hy2_write_config "$config_tmp" "$port_spec" "$HY2_CERT_DIR" "$username" "$password"
  install -o root -g hysteria -m 640 "$config_tmp" "$HY2_CONFIG"
  rm -f "$config_tmp"
  if ! systemctl daemon-reload || ! systemctl enable hysteria-server.service || ! systemctl restart hysteria-server.service; then
    ah_err "Hysteria failed to start. Restoring the previous configuration when available."
    if [[ -n "$backup" && -s "$backup" ]]; then
      cp -a "$backup" "$HY2_CONFIG"
      systemctl restart hysteria-server.service || true
    fi
    return 1
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$ufw_port_spec/udp" || ah_warn "Could not add UDP $port_spec to UFW."
  fi
  umask 077
  printf 'HY2_DOMAIN=%q\nHY2_PORT_SPEC=%q\nHY2_USERNAME=%q\nHY2_PASSWORD=%q\n' "$domain" "$port_spec" "$username" "$password" > "$HY2_STATE"
  chmod 600 "$HY2_STATE"
  ah_ok "Hysteria 2 configured and running."
  echo "Domain: $domain"
  echo "UDP port/range: $port_spec"
  echo "Username: $username"
  echo "Password: $password"
  ah_info "Open UDP $port_spec in your VPS provider firewall too."
  [[ "$port_spec" != *-* ]] || ah_info "Port hopping requires nftables/iptables and CAP_NET_ADMIN; the official systemd unit includes the required capabilities."
  ah_warn "Save the password securely. Never commit client credentials to Git."
}

hy2_show_client() {
  [[ -r "$HY2_STATE" ]] || { ah_warn "Configure Hysteria 2 first."; return 1; }
  # shellcheck disable=SC1090
  . "$HY2_STATE"
  echo
  printf 'hysteria2://%s:%s@%s:%s/?sni=%s#Africhome-Hysteria2\n' "$HY2_USERNAME" "$HY2_PASSWORD" "$HY2_DOMAIN" "$HY2_PORT_SPEC" "$HY2_DOMAIN"
  ah_warn "This URI contains the account password. Keep it private. Configure the same port range in a compatible client when using port hopping."
}
hy2_status() {
  ah_require_root || return 1
  systemctl --no-pager --full status hysteria-server.service || true
  journalctl -u hysteria-server.service -n 30 --no-pager 2>/dev/null || true
}
hy2_menu() {
  while true; do
    echo
    echo "----- Hysteria 2 Management -----"
    echo "1) Install/update Hysteria 2"
    echo "2) Configure custom domain and UDP port/range"
    echo "3) Show client import URI"
    echo "4) Service status and logs"
    echo "5) Restart Hysteria 2"
    echo "6) Hysteria user account management"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) hy2_install; ah_pause ;;
      2) hy2_setup; ah_pause ;;
      3) hy2_show_client; ah_pause ;;
      4) hy2_status; ah_pause ;;
      5) ah_require_root && systemctl restart hysteria-server.service; ah_pause ;;
      6) hy2u_menu ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
