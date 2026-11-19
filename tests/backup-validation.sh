#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/modules/backup.sh"

backup_require_root(){ return 0; }
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export AH_BACKUP_ROOT="$tmp/backups"
export AH_RESTORE_STAGE_ROOT="$tmp/staged"
mkdir -p "$AH_BACKUP_ROOT" "$tmp/source/etc/xray" "$tmp/source/etc/letsencrypt/archive/example.test" "$tmp/source/etc/letsencrypt/live/example.test"
printf 'test-config\n' > "$tmp/source/etc/xray/config.json"
printf 'test-cert\n' > "$tmp/source/etc/letsencrypt/archive/example.test/cert.pem"
ln -s ../../archive/example.test/cert.pem "$tmp/source/etc/letsencrypt/live/example.test/cert.pem"
good="$AH_BACKUP_ROOT/africhome-good.tar.gz"
tar -czf "$good" -C "$tmp/source" etc/xray etc/letsencrypt
(cd "$AH_BACKUP_ROOT" && sha256sum "$(basename "$good")" > "$(basename "$good").sha256")
backup_verify "$good"
backup_stage_restore "$good"
stage="$(find "$AH_RESTORE_STAGE_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$stage" ]]
[[ "$(cat "$stage/etc/xray/config.json")" == "test-config" ]]
[[ "$(cat "$stage/etc/letsencrypt/live/example.test/cert.pem")" == "test-cert" ]]
[[ -L "$stage/etc/letsencrypt/live/example.test/cert.pem" ]]
[[ "$(stat -c '%a' "$stage/etc/xray/config.json")" == "600" ]]

bad="$AH_BACKUP_ROOT/africhome-bad.tar.gz"
tar -czf "$bad" -C "$tmp" --transform='s|escape|../escape|' source/etc/xray/config.json
(cd "$AH_BACKUP_ROOT" && sha256sum "$(basename "$bad")" > "$(basename "$bad").sha256")
if backup_stage_restore "$bad"; then
  echo "Path traversal archive was accepted" >&2
  exit 1
fi
[[ ! -e "$tmp/escape" ]]
echo "Backup and staged-restore validation passed."
