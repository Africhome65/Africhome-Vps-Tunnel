#!/usr/bin/env bash
# Loopback-only TLS wrapper backend for SSH. Public SNI routing remains a
# separate central-router task; this module never binds public TCP 80/443.
set -Eeuo pipefail

SSH_TLS_CONFIG_DIR="${SSH_TLS_CONFIG_DIR:-/etc/stunnel}"
SSH_TLS_CONFIG="${SSH_TLS_CONFIG:-$SSH_TLS_CONFIG_DIR/africhome-ssh.conf}"
SSH_TLS_UNIT="${SSH_TLS_UNIT:-/etc/systemd/system/africhome-ssh-tls.service}"
SSH_TLS_BACKEND_PORT="${SSH_TLS_BACKEND_PORT:-12222}"
SSH_TLS_SERVICE="africhome-ssh-tls.service"

ssh_tls_error(){ ah_err "$*"; }
ssh_tls_valid_port(){
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#${1} >= 1024 && 10#${1} <= 65535 ))
}
ssh_tls_valid_hostname(){
  local value="${1:-}"
  (( ${#value} <= 253 )) || return 1
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}
ssh_tls_resolve_material(){
  local path="${1:-}" resolved
  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  if [[ -L "$path" ]]; then
    [[ "$path" == /etc/letsencrypt/live/* ]] || return 1
    resolved="$(readlink -f -- "$path")" || return 1
    [[ "$resolved" == /etc/letsencrypt/archive/* && -f "$resolved" && ! -L "$resolved" ]] || return 1
  else
    [[ -f "$path" && ! -L "$path" ]] || return 1
    resolved="$path"
  fi
  printf '%s' "$resolved"
}
ssh_tls_check_certificate(){
  local host="$1" cert="$2" key="$3" cert_real key_real cert_pub key_pub
  [[ "$cert" =~ ^/[A-Za-z0-9._/-]+$ ]] || { ssh_tls_error "Certificate path contains unsupported characters."; return 1; }
  [[ "$key" =~ ^/[A-Za-z0-9._/-]+$ ]] || { ssh_tls_error "Private-key path contains unsupported characters."; return 1; }
  cert_real="$(ssh_tls_resolve_material "$cert")" || { ssh_tls_error "Certificate must be a regular file or a valid Let's Encrypt live symlink."; return 1; }
  key_real="$(ssh_tls_resolve_material "$key")" || { ssh_tls_error "Private key must be a regular file or a valid Let's Encrypt live symlink."; return 1; }
  [[ -r "$cert_real" && -r "$key_real" ]] || { ssh_tls_error "Certificate and key must be readable by root."; return 1; }
  [[ "$(stat -c '%u:%a' -- "$key_real" 2>/dev/null)" == "0:600" ]] || { ssh_tls_error "Private key must be root-owned with mode 0600."; return 1; }
  openssl x509 -in "$cert" -noout -checkhost "$host" >/dev/null 2>&1 || { ssh_tls_error "Certificate does not cover SNI hostname $host."; return 1; }
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || { ssh_tls_error "Certificate is expired or invalid."; return 1; }
  openssl pkey -in "$key" -passin pass: -noout >/dev/null 2>&1 || { ssh_tls_error "Private key must be an unencrypted PEM key readable by root."; return 1; }
  cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" || return 1
  key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" || return 1
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || { ssh_tls_error "Certificate and private key do not match."; return 1; }
}
ssh_tls_port_available(){
  local port="$1" output
  if ! output="$(ss -H -ltn 2>/dev/null)"; then
    ssh_tls_error "Could not inspect TCP listeners; refusing to assume port $port is free."
    return 1
  fi
  if awk -v p="$port" '
    {
      endpoint=$4
      sub(/^.*:/, "", endpoint)
      if (endpoint == p) found=1
    }
    END {exit !found}
  ' <<< "$output"; then
    return 1
  fi
  return 0
}

# Configuration directories must be real, root-owned, and not group/world-writable.
ssh_tls_safe_directory(){
  local dir="${1:-}" metadata owner mode
  [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || return 1
  metadata="$(stat -c '%u:%a' -- "$dir" 2>/dev/null)" || return 1
  owner="${metadata%%:*}"
  mode="${metadata#*:}"
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}
ssh_tls_write_config(){
  local output="$1" port="$2" cert="$3" key="$4"
  cat > "$output" <<EOF
foreground = yes
debug = notice
setuid = nobody
setgid = nogroup

[africhome-ssh]
client = no
accept = 127.0.0.1:$port
connect = 127.0.0.1:22
cert = $cert
key = $key
sslVersionMin = TLSv1.2
EOF
}
ssh_tls_write_unit(){
  local output="$1"
  cat > "$output" <<'EOF'
[Unit]
Description=Africhome SSH over TLS loopback backend
After=network.target ssh.service
Wants=ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/stunnel4 /etc/stunnel/africhome-ssh.conf
Restart=on-failure
RestartSec=3
TimeoutStartSec=30
TimeoutStopSec=15
KillMode=control-group
TasksMax=64
LimitNOFILE=4096
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
}
ssh_tls_install_packages(){
  ah_require_root || return 1
  ah_apt_install stunnel4 openssl iproute2 || return 1
  command -v stunnel4 >/dev/null 2>&1 || { ssh_tls_error "stunnel4 executable not found."; return 1; }
  ah_ok "stunnel4 backend dependencies installed."
}
# Roll back only files created by this attempt, and never remove config
# while the backend may still be running.
ssh_tls_rollback_failed_start(){
  local config="$1" unit="$2"
  systemctl stop "$SSH_TLS_SERVICE" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$SSH_TLS_SERVICE" 2>/dev/null; then
    ssh_tls_error "CRITICAL: SSH TLS backend remains active; config and unit were retained for manual recovery."
    return 1
  fi
  if systemctl is-enabled --quiet "$SSH_TLS_SERVICE" 2>/dev/null; then
    systemctl disable "$SSH_TLS_SERVICE" >/dev/null 2>&1 || {
      ssh_tls_error "Could not disable the failed SSH TLS unit; config and unit were retained."
      return 1
    }
  fi
  rm -f -- "$config" "$unit" || {
    ssh_tls_error "Could not remove failed SSH TLS config/unit; inspect them manually."
    return 1
  }
  systemctl daemon-reload >/dev/null 2>&1 || ah_warn "systemd daemon-reload failed after SSH TLS rollback."
  return 0
}

ssh_tls_configure(){
  ah_require_root || return 1
  command -v stunnel4 >/dev/null 2>&1 || { ssh_tls_error "Install stunnel4 first."; return 1; }
  command -v openssl >/dev/null 2>&1 || { ssh_tls_error "OpenSSL is required."; return 1; }
  command -v ss >/dev/null 2>&1 || { ssh_tls_error "iproute2 is required."; return 1; }
  [[ ! -L "$SSH_TLS_CONFIG_DIR" && ! -L "$SSH_TLS_CONFIG" && ! -L "$SSH_TLS_UNIT" ]] || {
    ssh_tls_error "stunnel config/unit paths must not be symlinks."; return 1;
  }
  [[ ! -e "$SSH_TLS_CONFIG" && ! -e "$SSH_TLS_UNIT" ]] || {
    ssh_tls_error "An Africhome SSH TLS config or unit already exists; refusing to overwrite."; return 1;
  }
  [[ ! -L /usr/bin/stunnel4 && -x /usr/bin/stunnel4 ]] || { ssh_tls_error "Expected /usr/bin/stunnel4 executable is missing or unsafe."; return 1; }
  if systemctl is-active --quiet "$SSH_TLS_SERVICE" 2>/dev/null; then
    ssh_tls_error "SSH TLS backend is already active."; return 1
  fi
  if systemctl is-enabled --quiet "$SSH_TLS_SERVICE" 2>/dev/null; then
    ssh_tls_error "SSH TLS backend is already enabled but inactive; review its existing unit before setup."
    return 1
  fi
  local host cert key port conf_tmp unit_tmp
  read -r -p "SSH TLS certificate hostname (SNI): " host
  ssh_tls_valid_hostname "$host" || { ssh_tls_error "Invalid SNI hostname."; return 1; }
  read -r -p "Full path to TLS certificate (PEM): " cert
  read -r -p "Full path to matching private key (PEM): " key
  ssh_tls_check_certificate "$host" "$cert" "$key" || return 1
  read -r -p "Loopback backend port [12222]: " port
  port="${port:-12222}"
  ssh_tls_valid_port "$port" || { ssh_tls_error "Backend port must be 1024-65535."; return 1; }
  ssh_tls_port_available "$port" || { ssh_tls_error "TCP port $port is already in use."; return 1; }
  timeout 3 bash -c ':</dev/tcp/127.0.0.1/22' >/dev/null 2>&1 || {
    ssh_tls_error "SSH is not reachable at 127.0.0.1:22. Ensure sshd listens locally before setup."; return 1;
  }
  if [[ ! -d "$SSH_TLS_CONFIG_DIR" ]]; then install -d -m 0755 "$SSH_TLS_CONFIG_DIR" || return 1; fi
  ssh_tls_safe_directory "$SSH_TLS_CONFIG_DIR" || { ssh_tls_error "stunnel config directory must be root-owned and not group/world-writable."; return 1; }
  ssh_tls_safe_directory /etc/systemd/system || { ssh_tls_error "systemd unit directory must be root-owned and not group/world-writable."; return 1; }
  conf_tmp="$(mktemp "$SSH_TLS_CONFIG_DIR/.africhome-ssh.XXXXXX")" || return 1
  unit_tmp="$(mktemp /etc/systemd/system/.africhome-ssh-tls.XXXXXX)" || { rm -f "$conf_tmp"; return 1; }
  ssh_tls_write_config "$conf_tmp" "$port" "$cert" "$key"
  ssh_tls_write_unit "$unit_tmp"
  chmod 0600 "$conf_tmp"
  chown root:root "$conf_tmp" "$unit_tmp"
  chmod 0644 "$unit_tmp"
  if ! mv -n -- "$conf_tmp" "$SSH_TLS_CONFIG" || [[ -e "$conf_tmp" ]]; then
    rm -f "$conf_tmp" "$unit_tmp"
    ssh_tls_error "Could not safely install stunnel config."; return 1
  fi
  if ! mv -n -- "$unit_tmp" "$SSH_TLS_UNIT" || [[ -e "$unit_tmp" ]]; then
    rm -f "$unit_tmp" "$SSH_TLS_CONFIG"
    ssh_tls_error "Could not safely install systemd unit."; return 1
  fi
  if ! systemctl daemon-reload || ! systemctl enable --now "$SSH_TLS_SERVICE" ||
     ! systemctl is-active --quiet "$SSH_TLS_SERVICE"; then
    if ssh_tls_rollback_failed_start "$SSH_TLS_CONFIG" "$SSH_TLS_UNIT"; then
      ssh_tls_error "SSH TLS backend failed to start; its new files were rolled back."
    else
      ssh_tls_error "SSH TLS startup failed and automatic rollback was incomplete. Inspect the active service and retained files."
    fi
    journalctl -u "$SSH_TLS_SERVICE" -n 30 --no-pager 2>/dev/null || true
    return 1
  fi
  ah_ok "SSH TLS backend is active on 127.0.0.1:$port."
  ah_info "It forwards decrypted SSH traffic to 127.0.0.1:22."
  ah_info "For central routing, add SNI $host -> 127.0.0.1:$port to the candidate manifest."
  ah_warn "This is an SSH-over-TLS backend only. It does not implement HTTP payload, HTTP CONNECT proxy, or public TCP 443 routing."
}
ssh_tls_status(){
  ah_require_root || return 1
  systemctl --no-pager --full status "$SSH_TLS_SERVICE" || true
  journalctl -u "$SSH_TLS_SERVICE" -n 25 --no-pager 2>/dev/null || true
}
ssh_tls_menu(){
  while true; do
    echo
    echo "----- SSH over TLS backend -----"
    echo "1) Install stunnel4 dependencies"
    echo "2) Configure loopback SSH TLS backend"
    echo "3) Service status and logs"
    echo "0) Back"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) ssh_tls_install_packages; ah_pause ;;
      2) ssh_tls_configure; ah_pause ;;
      3) ssh_tls_status; ah_pause ;;
      0) return ;;
      *) ah_warn "Invalid choice." ;;
    esac
  done
}
