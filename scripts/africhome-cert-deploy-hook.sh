#!/usr/bin/env bash
set -eo pipefail
BASE_DIR=/opt/africhome-vps-tunnel
[[ "$EUID" -eq 0 ]] || exit 1
[[ -n "$RENEWED_LINEAGE" && -n "$RENEWED_DOMAINS" ]] || exit 0
. "$BASE_DIR/lib/common.sh"
. "$BASE_DIR/modules/domain_manager.sh"
. "$BASE_DIR/modules/cert_deploy.sh"
status=0
for domain in $RENEWED_DOMAINS; do
  cd_deploy_lineage "$RENEWED_LINEAGE" "$domain" || status=1
done
exit "$status"
