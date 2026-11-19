#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export AH_BACKUP_ROOT="$tmp/backups"
export AH_RESTORE_STAGE_ROOT="$tmp/staged"
. "$ROOT/lib/common.sh"
. "$ROOT/modules/backup.sh"

backup_require_root(){ return 0; }
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
python3 - "$bad" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tf:
    data = b"not allowed"
    info = tarfile.TarInfo("../escape")
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PY
(cd "$AH_BACKUP_ROOT" && sha256sum "$(basename "$bad")" > "$(basename "$bad").sha256")
if backup_stage_restore "$bad"; then
  echo "Path traversal archive was accepted" >&2
  exit 1
fi
[[ ! -e "$tmp/escape" ]]

# Retention is explicit, age-gated, and restricted to paired Africhome archives.
old="$AH_BACKUP_ROOT/africhome-old.tar.gz"
recent="$AH_BACKUP_ROOT/africhome-recent.tar.gz"
printf old > "$old"
printf recent > "$recent"
printf 'checksum  old\\n' > "$old.sha256"
printf 'checksum  recent\\n' > "$recent.sha256"
touch -d '120 days ago' "$old" "$old.sha256"
touch "$recent" "$recent.sha256"
printf 'unrelated\\n' > "$AH_BACKUP_ROOT/keep-me.txt"
preview="$(backup_retention_preview 1 90)"
grep -Fq 'WOULD PRUNE: africhome-old.tar.gz' <<< "$preview"
grep -Fq 'KEEP: africhome-recent.tar.gz' <<< "$preview"
printf 'PRUNE\\n' | backup_retention_prune 1 90
[[ ! -e "$old" && ! -e "$old.sha256" ]]
[[ -f "$recent" && -f "$recent.sha256" && -f "$AH_BACKUP_ROOT/keep-me.txt" ]]
\necho "Backup, retention, and staged-restore validation passed."
