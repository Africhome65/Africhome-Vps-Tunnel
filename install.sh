#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Africhome65/Africhome-Vps-Tunnel.git"
INSTALL_DIR="/opt/africhome-vps-tunnel"
BIN_LINK="/usr/local/bin/africhome"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || fail "Run as root: sudo bash install.sh"
[[ -r /etc/os-release ]] || fail "Cannot identify operating system."
. /etc/os-release
OS_ID="${ID:-}"
OS_VERSION="${VERSION_ID:-}"
case "$OS_ID" in
  ubuntu) [[ "${OS_VERSION%%.*}" -ge 22 ]] || fail "Ubuntu 22.04 or newer is required." ;;
  debian) [[ "${OS_VERSION%%.*}" -ge 11 ]] || fail "Debian 11 or newer is required." ;;
  *) fail "Unsupported OS: $OS_ID. Use Ubuntu 22.04+ or Debian 11+." ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git ca-certificates curl jq openssl iproute2 procps util-linux dnsutils
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" fetch --depth=1 origin main
  git -C "$INSTALL_DIR" reset --hard origin/main
else
  [[ ! -e "$INSTALL_DIR" ]] || fail "$INSTALL_DIR exists but is not a Git checkout. Move it aside and retry."
  git clone --depth=1 --branch main "$REPO_URL" "$INSTALL_DIR"
fi

chmod 0755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/menu.sh"
chmod 0644 "$INSTALL_DIR/lib/common.sh" "$INSTALL_DIR"/modules/*.sh
ln -sfn "$INSTALL_DIR/menu.sh" "$BIN_LINK"
echo "Africhome VPS Tunnel foundation installed."
echo "Launch the terminal menu with: sudo africhome"
