#!/usr/bin/env bash
# Africhome configuration backups. Restore is staged for inspection; it never
# writes directly into live /etc paths.
AH_BACKUP_ROOT="${AH_BACKUP_ROOT:-/var/backups/africhome}"
AH_RESTORE_STAGE_ROOT="${AH_RESTORE_STAGE_ROOT:-/var/lib/africhome/restore-staging}"

backup_require_root(){
  if [[ "${EUID}" -ne 0 ]]; then
    ah_err "Run backup management as root (sudo africhome)."
    return 1
  fi
}
backup_collect_paths(){
  local p
  local -a candidates=(
    etc/ssh/sshd_config
    etc/ssh/sshd_config.d
    etc/fail2ban
    etc/ufw
    etc/nftables.conf
    etc/africhome
    etc/xray
    usr/local/etc/xray
    etc/hysteria
    etc/letsencrypt
    var/lib/africhome
  )
  for p in "${candidates[@]}"; do
    if [[ -e "/$p" || -L "/$p" ]]; then printf '%s\n' "$p"; fi
  done
  for p in /etc/systemd/system/africhome-*.service /etc/systemd/system/africhome-*.timer; do
    [[ -e "$p" || -L "$p" ]] || continue
    printf '%s\n' "${p#/}"
  done
}
backup_create(){
  backup_require_root || return 1
  command -v tar >/dev/null 2>&1 || { ah_err "tar is required."; return 1; }
  command -v sha256sum >/dev/null 2>&1 || { ah_err "sha256sum is required."; return 1; }
  install -d -m 0700 "$AH_BACKUP_ROOT" || return 1
  chmod 0700 "$AH_BACKUP_ROOT" || return 1
  local stamp archive tmp sumtmp
  local -a paths
  mapfile -t paths < <(backup_collect_paths)
  if (( ${#paths[@]} == 0 )); then
    ah_err "No supported Africhome or service configuration paths were found."
    return 1
  fi
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  archive="$AH_BACKUP_ROOT/africhome-$stamp.tar.gz"
  [[ ! -e "$archive" ]] || { ah_err "Backup already exists: $archive"; return 1; }
  tmp="$(mktemp "$AH_BACKUP_ROOT/.backup.XXXXXX")" || return 1
  sumtmp="$(mktemp "$AH_BACKUP_ROOT/.checksum.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if ! tar -czf "$tmp" --numeric-owner -C / "${paths[@]}"; then
    rm -f "$tmp" "$sumtmp"
    ah_err "Backup archive creation failed."
    return 1
  fi
  chmod 0600 "$tmp" || { rm -f "$tmp" "$sumtmp"; return 1; }
  mv -- "$tmp" "$archive" || { rm -f "$tmp" "$sumtmp"; return 1; }
  if ! (cd "$AH_BACKUP_ROOT" && sha256sum "$(basename "$archive")" > "$sumtmp"); then
    rm -f "$archive" "$sumtmp"
    ah_err "Could not create backup checksum."
    return 1
  fi
  chmod 0600 "$sumtmp" || { rm -f "$archive" "$sumtmp"; return 1; }
  mv -- "$sumtmp" "$archive.sha256" || { rm -f "$archive" "$sumtmp"; return 1; }
  ah_ok "Encrypted? No. Root-only configuration backup created: $archive"
  ah_warn "This archive may contain passwords, tokens, certificates, and private keys. Keep it protected and off-host."
  printf 'Included paths:\n'
  printf '  %s\n' "${paths[@]}"
}
backup_list(){
  if [[ ! -d "$AH_BACKUP_ROOT" ]]; then
    ah_info "No Africhome backup directory exists yet."
    return 0
  fi
  find "$AH_BACKUP_ROOT" -maxdepth 1 -type f -name 'africhome-*.tar.gz' -printf '%f  %s bytes\n' | sort
}
backup_verify(){
  backup_require_root || return 1
  local archive="$1" base
  [[ -f "$archive" && ! -L "$archive" ]] || { ah_err "Backup archive is not a regular file."; return 1; }
  base="$(basename "$archive")"
  [[ "$base" == africhome-*.tar.gz && "$(dirname -- "$archive")" == "$AH_BACKUP_ROOT" ]] || {
    ah_err "Select an archive directly inside $AH_BACKUP_ROOT."
    return 1
  }
  [[ -f "$archive.sha256" && ! -L "$archive.sha256" ]] || { ah_err "Backup checksum is missing."; return 1; }
  (cd "$AH_BACKUP_ROOT" && sha256sum -c "$base.sha256") || return 1
  tar -tzf "$archive" >/dev/null || { ah_err "Archive integrity check failed."; return 1; }
  ah_ok "Backup checksum and gzip/tar integrity verified."
}
backup_stage_restore(){
  backup_require_root || return 1
  local archive="$1" stage
  backup_verify "$archive" || return 1
  install -d -m 0700 "$AH_RESTORE_STAGE_ROOT" || return 1
  chmod 0700 "$AH_RESTORE_STAGE_ROOT" || return 1
  stage="$(mktemp -d "$AH_RESTORE_STAGE_ROOT/restore.XXXXXX")" || return 1
  chmod 0700 "$stage" || { rm -rf -- "$stage"; return 1; }
  if ! python3 - "$archive" "$stage" <<'PY'
import pathlib, sys, tarfile
archive, destination = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
allowed = (
    "etc/ssh/sshd_config", "etc/ssh/sshd_config.d", "etc/fail2ban",
    "etc/ufw", "etc/nftables.conf", "etc/africhome", "etc/xray",
    "usr/local/etc/xray", "etc/hysteria", "etc/letsencrypt",
    "var/lib/africhome", "etc/systemd/system/africhome-",
)
def allowed_path(name):
    return any(name == root or name.startswith(root.rstrip("/") + "/") or
               (root.endswith("-") and name.startswith(root))
               for root in allowed)
try:
    with tarfile.open(archive, "r:gz") as tf:
        members = tf.getmembers()
        if not members:
            raise ValueError("archive is empty")
        checked = []
        for member in members:
            name = member.name
            path = pathlib.PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or not allowed_path(name):
                raise ValueError(f"unexpected archive path: {name}")
            if not (member.isdir() or member.isfile() or member.issym()):
                raise ValueError(f"hard links and special files are not restorable: {name}")
            raw_target = destination / pathlib.Path(*path.parts)
            target = raw_target.resolve()
            if target != destination and destination not in target.parents:
                raise ValueError(f"path escapes staging directory: {name}")
            if member.issym():
                link = pathlib.PurePosixPath(member.linkname)
                if link.is_absolute():
                    raise ValueError(f"absolute symlink target is not allowed: {name}")
                resolved_link = (raw_target.parent / pathlib.Path(*link.parts)).resolve()
                if resolved_link != destination and destination not in resolved_link.parents:
                    raise ValueError(f"symlink escapes staging directory: {name}")
            checked.append((member, raw_target))
        for member, raw_target in checked:
            target = raw_target
            # Never traverse an already-created symlink as a parent directory.
            for parent in target.parents:
                if parent == destination:
                    break
                if parent.is_symlink():
                    raise ValueError(f"archive path traverses a symlink: {member.name}")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
                target.chmod(0o700)
            elif member.issym():
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                target.symlink_to(member.linkname)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                source = tf.extractfile(member)
                if source is None:
                    raise ValueError(f"cannot read archive member: {member.name}")
                with source, target.open("xb") as output:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
                target.chmod(0o600)
except Exception as exc:
    print(f"Safe restore staging failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
  then
    rm -rf -- "$stage"
    return 1
  fi
  ah_ok "Restore staged for inspection: $stage"
  ah_warn "Nothing was copied into live system paths. Review files and plan service-specific restoration separately."
}
# Retention is manual and opt-in. Only old, regular Africhome archives and
# their matching regular checksum sidecars inside the fixed backup root qualify.
backup_retention_preview() {
  local keep="${1:-10}" days="${2:-90}" root archive index=0 mtime cutoff
  [[ "$keep" =~ ^[0-9]+$ && "$days" =~ ^[0-9]+$ ]] || return 1
  (( keep >= 1 && keep <= 100 && days >= 1 && days <= 3650 )) || return 1
  [[ -d "$AH_BACKUP_ROOT" && ! -L "$AH_BACKUP_ROOT" ]] || {
    ah_warn "Backup directory is missing or is a symlink; nothing will be pruned."
    return 1
  }
  root="$(realpath -e -- "$AH_BACKUP_ROOT")" || return 1
  [[ "$root" == "$AH_BACKUP_ROOT" ]] || { ah_err "Backup root must be a canonical, non-symlink path."; return 1; }
  cutoff=$(( $(date +%s) - days * 86400 ))
  mapfile -t _backup_retention_rows < <(find "$root" -mindepth 1 -maxdepth 1 -type f -name 'africhome-*.tar.gz' -printf '%T@ %p\\n' | sort -rn)
  printf 'Retention preview: keep newest %s archives; prune only archives at least %s days old.\\n' "$keep" "$days"
  for row in "${_backup_retention_rows[@]}"; do
    mtime="${row%% *}"
    archive="${row#* }"
    ((index+=1))
    [[ -f "$archive" && ! -L "$archive" ]] || continue
    if (( index > keep )) && [[ "$mtime" =~ ^[0-9]+(\\.[0-9]+)?$ ]] && (( ${mtime%%.*} <= cutoff )); then
      if [[ -f "$archive.sha256" && ! -L "$archive.sha256" ]]; then
        printf 'WOULD PRUNE: %s\\n' "$(basename -- "$archive")"
      else
        printf 'SKIP (missing/unsafe checksum): %s\\n' "$(basename -- "$archive")"
      fi
    else
      printf 'KEEP: %s\\n' "$(basename -- "$archive")"
    fi
  done
}
backup_retention_prune() {
  backup_require_root || return 1
  local keep="${1:-10}" days="${2:-90}" root row mtime archive index=0 removed=0
  [[ "$keep" =~ ^[0-9]+$ && "$days" =~ ^[0-9]+$ ]] || return 1
  (( keep >= 1 && keep <= 100 && days >= 1 && days <= 3650 )) || {
    ah_err "Retention must keep 1-100 archives and use an age of 1-3650 days."
    return 1
  }
  backup_retention_preview "$keep" "$days" || return 1
  read -r -p "Type PRUNE to permanently delete only the listed old backups: " answer
  if [[ "$answer" != PRUNE ]]; then
    ah_info "Retention pruning cancelled."
    ah_audit_log backup.retention cancelled 2>/dev/null || true
    return 0
  fi
  root="$(realpath -e -- "$AH_BACKUP_ROOT")" || return 1
  [[ "$root" == "$AH_BACKUP_ROOT" && -d "$root" && ! -L "$AH_BACKUP_ROOT" ]] || return 1
  mapfile -t _backup_retention_rows < <(find "$root" -mindepth 1 -maxdepth 1 -type f -name 'africhome-*.tar.gz' -printf '%T@ %p\\n' | sort -rn)
  for row in "${_backup_retention_rows[@]}"; do
    mtime="${row%% *}"
    archive="${row#* }"
    ((index+=1))
    [[ "$archive" == "$root"/africhome-*.tar.gz && -f "$archive" && ! -L "$archive" ]] || continue
    [[ "$mtime" =~ ^[0-9]+(\\.[0-9]+)?$ ]] || continue
    if (( index > keep && ${mtime%%.*} <= $(date +%s) - days * 86400 )) &&
       [[ -f "$archive.sha256" && ! -L "$archive.sha256" ]]; then
      rm -f -- "$archive.sha256" "$archive" || return 1
      ((removed+=1))
    fi
  done
  ah_ok "Removed $removed old backup archive(s); newest $keep were retained."
  ah_audit_log backup.retention success 2>/dev/null || true
}
backup_menu(){
  while true; do
    clear
    echo "=== BACKUP & RESTORE ==="
    echo "1) Create protected configuration backup"
    echo "2) List backups"
    echo "3) Verify a backup"
    echo "4) Stage restore for inspection (no live overwrite)"
    echo "5) Preview and apply manual backup retention"
    echo "0) Back"
    read -r -p "Select: " choice
    case "$choice" in
      1) backup_create; ah_pause ;;
      2) backup_list; ah_pause ;;
      3)
        read -r -p "Backup filename inside $AH_BACKUP_ROOT: " name
        backup_verify "$AH_BACKUP_ROOT/$name"; ah_pause
        ;;
      4)
        read -r -p "Backup filename inside $AH_BACKUP_ROOT: " name
        backup_stage_restore "$AH_BACKUP_ROOT/$name"; ah_pause
        ;;
      5)\n        read -r -p "Keep newest archive count (1-100) [10]: " keep\n        keep="${keep:-10}"\n        read -r -p "Minimum archive age in days (1-3650) [90]: " days\n        days="${days:-90}"\n        backup_retention_prune "$keep" "$days"; ah_pause\n        ;;\n      0) return ;;
      *) ah_warn "Invalid choice."; sleep 1 ;;
    esac
  done
}
