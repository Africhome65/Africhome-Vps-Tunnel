#!/usr/bin/env bash
# Transaction helpers for the DNSTT bootstrap. No work is performed when sourced.

dnstt_restore_file() {
  local backup_path="$1" destination="$2" existed="$3" restore_tmp
  if (( existed )); then
    restore_tmp="$(mktemp "${destination}.restore.XXXXXX")" || return 1
    if ! cp -a -- "$backup_path" "$restore_tmp"; then
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

dnstt_install_go_toolchain() {
  local stage="$1" target="$2" backup=""
  [[ -x "$stage/bin/go" ]] || { echo "Staged Go toolchain is missing its executable." >&2; return 1; }
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -d "$target" && ! -L "$target" ]] || { echo "Existing Go path is not a real directory." >&2; return 1; }
    backup="${target}.africhome-backup.$(date +%s%N)"
    [[ ! -e "$backup" && ! -L "$backup" ]] || { echo "Go backup path already exists." >&2; return 1; }
    mv -- "$target" "$backup" || { echo "Could not stage the existing Go toolchain." >&2; return 1; }
  fi
  if ! mv -- "$stage" "$target"; then
    if [[ -n "$backup" ]]; then
      mv -- "$backup" "$target" || { echo "CRITICAL: Go install failed and rollback could not restore $backup." >&2; return 1; }
    fi
    echo "Could not install the staged Go toolchain; previous toolchain restored." >&2
    return 1
  fi
  if ! go_is_new_enough "$target/bin/go"; then
    rm -rf -- "$target" || { echo "CRITICAL: invalid Go toolchain could not be removed; backup retained at $backup." >&2; return 1; }
    if [[ -n "$backup" ]]; then
      mv -- "$backup" "$target" || { echo "CRITICAL: Go validation failed and rollback could not restore $backup." >&2; return 1; }
    fi
    echo "Staged Go toolchain failed its version check; previous toolchain restored." >&2
    return 1
  fi
  [[ -z "$backup" ]] || rm -rf -- "$backup"
  return 0
}

dnstt_replace_binary_pair() {
  local server_source="$1" client_source="$2" bindir="$3"
  local backup="" server_new="" client_new="" server_existed=0 client_existed=0
  local rollback_ok=1 preserve_backup=0

  [[ -f "$server_source" && -f "$client_source" ]] || { echo "DNSTT build outputs are missing." >&2; return 1; }
  [[ -d "$bindir" && ! -L "$bindir" ]] || { echo "DNSTT binary directory must be a real directory." >&2; return 1; }
  backup="$(mktemp -d "$bindir/.africhome-dnstt-backup.XXXXXX")" || return 1

  if [[ -e "$bindir/dnstt-server" || -L "$bindir/dnstt-server" ]]; then
    [[ -f "$bindir/dnstt-server" && ! -L "$bindir/dnstt-server" ]] || { echo "Existing dnstt-server is not a regular non-symlink file." >&2; rm -rf -- "$backup"; return 1; }
    cp -a -- "$bindir/dnstt-server" "$backup/dnstt-server" || { rm -rf -- "$backup"; return 1; }
    server_existed=1
  fi
  if [[ -e "$bindir/dnstt-client" || -L "$bindir/dnstt-client" ]]; then
    [[ -f "$bindir/dnstt-client" && ! -L "$bindir/dnstt-client" ]] || { echo "Existing dnstt-client is not a regular non-symlink file." >&2; rm -rf -- "$backup"; return 1; }
    cp -a -- "$bindir/dnstt-client" "$backup/dnstt-client" || { rm -rf -- "$backup"; return 1; }
    client_existed=1
  fi

  server_new="$(mktemp "$bindir/.dnstt-server.new.XXXXXX")" || { rm -rf -- "$backup"; return 1; }
  client_new="$(mktemp "$bindir/.dnstt-client.new.XXXXXX")" || { rm -f -- "$server_new"; rm -rf -- "$backup"; return 1; }
  if ! install -m 0755 "$server_source" "$server_new" || ! install -m 0755 "$client_source" "$client_new"; then
    rm -f -- "$server_new" "$client_new"
    rm -rf -- "$backup"
    echo "Could not stage the DNSTT server/client binary pair." >&2
    return 1
  fi
  if ! mv -f -- "$server_new" "$bindir/dnstt-server"; then
    rm -f -- "$server_new" "$client_new"
    rm -rf -- "$backup"
    echo "Could not install DNSTT server binary; existing binaries were not changed." >&2
    return 1
  fi
  if ! mv -f -- "$client_new" "$bindir/dnstt-client"; then
    dnstt_restore_file "$backup/dnstt-server" "$bindir/dnstt-server" "$server_existed" || rollback_ok=0
    dnstt_restore_file "$backup/dnstt-client" "$bindir/dnstt-client" "$client_existed" || rollback_ok=0
    rm -f -- "$server_new" "$client_new"
    if (( rollback_ok )); then
      rm -rf -- "$backup"
      echo "Could not install DNSTT client binary; previous server/client pair restored." >&2
    else
      preserve_backup=1
      echo "CRITICAL: DNSTT binary install and rollback both failed. Protected backups retained at $backup." >&2
    fi
    (( preserve_backup )) || rm -rf -- "$backup"
    return 1
  fi

  rm -rf -- "$backup"
  return 0
}
