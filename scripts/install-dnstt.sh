#!/usr/bin/env bash
# Build the official DNSTT server/client and create a local keypair.
# This bootstrap deliberately does NOT stop iodine, bind UDP/53, change DNS,
# change firewall rules, or install/start a DNSTT systemd service.
set -Eeuo pipefail

DNSTT_REPO="https://www.bamsoftware.com/git/dnstt.git"
DNSTT_SRC="/opt/dnstt-src"
KEY_DIR="/etc/africhome-dnstt"
GO_VERSION="1.27.4"
GO_SHA256="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }

[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash scripts/install-dnstt.sh"
[[ "$(uname -s)" == "Linux" ]] || fail "Linux is required."
[[ "$(uname -m)" == "x86_64" ]] || fail "This bootstrap currently supports x86_64/amd64 only."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git tar

go_is_new_enough() {
  local bin="$1" version major minor
  [[ -x "$bin" ]] || return 1
  version="$("$bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
  [[ -n "$version" ]] || return 1
  IFS=. read -r major minor _ <<< "${version%%-*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > 1 || (major == 1 && minor >= 21) ))
}

GO_BIN=""
if go_is_new_enough /usr/local/go/bin/go; then
  GO_BIN="/usr/local/go/bin/go"
elif command -v go >/dev/null 2>&1 && go_is_new_enough "$(command -v go)"; then
  GO_BIN="$(command -v go)"
else
  info "Installing verified Go ${GO_VERSION} toolchain..."
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  archive="$tmpdir/go.linux-amd64.tar.gz"
  curl -fL --retry 3 "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o "$archive"
  printf '%s  %s\n' "$GO_SHA256" "$archive" | sha256sum -c - || fail "Go archive checksum mismatch."
  stage="$tmpdir/go"
  install -d -m 0755 "$stage"
  tar -C "$stage" --strip-components=1 -xzf "$archive"
  [[ -x "$stage/bin/go" ]] || fail "Go extraction did not produce a working toolchain."
  if [[ -d /usr/local/go ]]; then
    mv /usr/local/go "/usr/local/go.backup.$(date +%Y%m%d%H%M%S)"
  fi
  mv "$stage" /usr/local/go
  GO_BIN="/usr/local/go/bin/go"
  trap - EXIT
  rm -rf "$tmpdir"
fi

info "Using $("$GO_BIN" version)"

if [[ -e "$DNSTT_SRC" && ! -d "$DNSTT_SRC/.git" ]]; then
  fail "$DNSTT_SRC exists but is not a Git checkout; move it aside and retry."
fi
if [[ ! -d "$DNSTT_SRC/.git" ]]; then
  git clone "$DNSTT_REPO" "$DNSTT_SRC"
else
  info "Using existing DNSTT source checkout at $DNSTT_SRC (not updating it automatically)."
fi

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required."
install -d -m 0755 /usr/local/bin
build_tmp="$(mktemp -d)"
trap 'rm -rf "$build_tmp"' EXIT
(
  cd "$DNSTT_SRC/dnstt-server"
  GOTOOLCHAIN=local "$GO_BIN" build -trimpath -o "$build_tmp/dnstt-server" .
)
(
  cd "$DNSTT_SRC/dnstt-client"
  GOTOOLCHAIN=local "$GO_BIN" build -trimpath -o "$build_tmp/dnstt-client" .
)
install -m 0755 "$build_tmp/dnstt-server" /usr/local/bin/dnstt-server.new
install -m 0755 "$build_tmp/dnstt-client" /usr/local/bin/dnstt-client.new
mv -f /usr/local/bin/dnstt-server.new /usr/local/bin/dnstt-server
mv -f /usr/local/bin/dnstt-client.new /usr/local/bin/dnstt-client
rm -rf "$build_tmp"
trap - EXIT

install -d -m 0700 "$KEY_DIR"
if [[ -e "$KEY_DIR/server.key" && -e "$KEY_DIR/server.pub" ]]; then
  info "Existing DNSTT keypair found; preserving it."
elif [[ ! -e "$KEY_DIR/server.key" && ! -e "$KEY_DIR/server.pub" ]]; then
  umask 077
  /usr/local/bin/dnstt-server -gen-key \
    -privkey-file "$KEY_DIR/server.key" \
    -pubkey-file "$KEY_DIR/server.pub"
else
  fail "Only one DNSTT key file exists. Back it up and repair the pair manually; refusing to overwrite."
fi
chmod 0600 "$KEY_DIR/server.key"
chmod 0644 "$KEY_DIR/server.pub"

[[ -x /usr/local/bin/dnstt-server && -x /usr/local/bin/dnstt-client ]] || fail "DNSTT binaries are missing."
[[ -s "$KEY_DIR/server.key" && -s "$KEY_DIR/server.pub" ]] || fail "DNSTT keypair is incomplete."

ok "DNSTT server and client built."
ok "DNSTT keypair is ready in $KEY_DIR (private key mode 600)."
printf 'Source commit: %s\n' "$(git -C "$DNSTT_SRC" rev-parse --short HEAD)"
printf 'Public key: '
cat "$KEY_DIR/server.pub"
echo
info "No DNS, firewall, UDP/53, iodine, or systemd service settings were changed."
info "Next: configure and externally test DNSTT before any SlowDNS migration."
