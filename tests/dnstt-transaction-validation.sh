#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/dnstt-transaction.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
pass=0
fail=0

go_is_new_enough() {
  local bin="$1" version major minor
  [[ -x "$bin" ]] || return 1
  version="$("$bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
  [[ -n "$version" ]] || return 1
  IFS=. read -r major minor _ <<< "${version%%-*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > 1 || (major == 1 && minor >= 21) ))
}

make_go_tree() {
  local dir="$1" version="$2"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/go" <<EOF
#!/usr/bin/env bash
echo "go version $version linux/amd64"
EOF
  chmod 0755 "$dir/bin/go"
}

# A failed stage rename must restore the previous Go toolchain.
go_target="$TMP/go-install"
go_stage="$TMP/go-stage-move-fail"
make_go_tree "$go_target" "go1.26.1"
make_go_tree "$go_stage" "go1.27.4"
inject_go_move_fail=1
mv() {
  if [[ "${1:-}" == "--" && "${2:-}" == "$go_stage" && "${3:-}" == "$go_target" && "$inject_go_move_fail" == "1" ]]; then
    inject_go_move_fail=0
    return 1
  fi
  command mv "$@"
}
if dnstt_install_go_toolchain "$go_stage" "$go_target"; then
  echo "FAIL: injected Go stage rename failure unexpectedly succeeded" >&2
  ((fail+=1))
elif "$go_target/bin/go" version | grep -q 'go1.26.1'; then
  echo "PASS: Go stage rename failure restored the previous toolchain"
  ((pass+=1))
else
  echo "FAIL: Go stage rename failure did not restore the previous toolchain" >&2
  ((fail+=1))
fi
unset -f mv

# A staged Go version below the minimum must be discarded and the old one restored.
go_stage="$TMP/go-stage-invalid"
make_go_tree "$go_target" "go1.26.1"
make_go_tree "$go_stage" "go1.20.9"
if dnstt_install_go_toolchain "$go_stage" "$go_target"; then
  echo "FAIL: invalid Go version unexpectedly installed" >&2
  ((fail+=1))
elif "$go_target/bin/go" version | grep -q 'go1.26.1'; then
  echo "PASS: invalid Go version was rejected and old toolchain restored"
  ((pass+=1))
else
  echo "FAIL: invalid Go version did not restore old toolchain" >&2
  ((fail+=1))
fi

# A successful Go replacement must install the pinned version and remove its backup.
go_stage="$TMP/go-stage-good"
make_go_tree "$go_stage" "go1.27.4"
dnstt_install_go_toolchain "$go_stage" "$go_target"
if "$go_target/bin/go" version | grep -q 'go1.27.4' && ! compgen -G "$go_target.africhome-backup.*" >/dev/null; then
  echo "PASS: valid Go toolchain installed and old backup cleaned"
  ((pass+=1))
else
  echo "FAIL: valid Go toolchain replacement did not complete cleanly" >&2
  ((fail+=1))
fi

# A successful binary pair replacement must publish both candidates together.
success_bindir="$TMP/bin-success"
mkdir -p "$success_bindir"
dnstt_replace_binary_pair "$TMP/server-new" "$TMP/client-new" "$success_bindir"
if [[ "$(cat "$success_bindir/dnstt-server")" == "new-server" &&
      "$(cat "$success_bindir/dnstt-client")" == "new-client" ]] &&
   ! compgen -G "$success_bindir/.africhome-dnstt-backup.*" >/dev/null; then
  echo "PASS: successful DNSTT binary pair replacement installed both candidates"
  ((pass+=1))
else
  echo "FAIL: successful DNSTT binary pair replacement was incomplete" >&2
  ((fail+=1))
fi

# A failure on the second binary move must restore the previous server/client pair.
bindir="$TMP/bin-pair"
mkdir -p "$bindir"
printf 'old-server\n' > "$bindir/dnstt-server"
printf 'old-client\n' > "$bindir/dnstt-client"
printf 'new-server\n' > "$TMP/server-new"
printf 'new-client\n' > "$TMP/client-new"
inject_client_fail=1
mv() {
  if [[ "${1:-}" == "-f" && "${2:-}" == "--" && "${3:-}" == "$bindir"/.dnstt-client.new.* && "${4:-}" == "$bindir/dnstt-client" && "$inject_client_fail" == "1" ]]; then
    inject_client_fail=0
    return 1
  fi
  command mv "$@"
}
if dnstt_replace_binary_pair "$TMP/server-new" "$TMP/client-new" "$bindir"; then
  echo "FAIL: injected DNSTT client move failure unexpectedly succeeded" >&2
  ((fail+=1))
elif [[ "$(cat "$bindir/dnstt-server")" == "old-server" && "$(cat "$bindir/dnstt-client")" == "old-client" ]]; then
  echo "PASS: second binary move failure restored the previous server/client pair"
  ((pass+=1))
else
  echo "FAIL: DNSTT binary pair was not restored after injected failure" >&2
  ((fail+=1))
fi
unset -f mv

# If restoration itself fails, the protected backup directory must be retained.
printf 'old-server-2\n' > "$bindir/dnstt-server"
printf 'old-client-2\n' > "$bindir/dnstt-client"
inject_client_fail=1
inject_restore_fail=1
mv() {
  if [[ "${1:-}" == "-f" && "${2:-}" == "--" && "${3:-}" == "$bindir"/.dnstt-client.new.* && "${4:-}" == "$bindir/dnstt-client" && "$inject_client_fail" == "1" ]]; then
    inject_client_fail=0
    return 1
  fi
  if [[ "${1:-}" == "-f" && "${2:-}" == "--" && "${3:-}" == "$bindir"/dnstt-server.restore.* && "${4:-}" == "$bindir/dnstt-server" && "$inject_restore_fail" == "1" ]]; then
    inject_restore_fail=0
    return 1
  fi
  command mv "$@"
}
if dnstt_replace_binary_pair "$TMP/server-new" "$TMP/client-new" "$bindir"; then
  echo "FAIL: injected rollback failure unexpectedly succeeded" >&2
  ((fail+=1))
elif compgen -G "$bindir/.africhome-dnstt-backup.*" >/dev/null &&
     grep -R -q 'old-server-2' "$bindir"/.africhome-dnstt-backup.*/dnstt-server; then
  echo "PASS: failed binary rollback retained protected previous binaries"
  ((pass+=1))
else
  echo "FAIL: failed binary rollback did not retain protected backups" >&2
  ((fail+=1))
fi
unset -f mv

printf '\nDNSTT transaction tests: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
