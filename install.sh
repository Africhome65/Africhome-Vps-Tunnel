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

# Refuse unsafe install paths before apt or any other system changes.
if [[ -L "$INSTALL_DIR" ]]; then
  fail "$INSTALL_DIR is a symlink. Review it manually; installer will not follow it."
fi
if [[ -e "$INSTALL_DIR" && ( ! -d "$INSTALL_DIR/.git" || -L "$INSTALL_DIR/.git" ) ]]; then
  fail "$INSTALL_DIR exists but is not a Git checkout. Move it aside deliberately before retrying."
fi

# Refuse to overwrite local tracked or untracked work in an existing installation.
# The update step below uses reset --hard, so a clean worktree is mandatory.
if [[ -d "$INSTALL_DIR/.git" && ! -L "$INSTALL_DIR/.git" ]]; then
  if [[ -n "$(git -C "$INSTALL_DIR" status --porcelain --untracked-files=all)" ]]; then
    fail "$INSTALL_DIR contains local or untracked files. No update was performed. Back up and review these files, then clean or move them deliberately before retrying."
  fi
fi

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
  git clone --depth=1 --branch "$INSTALL_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

chmod 0755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/menu.sh" "$INSTALL_DIR/scripts/license.sh" "$INSTALL_DIR/scripts/xray-inventory.sh" "$INSTALL_DIR/scripts/dnstt-inventory.sh" "$INSTALL_DIR/scripts/openvpn-inventory.sh" "$INSTALL_DIR/scripts/update-reality-sni.py" "$INSTALL_DIR/scripts/render-central-router.py" "$INSTALL_DIR/scripts/render-http-router.py" "$INSTALL_DIR/scripts/render-central-haproxy.py" "$INSTALL_DIR/scripts/central-router-preflight.sh" "$INSTALL_DIR/scripts/apply-central-haproxy.sh"
chmod 0644 "$INSTALL_DIR/lib/common.sh" "$INSTALL_DIR"/modules/*.sh
install -D -m 0750 "$INSTALL_DIR/scripts/africhome-cert-deploy-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/africhome-central-deploy.sh
ln -sfn "$INSTALL_DIR/menu.sh" "$BIN_LINK"
echo "Africhome VPS Tunnel foundation installed."
echo "Launch the terminal menu with: sudo africhome"
