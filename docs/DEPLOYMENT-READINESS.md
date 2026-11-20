# Deployment readiness

**Status: release candidate code is substantially implemented, but not yet approved for production deployment.** The feature branch has passing automated regression tests; this does not prove protocol interoperability on a live VPS.

## Implemented and regression-tested foundations

- Installer Ed25519 licence verification and install-target safety checks.
- Existing Xray VLESS REALITY, VMess WebSocket/TLS, Trojan, Shadowsocks, Hysteria 2 and account-management modules.
- Read-only listener/service inventory.
- Central TCP 443 SNI, TCP 80 HTTP Host/path, and combined HAProxy configuration renderers.
- DNSTT bootstrap pinned to an immutable upstream release tag and commit, with verified source hashes, transactional Go toolchain replacement, transactional server/client binary replacement, and fault-injection rollback tests.
- Hysteria 2 installer pinned to a verified official release, architecture-specific binary checksum verification, transactional binary/unit/config rollback, transactional first setup, and certificate/key renewal rollback tests.
- VMess shared TCP 443 candidate generation: VLESS REALITY moves to loopback TCP 1443, VMess WebSocket + TLS uses loopback TCP 8443, and HAProxy routes TLS SNI to the appropriate backend. The generator validates the VMess certificate SAN and key match, supports safe Let's Encrypt symlinks, checks Xray service-user read access, and writes root-only candidate files, including the VMess management state used by the existing client/status menu functions.
- A guarded combined shared-443 apply command with root/licence gate, explicit APPLY confirmation, protected Xray/HAProxy backups, Xray-first migration, TCP/443 availability check, HAProxy listener ownership verification, and rollback. It writes protected VMess management state and blocks generic VMess removal while shared mode is active. Fault-injection tests cover HAProxy restart failure, another process occupying TCP/443, VMess state-file replacement failure, and a failed Xray restore.
- Native OpenVPN UDP/TCP setup, Easy-RSA CA, server/client certificate lifecycle, client profiles, revocation, service status, and read-only inventory.
- Protected backup collection and staged restore include /etc/openvpn, /etc/stunnel, the OpenVPN state file, and Africhome systemd units.

## Still required before production

- Run the shared-443 apply command on a clean disposable Ubuntu VPS, then verify VLESS REALITY and VMess clients connect and reconnect through the same public TCP 443 listener. The apply command has not been run on any live server.
- Validate DNSTT end-to-end with an external Android client, individual SSH customer accounts, resolver choices, DNS delegation and UDP listener.
- Validate Hysteria 2 installation, first setup, UDP reachability, client connection, certificate renewal and rollback on a disposable VPS.
- SSH TLS loopback backend is implemented; central SNI activation and supported client-app interoperability tests remain. Actual SSH payload/proxy gateway is still required.
- OpenVPN WebSocket, payload/proxy, and SNI wrapper backends remain unimplemented.
- End-to-end tests for each requested mode, including reconnects, invalid credentials, certificate renewal/revocation, and TCP/UDP conflict cases.
- Review firewall/provider rules, IP forwarding/NAT requirements, DNS/certificates, and rollback steps for the target VPS.
- Review and consolidate the release candidate into public main; the current default main branch is not the current release candidate.

## Safety boundaries

- No installer has been run against the live VPS as part of this development work.
- No live Xray, DNSTT, Hysteria, SSH, UFW, nftables, DNS or port configuration has been changed.
- The feature branch and draft pull requests remain unmerged. Do not install the default main branch until consolidation and review are complete.
- The shared-443 apply command replaces the complete /etc/haproxy/haproxy.cfg; review and back up any non-Africhome HAProxy configuration before using it.
- Do not treat a passing syntax/configuration test as proof of real client interoperability.
- Backups may contain private keys and certificates; keep them root-only and protected off-host.

## Validation interpretation

The full GitHub Actions suite passed on commit 398baf7cd37f4438c735bb4bef9740f1851fa97d (run 44708847611). Checks include shell syntax, ShellCheck, licence tests, DNSTT/Hysteria rollback fault injection, VMess shared-443 candidate tests and shared-443 apply/rollback fault injection. The checklist-only follow-up commit triggers another full run. These automated checks do not replace disposable-VPS and external-client integration testing.
