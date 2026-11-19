#!/usr/bin/env bash
# Guarded HAProxy apply transaction. Requires a free-port preflight and explicit confirmation.
set -Eeuo pipefail
CANDIDATE="\${AFRICHOME_HAPROXY_CANDIDATE:-/root/africhome-haproxy-candidate.cfg}"
CONFIG_DIR="\${AFRICHOME_HAPROXY_CONFIG_DIR:-/etc/haproxy}"
CONFIG_FILE="\${AFRICHOME_HAPROXY_CONFIG_FILE:-$CONFIG_DIR/haproxy.cfg}"
BACKUP_ROOT="\${AFRICHOME_HAPROXY_BACKUP_ROOT:-/var/backups/africhome-haproxy}"
LOCK_FILE="\${AFRICHOME_HAPROXY_LOCK_FILE:-/run/lock/africhome-haproxy-apply.lock}"
HAPROXY_BIN="\${AFRICHOME_HAPROXY_BIN:-haproxy}"
SYSTEMCTL_BIN="\${AFRICHOME_SYSTEMCTL_BIN:-systemctl}"
SS_BIN="\${AFRICHOME_SS_BIN:-ss}"
fail(){ printf '[ERROR] %s\n' "$*" >&2; }
info(){ printf '[INFO] %s\n' "$*"; }
[[ "$#" -eq 1 && "$1" == "--apply" ]] || { fail "Usage: $0 --apply (interactive APPLY confirmation required)"; exit 2; }
(( EUID == 0 )) || { fail "Run as root."; exit 1; }
for cmd in "$HAPROXY_BIN" "$SYSTEMCTL_BIN" "$SS_BIN" flock install stat awk grep cp; do
  command -v "$cmd" >/dev/null 2>&1 || { fail "Required command is missing: $cmd"; exit 1; }
done
[[ -f "$CANDIDATE" && ! -L "$CANDIDATE" ]] || { fail "Candidate must be a regular non-symlink file."; exit 1; }
[[ "$(stat -c '%u:%a' -- "$CANDIDATE")" == "0:600" ]] || { fail "Candidate must be root-owned with mode 0600."; exit 1; }
grep -Eq '^[[:space:]]*bind[[:space:]]+0\.0\.0\.0:80([[:space:]]|$)' "$CANDIDATE" &&
grep -Eq '^[[:space:]]*bind[[:space:]]+0\.0\.0\.0:443([[:space:]]|$)' "$CANDIDATE" || {
  fail "Candidate must contain the expected public TCP 80 and 443 listeners."; exit 1;
}
[[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" && "$(stat -c '%u' -- "$CONFIG_DIR")" == "0" ]] || {
  fail "HAProxy config directory must exist, be root-owned, and not be a symlink."; exit 1;
}
if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" && "$(stat -c '%u' -- "$CONFIG_FILE")" == "0" ]] || {
    fail "Existing HAProxy config must be a root-owned regular file, not a symlink."; exit 1;
  }
fi
install -d -o root -g root -m 0755 "$(dirname -- "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || { fail "Another HAProxy apply transaction is running."; exit 1; }
if "$SYSTEMCTL_BIN" is-active --quiet haproxy 2>/dev/null; then
  fail "HAProxy is already active. Refusing to replace a live service configuration."; exit 1
fi
enabled_before=0
if "$SYSTEMCTL_BIN" is-enabled --quiet haproxy 2>/dev/null; then enabled_before=1; fi
port_busy(){
  local port="$1"
  "$SS_BIN" -H -ltn 2>/dev/null | awk -v suffix=":$port" '$4 ~ (suffix "$") {found=1} END{exit !found}'
}
for port in 80 443; do
  if port_busy "$port"; then fail "TCP port $port is already occupied. No configuration was changed."; exit 3; fi
done
"$HAPROXY_BIN" -c -f "$CANDIDATE" || { fail "HAProxy rejected the candidate."; exit 1; }
read -r -p "This will start HAProxy on public TCP ports 80 and 443. Type APPLY to continue: " confirmation
[[ "$confirmation" == "APPLY" ]] || { info "Cancelled; no system configuration was changed."; exit 0; }
install -d -o root -g root -m 0700 "$BACKUP_ROOT"
[[ -d "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" && "$(stat -c '%u:%a' -- "$BACKUP_ROOT")" == "0:700" ]] || {
  fail "Backup directory must be root-owned mode 0700."; exit 1;
}
backup_dir="$(mktemp -d "$BACKUP_ROOT/transaction.XXXXXX")" || exit 1
had_config=0
if [[ -e "$CONFIG_FILE" ]]; then
  cp -a -- "$CONFIG_FILE" "$backup_dir/haproxy.cfg" || { rmdir "$backup_dir"; fail "Could not back up existing config."; exit 1; }
  had_config=1
fi
tmp="$(mktemp "$CONFIG_DIR/.africhome-haproxy.XXXXXX")" || { rm -rf -- "$backup_dir"; exit 1; }
cleanup(){ [[ -z "\${tmp:-}" ]] || rm -f -- "$tmp"; }
trap cleanup EXIT
if ! install -o root -g root -m 0640 "$CANDIDATE" "$tmp" ||
   ! "$HAPROXY_BIN" -c -f "$tmp" ||
   ! mv -fT -- "$tmp" "$CONFIG_FILE"; then
  fail "Could not validate and atomically install the candidate."; exit 1
fi
tmp=""
started_by_us=0
enable_attempted=0
rollback(){
  if (( started_by_us == 1 )); then "$SYSTEMCTL_BIN" stop haproxy >/dev/null 2>&1 || true; fi
  if (( enable_attempted == 1 )); then "$SYSTEMCTL_BIN" disable haproxy >/dev/null 2>&1 || true; fi
  if (( had_config == 1 )); then
    local restore_tmp
    restore_tmp="$(mktemp "$CONFIG_DIR/.africhome-haproxy-rollback.XXXXXX")" || {
      fail "CRITICAL: rollback temp file could not be created; backup is at $backup_dir/haproxy.cfg"; return 1;
    }
    if ! cp -a -- "$backup_dir/haproxy.cfg" "$restore_tmp" ||
       ! mv -fT -- "$restore_tmp" "$CONFIG_FILE"; then
      rm -f -- "$restore_tmp"
      fail "CRITICAL: automatic rollback failed; original backup is at $backup_dir/haproxy.cfg"; return 1;
    fi
  else
    rm -f -- "$CONFIG_FILE"
  fi
  info "Previous HAProxy configuration restored; service left stopped."
}
if ! "$SYSTEMCTL_BIN" start haproxy; then
  fail "HAProxy failed to start. Rolling back."
  rollback || true
  exit 1
fi
started_by_us=1
if ! "$SYSTEMCTL_BIN" is-active --quiet haproxy || ! port_busy 80 || ! port_busy 443; then
  fail "HAProxy did not become active with both expected listeners. Rolling back."
  rollback || true
  exit 1
fi
if (( enabled_before == 0 )); then
  enable_attempted=1
  if ! "$SYSTEMCTL_BIN" enable haproxy; then
    fail "HAProxy could not be enabled for startup. Rolling back."
    rollback || true
    exit 1
  fi
fi
info "HAProxy started and enabled with TCP 80 and 443 listeners."
info "Previous config backup: $backup_dir"
info "This transaction did not edit UFW/nftables, Xray, or other services."
