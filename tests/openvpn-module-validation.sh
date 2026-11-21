#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=../modules/openvpn.sh
source "$ROOT/modules/openvpn.sh"
ah_err(){ :; }

ovpn_valid_port 1194
! ovpn_valid_port 0
! ovpn_valid_port 65536
! ovpn_valid_port abc
ovpn_valid_name client_01
! ovpn_valid_name ../escape
! ovpn_valid_name "client name"
ovpn_valid_remote vpn.example.com
ovpn_valid_remote vpn.xn--p1ai
! ovpn_valid_remote -bad.example
! ovpn_valid_remote bad-.example
! ovpn_valid_remote "$(printf 'a%.0s' {1..250}).com"
ovpn_valid_remote 192.0.2.10
! ovpn_valid_remote 999.1.1.1
! ovpn_valid_remote https://vpn.example.com
ss(){ printf 'LISTEN 0 128 0.0.0.0:1194 0.0.0.0:*\n'; }
! ovpn_port_available tcp 1194
ss(){ printf 'UNCONN 0 0 [::]:1194 [::]:*\n'; }
! ovpn_port_available udp 1194
# A longer port ending in the requested digits must not be a collision.
ss(){ printf 'LISTEN 0 128 0.0.0.0:21194 0.0.0.0:*\n'; }
ovpn_port_available tcp 1194
ss(){ :; }
ovpn_port_available tcp 1194
ovpn_port_available udp 1194
# Failed socket inspection and unsupported transports must fail closed.
ss(){ return 1; }
! ovpn_port_available tcp 1194
! ovpn_port_available sctp 1194
unset -f ss

# Subnet safety must detect broad and narrow overlaps, ignore the default
# route, and allow unrelated networks.
ip(){
  printf '%s\n' "default via 192.0.2.1 dev eth0" "10.0.0.0/8 dev docker0"
}
! ovpn_subnet_available
ip(){
  printf '%s\n' "default via 192.0.2.1 dev eth0" "10.8.0.7/32 dev tun-old"
}
! ovpn_subnet_available
# iproute2 emits host/local routes with a route-type prefix; these must
# also be treated as overlaps with the VPN pool.
ip(){
  printf '%s\n' "local 10.8.0.1 dev lo table local proto kernel scope host src 10.8.0.1"
}
! ovpn_subnet_available
ip(){
  printf '%s\n' "blackhole 10.8.0.128/25"
}
! ovpn_subnet_available
ip(){
  printf '%s\n' "default via 192.0.2.1 dev eth0" "192.168.0.0/16 dev eth0"
}
ovpn_subnet_available
ip(){ return 1; }
! ovpn_subnet_available
unset -f ip

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OVPN_STATE="$TMP/state"
printf 'OVPN_REMOTE=vpn.example.com\nOVPN_PORT=1194\nOVPN_PROTO=udp\n' > "$OVPN_STATE"
chmod 0600 "$OVPN_STATE"
stat(){ printf '0:600\n'; }
ovpn_load_state
[[ "$OVPN_REMOTE" == vpn.example.com && "$OVPN_PORT" == 1194 && "$OVPN_PROTO" == udp ]]
printf 'OVPN_REMOTE=vpn.example.com\nOVPN_REMOTE=other.example.com\nOVPN_PORT=1194\nOVPN_PROTO=udp\n' > "$OVPN_STATE"
! ovpn_load_state
unset -f stat
OVPN_CLIENT_DIR="$TMP/client-export"
mkdir -m 0700 "$OVPN_CLIENT_DIR"
stat(){ printf '0:700\n'; }
ovpn_prepare_client_dir
rm -rf "$OVPN_CLIENT_DIR"
ln -s "$TMP" "$OVPN_CLIENT_DIR"
! ovpn_prepare_client_dir
unset -f stat
rm "$OVPN_CLIENT_DIR"
OVPN_EASYRSA_DIR="$TMP/easy-rsa"
OVPN_CONFIG_DIR="$TMP/server"
OVPN_CONFIG="$OVPN_CONFIG_DIR/africhome.conf"
mkdir -p "$OVPN_CONFIG_DIR" "$TMP/easy-rsa/pki/private" "$TMP/easy-rsa/pki/issued"
touch "$TMP/easy-rsa/easyrsa" "$TMP/easy-rsa/pki/private/ca.key"
chmod 0700 "$TMP/easy-rsa" "$TMP/easy-rsa/pki" "$TMP/easy-rsa/pki/private"
chmod 0600 "$TMP/easy-rsa/pki/private/ca.key"
stat(){
  local path="${@: -1}"
  if [[ -d "$path" ]]; then printf '%s\n' "${MOCK_OVPN_PKI_DIR_STAT:-0:700}"
  else printf '%s\n' "${MOCK_OVPN_PKI_FILE_STAT:-0:600}"; fi
}
ovpn_pki_paths_safe
MOCK_OVPN_PKI_DIR_STAT=1001:700
! ovpn_pki_paths_safe
unset MOCK_OVPN_PKI_DIR_STAT
MOCK_OVPN_PKI_DIR_STAT=0:777
! ovpn_pki_paths_safe
unset MOCK_OVPN_PKI_DIR_STAT
MOCK_OVPN_PKI_FILE_STAT=0:644
! ovpn_pki_paths_safe
unset MOCK_OVPN_PKI_FILE_STAT
mv "$TMP/easy-rsa/pki/private" "$TMP/private-real"
ln -s "$TMP/private-real" "$TMP/easy-rsa/pki/private"
! ovpn_pki_paths_safe
rm "$TMP/easy-rsa/pki/private"
mv "$TMP/private-real" "$TMP/easy-rsa/pki/private"
ovpn_pki_paths_safe
# Incomplete server setup cleanup removes only the newly-created runtime
# directory and an empty log directory; it never follows/removes a symlink.
ROLLBACK_RUNTIME="$TMP/rollback-runtime"
ROLLBACK_LOG="$TMP/rollback-log"
mkdir -m 0750 "$ROLLBACK_RUNTIME" "$ROLLBACK_LOG"
printf 'partial\n' > "$ROLLBACK_RUNTIME/partial"
ovpn_cleanup_unpublished_setup "$ROLLBACK_RUNTIME" "$ROLLBACK_LOG"
[[ ! -e "$ROLLBACK_RUNTIME" && ! -e "$ROLLBACK_LOG" ]]
mkdir -p "$TMP/runtime-target"
ln -s "$TMP/runtime-target" "$TMP/runtime-link"
ovpn_cleanup_unpublished_setup "$TMP/runtime-link" "$TMP/nonexistent-log"
[[ -L "$TMP/runtime-link" && -d "$TMP/runtime-target" ]]

ovpn_write_server_config "$TMP/server.conf" 1194 udp "$TMP/runtime"
grep -q '^proto udp$' "$TMP/server.conf"
grep -q "^tls-crypt $TMP/runtime/ta.key$" "$TMP/server.conf"
grep -q "^key $TMP/runtime/server.key$" "$TMP/server.conf"
grep -q "^crl-verify $TMP/runtime/crl.pem$" "$TMP/server.conf"
grep -q '^dh none$' "$TMP/server.conf"
grep -q '^explicit-exit-notify 1$' "$TMP/server.conf"

ovpn_write_server_config "$TMP/server-tcp.conf" 443 tcp "$TMP/runtime"
grep -q '^proto tcp-server$' "$TMP/server-tcp.conf"
[[ "$(ovpn_client_proto tcp)" == tcp-client ]]
[[ "$(ovpn_client_proto udp)" == udp ]]
! grep -q '^explicit-exit-notify' "$TMP/server-tcp.conf"

printf 'V\t20300101000000Z\t\t01\tunknown\t/CN=client-one\nR\t20300101000000Z\t20270101000000Z\t02\tunknown\t/CN=client-two\nV\t20300101000000Z\t\t03\tunknown\t/CN=server\n' > "$TMP/easy-rsa/pki/index.txt"
OVPN_EASYRSA_DIR="$TMP/easy-rsa"
ovpn_list_clients > "$TMP/clients.txt"
grep -q 'VALID.*client-one' "$TMP/clients.txt"
grep -q 'REVOKED.*client-two' "$TMP/clients.txt"
! grep -q 'server' "$TMP/clients.txt"
unset -f stat

# Revocation failure handling must stop the service.
OVPN_SERVICE="openvpn-server@africhome"
systemctl(){ touch "$TMP/systemctl.log"; printf '%s\n' "$*" >> "$TMP/systemctl.log"; }
ovpn_fail_closed "test CRL failure"
grep -q '^stop openvpn-server@africhome$' "$TMP/systemctl.log"
unset -f systemctl

# Easy-RSA calls must force a private umask even when the caller is permissive.
OVPN_EASYRSA_DIR="$TMP/easyrsa-umask"
mkdir -m 0700 "$OVPN_EASYRSA_DIR"
cat > "$OVPN_EASYRSA_DIR/easyrsa" <<'MOCK'
#!/usr/bin/env sh
umask > "$OVPN_UMASK_CAPTURE"
MOCK
chmod 0700 "$OVPN_EASYRSA_DIR/easyrsa"
export OVPN_UMASK_CAPTURE="$TMP/easyrsa-umask.txt"
( umask 000; ovpn_easyrsa inspect )
[[ "$(cat "$OVPN_UMASK_CAPTURE")" == 0077 ]]

# PKI initialization is staged and published only after a complete CA build.
OVPN_EASYRSA_DIR="$TMP/pki-success"
OVPN_EASYRSA_SOURCE="$TMP/easy-rsa-source"
mkdir -p "$OVPN_EASYRSA_SOURCE"
printf '#!/bin/sh\\nexit 0\\n' > "$OVPN_EASYRSA_SOURCE/easyrsa"
chmod 0700 "$OVPN_EASYRSA_SOURCE/easyrsa"
ah_require_root(){ return 0; }
ah_ok(){ :; }
ah_warn(){ :; }
ovpn_easyrsa(){
  case "$*" in
    "init-pki") mkdir -p "$OVPN_EASYRSA_DIR/pki/private"; return 0 ;;
    "--batch --req-cn=Africhome-CA build-ca nopass") printf 'test-ca-key\\n' > "$OVPN_EASYRSA_DIR/pki/private/ca.key"; return 0 ;;
    *) return 1 ;;
  esac
}
# The implementation executes Easy-RSA in the staging path; this test uses
# real shell scripts so both success and failure exercise the atomic publish.
cat > "$OVPN_EASYRSA_SOURCE/easyrsa" <<'MOCK'
#!/usr/bin/env bash
set -e
case "$*" in
  "init-pki") mkdir -p pki/private ;;
  "--batch --req-cn=Africhome-CA build-ca nopass") printf 'test-ca-key\\n' > pki/private/ca.key ;;
  "fail-build") exit 1 ;;
esac
MOCK
chmod 0700 "$OVPN_EASYRSA_SOURCE/easyrsa"
ovpn_init_pki
[[ -s "$OVPN_EASYRSA_DIR/pki/private/ca.key" ]]
[[ "$(stat -c '%a' "$OVPN_EASYRSA_DIR")" == 700 ]]
[[ "$(stat -c '%a' "$OVPN_EASYRSA_DIR/pki/private/ca.key")" == 600 ]]
! compgen -G "$TMP/.africhome-easyrsa.*" >/dev/null
OVPN_EASYRSA_DIR="$TMP/pki-failure"
OVPN_EASYRSA_SOURCE="$TMP/easy-rsa-failing"
mkdir -p "$OVPN_EASYRSA_SOURCE"
cat > "$OVPN_EASYRSA_SOURCE/easyrsa" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" != "--batch --req-cn=Africhome-CA build-ca nopass" ]]
MOCK
chmod 0700 "$OVPN_EASYRSA_SOURCE/easyrsa"
! ovpn_init_pki
[[ ! -e "$OVPN_EASYRSA_DIR" && ! -L "$OVPN_EASYRSA_DIR" ]]
! compgen -G "$TMP/.africhome-easyrsa.*" >/dev/null
unset -f ah_require_root ah_ok ah_warn ovpn_easyrsa


# End-to-end setup transaction tests with isolated paths and mocked service tools.
setup_case(){
  local root="$1"
  OVPN_EASYRSA_DIR="$root/easy-rsa"
  OVPN_CONFIG_DIR="$root/server"
  OVPN_CONFIG="$OVPN_CONFIG_DIR/africhome.conf"
  OVPN_STATE="$root/state"
  OVPN_RUNTIME_DIR="$root/runtime"
  OVPN_LOG_DIR="$root/log"
  OVPN_SERVICE="openvpn-server@africhome"
  mkdir -p "$OVPN_EASYRSA_DIR/pki/private" "$OVPN_EASYRSA_DIR/pki/issued" "$OVPN_CONFIG_DIR"
  printf 'ca cert\n' > "$OVPN_EASYRSA_DIR/pki/ca.crt"
  printf 'ca key\n' > "$OVPN_EASYRSA_DIR/pki/private/ca.key"
  printf 'server key\n' > "$OVPN_EASYRSA_DIR/pki/private/server.key"
  printf 'server cert\n' > "$OVPN_EASYRSA_DIR/pki/issued/server.crt"
  printf 'crl\n' > "$OVPN_EASYRSA_DIR/pki/crl.pem"
  printf 'tls key\n' > "$OVPN_EASYRSA_DIR/pki/ta.key"
}
ah_require_root(){ return 0; }
ah_ok(){ :; }
ah_info(){ :; }
ah_warn(){ :; }
ovpn_require_tools(){ return 0; }
ovpn_pki_paths_safe(){ return 0; }
ovpn_port_available(){ return 0; }
ip(){ :; }
chown(){ return 0; }
install(){
  local mode="" directory=0
  local -a paths=()
  while (($#)); do
    case "$1" in
      -d) directory=1; shift ;;
      -o|-g|-m) if [[ "$1" == -m ]]; then mode="$2"; fi; shift 2 ;;
      *) paths+=("$1"); shift ;;
    esac
  done
  if (( directory )); then
    mkdir -p -- "${paths[-1]}"
    [[ -z "$mode" ]] || chmod "$mode" "${paths[-1]}"
  else
    cp -- "${paths[-2]}" "${paths[-1]}"
    [[ -z "$mode" ]] || chmod "$mode" "${paths[-1]}"
  fi
}
systemctl(){
  printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
  case "$1" in
    is-active) [[ "$MOCK_ACTIVE" == 1 ]] ;;
    is-enabled) [[ "$MOCK_ENABLED" == 1 ]] ;;
    enable) MOCK_ENABLED=1 ;;
    disable) MOCK_ENABLED=0 ;;
    restart) MOCK_ACTIVE=1; [[ "$MOCK_RESTART_FAIL" != 1 ]] ;;
    stop)
      [[ "$MOCK_STOP_FAIL" != 1 ]] || return 1
      MOCK_ACTIVE=0
      ;;
    *) return 2 ;;
  esac
}
journalctl(){ :; }

# A failed start with successful stop must remove new state/runtime and preserve
# the failed config for diagnostics. It must also undo only its own enable.
SETUP_TMP="$TMP/setup-rollback"
mkdir -p "$SETUP_TMP"
setup_case "$SETUP_TMP"
export MOCK_SYSTEMCTL_LOG="$SETUP_TMP/systemctl.log"
: > "$MOCK_SYSTEMCTL_LOG"
if printf 'vpn.example.com\nudp\n1194\n' | MOCK_ACTIVE=0 MOCK_ENABLED=0 MOCK_RESTART_FAIL=1 MOCK_STOP_FAIL=0 ovpn_configure_server; then
  echo "Expected OpenVPN startup failure." >&2; exit 1
fi
[[ ! -e "$OVPN_CONFIG" && ! -e "$OVPN_STATE" && ! -e "$OVPN_RUNTIME_DIR" ]]
compgen -G "$OVPN_CONFIG.failed.*" >/dev/null
[[ ! -e "$OVPN_LOG_DIR" ]]
grep -q '^disable openvpn-server@africhome$' "$MOCK_SYSTEMCTL_LOG"

# If stop fails and OpenVPN remains active, retain all files rather than
# deleting a configuration that a live process may still depend on.
SETUP_TMP="$TMP/setup-critical"
mkdir -p "$SETUP_TMP"
setup_case "$SETUP_TMP"
: > "$MOCK_SYSTEMCTL_LOG"
if printf 'vpn.example.com\nudp\n1194\n' | MOCK_ACTIVE=0 MOCK_ENABLED=0 MOCK_RESTART_FAIL=1 MOCK_STOP_FAIL=1 ovpn_configure_server; then
  echo "Expected critical OpenVPN rollback warning." >&2; exit 1
fi
[[ -f "$OVPN_CONFIG" && -f "$OVPN_STATE" && -f "$OVPN_RUNTIME_DIR/server.key" ]]
[[ -d "$OVPN_LOG_DIR" ]]
rm -rf "$SETUP_TMP"

unset -f ah_require_root ah_ok ah_info ah_warn ovpn_require_tools ovpn_pki_paths_safe
unset -f ovpn_port_available ip chown install systemctl journalctl

echo "OpenVPN module validation passed."
