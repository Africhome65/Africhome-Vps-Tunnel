#!/usr/bin/env bash
# Build the official DNSTT server/client and create a local keypair.
# This bootstrap deliberately does NOT stop services, bind UDP/53, change DNS,
# change firewall rules, or install/start a DNSTT systemd service.
set -Eeuo pipefail

DNSTT_REPO="https://www.bamsoftware.com/git/dnstt.git"
DNSTT_TAG="v1.20260501.0"
DNSTT_TAG_OBJECT="8fb3b30e6dbdc9006780327c6687623534d134f5"
DNSTT_COMMIT="0c5c52a57d899c05428c116898941761a2ed83c2"
DNSTT_SRC="/opt/dnstt-src"
KEY_DIR="/etc/africhome-dnstt"
GO_VERSION="1.27.4"
GO_SHA256="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }

[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash scripts/install-dnstt.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -r "$SCRIPT_DIR/scripts/license.sh" ]] || fail "Licence verifier is missing. Run the main Africhome installer checkout."
bash "$SCRIPT_DIR/scripts/license.sh" verify
[[ "$(uname -s)" == "Linux" ]] || fail "Linux is required."
[[ "$(uname -m)" == "x86_64" ]] || fail "This bootstrap currently supports x86_64/amd64 only."

if [[ -L "$KEY_DIR" || ( -e "$KEY_DIR" && ! -d "$KEY_DIR" ) ]]; then
  fail "$KEY_DIR must be a real directory, not a symlink."
fi

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
  # Keep the old toolchain until the staged toolchain is in place and usable.
  go_backup=""
  if [[ -e /usr/local/go || -L /usr/local/go ]]; then
    [[ -d /usr/local/go && ! -L /usr/local/go ]] || fail "/usr/local/go must be a real directory."
    go_backup="/usr/local/go.africhome-backup.$(date +%s%N)"
    [[ ! -e "$go_backup" && ! -L "$go_backup" ]] || fail "Go backup path already exists."
    mv -- /usr/local/go "$go_backup" || fail "Could not stage the existing Go toolchain for rollback."
  fi
  if ! mv -- "$stage" /usr/local/go; then
    if [[ -n "$go_backup" && -d "$go_backup" ]]; then
      mv -- "$go_backup" /usr/local/go || fail "CRITICAL: Go install failed and the previous toolchain could not be restored from $go_backup."
    fi
    fail "Could not install the staged Go toolchain; previous toolchain restored."
  fi
  if ! /usr/local/go/bin/go version >/dev/null 2>&1; then
    rm -rf -- /usr/local/go
    if [[ -n "$go_backup" && -d "$go_backup" ]]; then
      mv -- "$go_backup" /usr/local/go || fail "CRITICAL: Go validation failed and rollback could not restore $go_backup."
    fi
    fail "Staged Go toolchain failed its version check; previous toolchain restored."
  fi
  GO_BIN="/usr/local/go/bin/go"
  [[ -z "$go_backup" ]] || rm -rf -- "$go_backup"
  trap - EXIT
  rm -rf -- "$tmpdir"
fi

info "Using $("$GO_BIN" version)"

[[ ! -L "$DNSTT_SRC" ]] || fail "$DNSTT_SRC must not be a symlink."
[[ ! -L "$DNSTT_SRC/.git" ]] || fail "$DNSTT_SRC/.git must not be a symlink."
if [[ -e "$DNSTT_SRC" && ! -d "$DNSTT_SRC/.git" ]]; then
  fail "$DNSTT_SRC exists but is not a Git checkout; move it aside and retry."
fi
if [[ -d "$DNSTT_SRC/.git" ]]; then
  existing_commit="$(git -C "$DNSTT_SRC" rev-parse HEAD)"
  [[ "$existing_commit" == "$DNSTT_COMMIT" ]] || fail "Existing DNSTT source checkout is not the pinned $DNSTT_TAG commit. Back it up and move it aside before retrying; it will not be overwritten."
  info "Using verified pinned DNSTT source commit $DNSTT_COMMIT."
else
  # Fetch the exact upstream release commit, not the moving master branch.
  src_stage="$(mktemp -d /opt/.dnstt-src.XXXXXX)"
  trap 'rm -rf -- "$src_stage"' EXIT
  git -C "$src_stage" init -q
  git -C "$src_stage" remote add origin "$DNSTT_REPO"
  git -C "$src_stage" fetch --depth=1 origin "refs/tags/$DNSTT_TAG:refs/tags/$DNSTT_TAG"
  git -C "$src_stage" checkout --detach "$DNSTT_TAG"
  fetched_tag_object="$(git -C "$src_stage" rev-parse "$DNSTT_TAG^{tag}")"
  [[ "$fetched_tag_object" == "$DNSTT_TAG_OBJECT" ]] || fail "Fetched DNSTT tag object does not match the pinned signed release tag."
  fetched_commit="$(git -C "$src_stage" rev-parse HEAD)"
  [[ "$fetched_commit" == "$DNSTT_COMMIT" ]] || fail "Fetched DNSTT source does not match the pinned release commit."
  mv -- "$src_stage" "$DNSTT_SRC"
  trap - EXIT
fi

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required."
install -d -m 0755 /usr/local/bin
build_tmp="$(mktemp -d)"
server_new=""
client_new=""
bin_backup=""
preserve_bin_backup=0
cleanup_build() {
  [[ -z "$server_new" ]] || rm -f -- "$server_new"
  [[ -z "$client_new" ]] || rm -f -- "$client_new"
  if (( ! preserve_bin_backup )) && [[ -n "$bin_backup" ]]; then
    rm -rf -- "$bin_backup"
  fi
  rm -rf -- "$build_tmp"
}
trap cleanup_build EXIT
(
  cd "$DNSTT_SRC/dnstt-server"
  GOTOOLCHAIN=local "$GO_BIN" build -trimpath -o "$build_tmp/dnstt-server" .
)
(
  cd "$DNSTT_SRC/dnstt-client"
  GOTOOLCHAIN=local "$GO_BIN" build -trimpath -o "$build_tmp/dnstt-client" .
)
# Keep backups on the same filesystem as the installed binaries for safe restore.
bin_backup="$(mktemp -d /usr/local/bin/.africhome-dnstt-backup.XXXXXX)"
server_existed=0
client_existed=0
if [[ -e /usr/local/bin/dnstt-server || -L /usr/local/bin/dnstt-server ]]; then
  [[ -f /usr/local/bin/dnstt-server && ! -L /usr/local/bin/dnstt-server ]] || fail "Existing dnstt-server is not a regular non-symlink file."
  cp -a -- /usr/local/bin/dnstt-server "$bin_backup/dnstt-server"
  server_existed=1
fi
if [[ -e /usr/local/bin/dnstt-client || -L /usr/local/bin/dnstt-client ]]; then
  [[ -f /usr/local/bin/dnstt-client && ! -L /usr/local/bin/dnstt-client ]] || fail "Existing dnstt-client is not a regular non-symlink file."
  cp -a -- /usr/local/bin/dnstt-client "$bin_backup/dnstt-client"
  client_existed=1
fi
server_new="$(mktemp /usr/local/bin/.dnstt-server.new.XXXXXX)"
client_new="$(mktemp /usr/local/bin/.dnstt-client.new.XXXXXX)"
install -m 0755 "$build_tmp/dnstt-server" "$server_new"
install -m 0755 "$build_tmp/dnstt-client" "$client_new"
if ! mv -f -- "$server_new" /usr/local/bin/dnstt-server; then
  fail "Could not install DNSTT server binary; existing binaries were not changed."
fi
if ! mv -f -- "$client_new" /usr/local/bin/dnstt-client; then
  # Restore each file through a same-filesystem temporary path. If restoration
  # itself fails, retain the protected backups for manual recovery.
  rollback_ok=1
  restore_binary() {
    local backup_file="$1" destination="$2" existed="$3" restore_tmp
    if (( existed )); then
      restore_tmp="$(mktemp "${destination}.restore.XXXXXX")" || return 1
      if ! cp -a -- "$backup_file" "$restore_tmp"; then
        rm -f -- "$restore_tmp"
        return 1
      fi
      if ! mv -f -- "$restore_tmp" "$destination"; then
        rm -f -- "$restore_tmp"
        return 1
      fi
    else
      rm -f -- "$destination" || return 1
    fi
  }
  restore_binary "$bin_backup/dnstt-server" /usr/local/bin/dnstt-server "$server_existed" || rollback_ok=0
  restore_binary "$bin_backup/dnstt-client" /usr/local/bin/dnstt-client "$client_existed" || rollback_ok=0
  if (( rollback_ok )); then
    fail "Could not install DNSTT client binary; previous server/client pair restored."
  fi
  preserve_bin_backup=1
  fail "CRITICAL: DNSTT binary install and rollback both failed. Protected backups retained at $bin_backup."
fi
rm -rf -- "$bin_backup"
bin_backup=""
rm -rf -- "$build_tmp"
trap - EXIT

install -d -o root -g root -m 0700 "$KEY_DIR"
[[ "$(stat -c '%u:%a' "$KEY_DIR")" == "0:700" ]] || fail "$KEY_DIR must be root-owned with mode 0700."
if [[ -e "$KEY_DIR/server.key" || -L "$KEY_DIR/server.key" || -e "$KEY_DIR/server.pub" || -L "$KEY_DIR/server.pub" ]]; then
  [[ -f "$KEY_DIR/server.key" && ! -L "$KEY_DIR/server.key" && "$(stat -c '%u:%a' "$KEY_DIR/server.key" 2>/dev/null || true)" == "0:600" ]] || fail "Existing DNSTT private key must be a root-owned regular file with mode 0600."
  [[ -f "$KEY_DIR/server.pub" && ! -L "$KEY_DIR/server.pub" && "$(stat -c '%u:%a' "$KEY_DIR/server.pub" 2>/dev/null || true)" == "0:644" ]] || fail "Existing DNSTT public key must be a root-owned regular file with mode 0644."
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
info "No DNS, firewall, UDP/53, or systemd service settings were changed."
info "Next: configure and externally test DNSTT before enabling its service."
