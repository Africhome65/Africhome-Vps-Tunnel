# Deployment readiness

**Status: not ready for production deployment.** The feature branch is still under development. CI passing means the automated regression suite passed; it does not prove that every protocol works end to end on a live VPS.

## Implemented and regression-tested foundations

- Installer licence verification and install-target safety checks.
- Existing Xray VLESS REALITY, VMess WebSocket/TLS, Trojan, Shadowsocks, Hysteria 2 and account-management modules.
- Read-only listener/service inventory.
- Central TCP 443 SNI, TCP 80 HTTP Host/path, and combined HAProxy configuration renderers. These generate and validate candidates only.
- Native OpenVPN UDP/TCP setup, Easy-RSA CA, server/client certificate lifecycle, client profiles, revocation, service status, and read-only inventory.
- Protected backup collection and staged restore now include `/etc/openvpn`, `/etc/stunnel`, the OpenVPN state file, and Africhome systemd units.

## Still required before production

- SSH TLS loopback backend is implemented; central SNI activation and supported client-app interoperability tests remain. Actual SSH payload/proxy gateway is still required.
- OpenVPN WebSocket, payload/proxy, and SNI wrapper backends.
- Safe central-router activation, port ownership checks, staged backup, service rollback, and migration plan for the existing VLESS REALITY listener.
- End-to-end tests for each requested mode, including reconnects, invalid credentials, certificate renewal/revocation, and TCP/UDP conflict cases.
- Complete disposable-VPS and external-client validation of the integrated DNSTT bootstrap, domain configuration, prepared service, account lifecycle, resolver modes, and configuration export. The scripts preserve existing keypairs and deliberately do not start DNSTT or change live DNS/firewall state.
- Review firewall/provider rules, IP forwarding/NAT requirements, DNS/certificates, and rollback steps for the target VPS.

## Safety boundaries

- No installer has been run against the live VPS as part of this development work.
- No live Xray, DNSTT, Hysteria, SSH, UFW, nftables, or port configuration has been changed.
- The feature branch must not be merged or installed until the remaining implementation and review are complete.
- Do not apply a generated HAProxy candidate to a live host merely because `haproxy -c` accepts it.
- Backups may contain private keys and certificates; keep them root-only and protected off-host.

## Validation interpretation

The GitHub Actions Bash syntax and full validation workflows have passed on recent feature-branch commits. Each new commit triggers another run. These checks cover shell syntax, static/regression tests, configuration renderers and safety assertions; they do not replace a disposable-VPS integration test.
