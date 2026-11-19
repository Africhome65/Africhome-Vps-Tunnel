#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/Africhome65/Africhome-Vps-Tunnel.git"
INSTALL_BRANCH="feature/central-port-routing-architecture"
INSTALL_DIR="/opt/africhome-vps-tunnel"
BIN_LINK="/usr/local/bin/africhome"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail(){ echo "[ERROR] $*" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || fail "Run as root: sudo bash install.sh"
[[ -r /etc/os-release ]] || fail "Cannot identify operating system."
. /etc/os-release
OS_ID="${ID:-}"
OS_VERSION="${VERSION_ID:-}"
case "$OS_ID" in
  ubuntu) [[ "${OS_VERSION%%.*}" -ge 22 ]] || fail "Ubuntu 22.04 or newer is required." ;;
  debian) [[ "${OS_VERSION%%.*}" -ge 11 ]] || fail "Debian 11 or newer is required." ;;
  *) fail "Unsupported OS: $OS_ID. Use Ubuntu 22.04+ or Debian 11+." ;;
esac

# Verify the locally signed lifetime licence before package installation or system changes.
[[ -r "$SCRIPT_DIR/scripts/license.sh" ]] || fail "Licence verifier is missing from this checkout."
bash "$SCRIPT_DIR/scripts/license.sh" verify

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git ca-certificates curl jq openssl iproute2 procps util-linux
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" fetch --depth=1 origin "$INSTALL_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$INSTALL_BRANCH"
else
  [[ ! -e "$INSTALL_DIR" ]] || fail "$INSTALL_DIR exists but is not a Git checkout. Move it aside and retry."
  git clone --depth=1 --branch "$INSTALL_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

chmod 0755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/menu.sh" "$INSTALL_DIR/scripts/license.sh" "$INSTALL_DIR/scripts/xray-inventory.sh" "$INSTALL_DIR/scripts/dnstt-inventory.sh"
chmod 0644 "$INSTALL_DIR/lib/common.sh" "$INSTALL_DIR"/modules/*.sh
install -D -m 0750 "$INSTALL_DIR/scripts/africhome-cert-deploy-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/africhome-central-deploy.sh
ln -sfn "$INSTALL_DIR/menu.sh" "$BIN_LINK"
echo "Africhome VPS Tunnel foundation installed."
echo "Launch the terminal menu with: sudo africhome"
