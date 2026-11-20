#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/shared443-transaction.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
pass=0
fail=0
xray_active=1
haproxy_active=0
mock_haproxy_enabled_state=disabled
fail_xray_validation=0
fail_haproxy_validation=0
fail_haproxy_restart=0
fail_ss=0
ss_mode=normal

xray() {
  (( fail_xray_validation )) && return 1
  return 0
}
haproxy() {
  (( fail_haproxy_validation )) && return 1
  return 0
}
getent() {
  [[ "${1:-}" == "group" && "${2:-}" == "root" ]]
}
systemctl() {
  local action="${1:-}" service=""
  service="${@: -1}"
  case "$action" in
    is-active)
      if [[ "$service" == "xray.service" ]]; then (( xray_active ))
      elif [[ "$service" == "haproxy.service" ]]; then (( haproxy_active ))
      else return 1
      fi
      ;;
    is-enabled) printf '%s\n' "$mock_haproxy_enabled_state" ;;
    show) printf 'root\n' ;;
    restart)
      if [[ "$service" == "xray.service" ]]; then xray_active=1
      elif [[ "$service" == "haproxy.service" ]]; then
        (( fail_haproxy_restart )) && return 1
        haproxy_active=1
      fi
      ;;
    enable) mock_haproxy_enabled_state=enabled ;;
    disable) mock_haproxy_enabled_state=disabled ;;
    stop)
      if [[ "$service" == "xray.service" ]]; then xray_active=0
      elif [[ "$service" == "haproxy.service" ]]; then haproxy_active=0
      fi
      ;;
    daemon-reload) return 0 ;;
    *) return 1 ;;
  esac
}
ss() {
  (( fail_ss )) && return 1
  if [[ "$ss_mode" == "busy" ]]; then
    printf 'LISTEN 0 128 *:443 *:* users:(("nginx",pid=321,fd=3))\n'
  elif [[ "$haproxy_active" == "1" ]]; then
    printf 'LISTEN 0 128 *:443 *:* users:(("haproxy",pid=123,fd=3))\n'
  fi
  return 0
}

make_case() {
  local name="$1" candidate active backup
  candidate="$TMP/$name/candidate"
  active="$TMP/$name/active"
  backup="$TMP/$name/backups"
  mkdir -p "$candidate" "$active"
  chmod 0700 "$candidate"
  printf '{"inbounds":[]}\n' > "$candidate/xray-config.json"
  printf 'global\ndefaults\nfrontend fe_shared_443\n' > "$candidate/haproxy-443.cfg"
  printf '{"routes":[]}\n' > "$candidate/tls-routes.json"
  chmod 0600 "$candidate/"*
  printf 'old-xray-%s\n' "$name" > "$active/xray.json"
  printf 'old-haproxy-%s\n' "$name" > "$active/haproxy.cfg"
  printf '%s\n' "$candidate" "$active/xray.json" "$active/haproxy.cfg" "$backup"
}

# Successful apply: Xray releases TCP/443, then HAProxy binds it; old configs are backed up.
mapfile -t success_paths < <(make_case success)
candidate="${success_paths[0]}"
xray_config="${success_paths[1]}"
haproxy_config="${success_paths[2]}"
backup_root="${success_paths[3]}"
xray_active=1; haproxy_active=0; mock_haproxy_enabled_state=disabled
fail_xray_validation=0; fail_haproxy_validation=0; fail_haproxy_restart=0; fail_ss=0; ss_mode=normal
if shared443_apply_transaction "$candidate" "$xray_config" "$haproxy_config" "$backup_root" xray.service haproxy.service 0 &&
   grep -q '"inbounds"' "$xray_config" &&
   grep -q 'frontend fe_shared_443' "$haproxy_config" &&
   (( xray_active && haproxy_active )) &&
   [[ "$mock_haproxy_enabled_state" == "enabled" ]] &&
   compgen -G "$backup_root/africhome-vmess-shared443.*/xray-config.json" >/dev/null; then
  echo "PASS: shared TCP/443 apply updates both configs and enables HAProxy with protected backups"
  ((pass+=1))
else
  echo "FAIL: shared TCP/443 successful apply did not complete as expected" >&2
  ((fail+=1))
fi

# If HAProxy restart fails, both configs and previous service states must be restored.
mapfile -t rollback_paths < <(make_case rollback)
candidate="${rollback_paths[0]}"
xray_config="${rollback_paths[1]}"
haproxy_config="${rollback_paths[2]}"
backup_root="${rollback_paths[3]}"
xray_active=1; haproxy_active=0; mock_haproxy_enabled_state=disabled
fail_xray_validation=0; fail_haproxy_validation=0; fail_haproxy_restart=1; fail_ss=0; ss_mode=normal
if shared443_apply_transaction "$candidate" "$xray_config" "$haproxy_config" "$backup_root" xray.service haproxy.service 0; then
  echo "FAIL: injected HAProxy restart failure unexpectedly succeeded" >&2
  ((fail+=1))
elif [[ "$(cat "$xray_config")" == "old-xray-rollback" ]] &&
     [[ "$(cat "$haproxy_config")" == "old-haproxy-rollback" ]] &&
     (( xray_active )) && (( ! haproxy_active )) &&
     [[ "$mock_haproxy_enabled_state" == "disabled" ]] &&
     compgen -G "$backup_root/africhome-vmess-shared443.*/xray-config.json" >/dev/null; then
  echo "PASS: failed HAProxy start restores both configs and previous service state"
  ((pass+=1))
else
  echo "FAIL: HAProxy restart failure did not restore previous state" >&2
  ((fail+=1))
fi

# A different listener occupying TCP/443 after Xray restart must abort and restore Xray.
mapfile -t busy_paths < <(make_case busy)
candidate="${busy_paths[0]}"
xray_config="${busy_paths[1]}"
haproxy_config="${busy_paths[2]}"
backup_root="${busy_paths[3]}"
xray_active=1; haproxy_active=0; mock_haproxy_enabled_state=disabled
fail_xray_validation=0; fail_haproxy_validation=0; fail_haproxy_restart=0; fail_ss=0; ss_mode=busy
if shared443_apply_transaction "$candidate" "$xray_config" "$haproxy_config" "$backup_root" xray.service haproxy.service 0; then
  echo "FAIL: occupied TCP/443 was accepted" >&2
  ((fail+=1))
elif [[ "$(cat "$xray_config")" == "old-xray-busy" ]] &&
     [[ "$(cat "$haproxy_config")" == "old-haproxy-busy" ]] &&
     (( xray_active )) && (( ! haproxy_active )); then
  echo "PASS: occupied TCP/443 aborts and restores the original Xray config"
  ((pass+=1))
else
  echo "FAIL: occupied TCP/443 did not restore the original config" >&2
  ((fail+=1))
fi

# A forced rollback rename failure must leave the protected backup available.
mapfile -t preserve_paths < <(make_case preserve)
candidate="${preserve_paths[0]}"
xray_config="${preserve_paths[1]}"
haproxy_config="${preserve_paths[2]}"
backup_root="${preserve_paths[3]}"
xray_active=1; haproxy_active=0; mock_haproxy_enabled_state=disabled
fail_xray_validation=0; fail_haproxy_validation=0; fail_haproxy_restart=1; fail_ss=0; ss_mode=normal
mv() {
  if [[ "${1:-}" == "-f" && "${2:-}" == "--" && "${3:-}" == "$(dirname -- "$xray_config")"/.africhome-restore.* && "${4:-}" == "$xray_config" ]]; then
    return 1
  fi
  command mv "$@"
}
if shared443_apply_transaction "$candidate" "$xray_config" "$haproxy_config" "$backup_root" xray.service haproxy.service 0; then
  echo "FAIL: forced shared-443 rollback failure unexpectedly succeeded" >&2
  ((fail+=1))
elif compgen -G "$backup_root/africhome-vmess-shared443.*/xray-config.json" >/dev/null &&
     grep -R -q 'old-xray-preserve' "$backup_root"/africhome-vmess-shared443.*/xray-config.json; then
  echo "PASS: failed shared-443 rollback retains the protected original Xray config"
  ((pass+=1))
else
  echo "FAIL: shared-443 rollback failure did not preserve the backup" >&2
  ((fail+=1))
fi
unset -f mv

printf '\nShared TCP/443 transaction tests: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
