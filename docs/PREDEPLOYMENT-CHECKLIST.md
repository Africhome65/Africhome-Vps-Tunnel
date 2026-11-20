# Africhome VPS Tunnel — Pre-deployment Readiness Checklist

This checklist is a release gate. A passing shell-syntax workflow is not proof that a tunnel works on a real client. Do not deploy this branch to a production VPS until every required check below has evidence recorded.

## Release rules

- Keep the repository public.
- Keep pull requests in draft until review and disposable-server testing are complete.
- Never run the installer against a production VPS as a test.
- Do not change existing tunnel services, DNS records, firewall rules, or SSH policy during pre-deployment validation.
- Excluded from this project: WireGuard, ZIVPN, and Iodine/SlowDNS.
- Do not place licence signing private keys, customer passwords, DNSTT private keys, or generated client secrets in Git.

## Current code-review blockers

- [x] Pin the DNSTT source to the signed upstream release tag object `8fb3b30e6dbdc9006780327c6687623534d134f5` and commit `0c5c52a57d899c05428c116898941761a2ed83c2` (`v1.20260501.0`); the installer fetches the tag and verifies both hashes.
- [x] Make Go toolchain replacement transactional: restore the previous `/usr/local/go` if the staged toolchain cannot be installed.
- [x] Make the server/client binary pair replacement transactional: if either binary installation fails, restore both previous binaries.
- [ ] Add fault-injection tests for each rollback path above.
- [x] Verify licence issuance and verification using valid, expired legacy, malformed, wrong-VPS, altered-payload, altered-signature, and mismatched-key cases (GitHub Actions licence matrix passed).
- [x] Review the installer ordering so invalid licences cannot trigger package or service changes (regression test passed).
- [x] Review the integrated Hysteria 2 module against central routing; keep its UDP service separate from TCP SNI routing. Certificate renewal now validates matching cert/key files and has a rollback path.
- [ ] Complete fault-injection tests for DNSTT toolchain/binary rollback and Hysteria certificate-pair rollback.

## Automated checks

Latest full GitHub Actions run for PR #7: `44707458544` — passed on commit `d257f7cfd0697529ace1c56b99d74485dd07e7a2`. It includes DNSTT and Hysteria rollback fault-injection tests plus nine VMess shared-443 candidate tests, including Let's Encrypt symlink and Xray service-file-access checks. This is CI evidence only; it does not replace VPS/client integration testing.

- [x] All shell scripts pass `bash -n`.
- [x] ShellCheck passes with no errors.
- [x] All repository safety/regression scripts pass on the current PR head.
- [x] Menu smoke test exits cleanly and every menu option resolves to an existing handler.
- [x] Route planner rejects invalid ports, hostnames, transports, backends, and duplicate socket claims.
- [x] Candidate router renderers do not write active service configuration or restart services.
- [x] Licence tests pass without committing any private signing material.
- [x] DNSTT account tests cover create, list, renew, never-expire, disable, re-enable, reset, delete, and trial timer cleanup.

## DNSTT disposable-server validation

Use a clean disposable Ubuntu 22.04+ or supported Debian VPS.

- [ ] Install with a valid machine-bound licence; confirm invalid licence is rejected before package/repository changes.
- [ ] Verify the pinned upstream source and Go archive checksums.
- [ ] Build both DNSTT binaries and verify executable ownership/modes.
- [ ] Verify server private key is root-owned mode 0600 and public key is root-owned mode 0644.
- [ ] Configure an operator-owned tunnel domain and authoritative nameserver.
- [ ] Prepare the service and inspect its unit; confirm preparation does not start or enable it.
- [ ] Confirm UDP listen port is free before activation. Default is UDP 53; chosen alternate UDP ports must be in 1–65535 and must match DNS/provider firewall configuration.
- [ ] Confirm server upstream is the intended local TCP service (normally 127.0.0.1:22 for SSH).
- [ ] Activate only on the disposable VPS and verify DNS delegation, authoritative answers, and server logs.
- [ ] Connect from at least one real Android client that explicitly supports DNSTT.
- [ ] Verify the local client TCP listener, then SSH to 127.0.0.1:7001 using a non-root customer account.
- [ ] Test UDP DNS, DoT, and DoH resolver modes separately where supported by the client.
- [ ] Test invalid public key, wrong domain, unreachable resolver, blocked UDP, and occupied-port failure paths.
- [ ] Confirm trial expiry locks the account and terminates its sessions; confirm renewal cancels the old timer.
- [ ] Confirm exports contain no SSH password or DNSTT private key.

DNSTT port roles must remain distinct: server-side DNS transport is UDP (normally port 53); the DNSTT server forwards tunnel streams to local SSH TCP (normally 127.0.0.1:22); the client exposes a local TCP listener (normally 127.0.0.1:7001).

## VMess and central routing validation

- [ ] Confirm the actual VMess/Xray inbound and transport configuration supported by the chosen client.
- [ ] Confirm VMess on TCP 443 can coexist with any other TCP 443 service only through a tested, compatible SNI/TLS routing design.
- [ ] Confirm UDP and TCP listeners are inventoried independently.
- [ ] Test duplicate hostname, wildcard/no-SNI, unknown-SNI, and backend-unavailable behavior.
- [ ] Verify every routed backend is loopback-only and reachable.
- [ ] Run the generated candidate through the real HAProxy/Xray configuration validators before any application.
- [ ] Record rollback commands and prove restoration on the disposable VPS.
- [ ] Do not label a route production-ready based only on a planner saying `candidate`.

## Hysteria 2 validation and integration

- [ ] Review the separate Hysteria 2 feature branch and its installer/service lifecycle.
- [ ] Verify official binary/source provenance and checksums.
- [ ] Test domain validation, certificate issuance, renewal deploy hook, and certificate permissions, including forced failure between certificate and key replacement.
- [ ] Test UDP port and port-hopping ranges against actual listeners and provider firewall rules.
- [ ] Confirm existing Xray, DNSTT, SSH, and unrelated services remain untouched.
- [ ] Integrate only after central-router conflict checks and rollback behavior pass.

## Licence and release security

- [ ] Generate the Ed25519 signing key offline; keep the private key outside the repository and VPS.
- [ ] Verify issuer rejects symlinks, non-regular files, unsafe permissions, wrong ownership, and a key that does not match the repository public key.
- [ ] Verify tokens are machine-bound and UTC expiry is enforced.
- [ ] Verify saved token path is root-owned mode 0600 and licence directory is root-owned mode 0700.
- [ ] Review logs and error output for accidental secret disclosure.
- [ ] Verify no secrets, temporary keys, backups, or generated customer exports are tracked by Git.

## Final release gate

A release may be called **ready for deployment** only after:
1. All code-review blockers are closed.
2. All automated checks pass on the final commit.
3. DNSTT, VMess routing, and Hysteria 2 have each passed their applicable disposable-VPS/client tests.
4. Backup and rollback have been exercised.
5. Documentation explains DNS, firewall/provider firewall, ports, client setup, licence issuance, account management, and recovery.

Until then, label the project **pre-release / testing required**. Do not claim production readiness based on CI alone.
