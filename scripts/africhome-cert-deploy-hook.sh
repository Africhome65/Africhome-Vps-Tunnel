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
ssh_tls_config=/etc/stunnel/africhome-ssh.conf
if [[ -f "$ssh_tls_config" && ! -L "$ssh_tls_config" ]]; then
  for domain in $RENEWED_DOMAINS; do
    dm_valid_domain "$domain" || continue
    if grep -Fqx "cert = /etc/letsencrypt/live/$domain/fullchain.pem" "$ssh_tls_config" &&
       grep -Fqx "key = /etc/letsencrypt/live/$domain/privkey.pem" "$ssh_tls_config"; then
      if systemctl is-active --quiet africhome-ssh-tls.service; then
        systemctl restart africhome-ssh-tls.service || status=1
      fi
    fi
  done
fi
exit "$status"
