# Central Port-Routing Architecture

Status: design specification; not yet deployed or enabled on a VPS.

## Goals

Africhome should allow several compatible tunnel services to share public TCP 443 and TCP 80 through a managed entry router, while keeping the currently working VLESS + REALITY service recoverable throughout any migration.

The router must be protocol-aware only where the protocol exposes a reliable discriminator. It must not claim that every TCP or UDP protocol can share one socket.

## Non-negotiable safety rules

1. Never replace or rewrite a live Xray configuration without a timestamped backup and a validated rollback path.
2. Never move the current public VLESS + REALITY listener from TCP 443 as part of an automatic upgrade. Port-sharing migration is an explicit, separately confirmed operation.
3. Keep a console session or provider console available during listener/firewall changes.
4. Bind protocol backends to loopback or a private interface when a front router owns the public port.
5. Validate generated router and backend configurations before changing listeners; check service health and listening sockets after each change.
6. On failure, restore the previous listener/configuration and restart the original service. Do not leave the public port unbound.
7. Treat client URIs, passwords, private keys, and generated credentials as secrets. Never print them in diagnostic logs or commit them.
8. Do not alter DNSTT configuration as part of TCP routing work.

## Proposed public entry points

### TCP 443: TLS/SNI-aware entry

Use a Layer-4 TCP router (initial candidate: HAProxy in TCP mode) to inspect ClientHello SNI and pass the original encrypted stream to the selected local backend. TLS passthrough is the default; the router must not terminate TLS unless a specific service mode explicitly requires it.

Candidate routing model:

- The existing VLESS + REALITY inbound is moved to a loopback backend port only during an explicitly approved migration. Its REALITY serverName must have a unique SNI route.
- Ordinary TLS services use separate, administrator-configured hostnames/SNIs and separate loopback backend ports.
- Trojan TLS, VLESS TLS, VMess WS+TLS, and TLS-wrapped SSH can be routed by SNI when their clients send distinct SNI values and the backend protocol is actually TLS-compatible.
- OpenVPN over a TLS wrapper (for example, a supported stunnel-style client/server arrangement) may be routed by SNI. Native OpenVPN TCP is not assumed to be ordinary TLS/SNI traffic and must use a dedicated port unless a tested wrapper is selected.
- SSH-over-TLS requires a TLS wrapper on both client and server sides. A raw SSH daemon cannot be selected by TLS SNI on its own.
- Unknown or missing SNI must go to a deliberately configured safe default or be rejected. Never send arbitrary unknown connections to an unrestricted third-party target.

REALITY caveat: REALITY is a modified TLS-like handshake and must be passed through unchanged to Xray. Do not TLS-terminate it at HAProxy, Nginx, Caddy, or another proxy. SNI inspection/passthrough is a candidate design, not a guarantee: it must be proven with the actual installed Xray version and a real client handshake before production cutover. If the router cannot reliably identify the configured REALITY SNI, retain the current direct Xray listener on public TCP 443 and use another public port or IP for the other services.

### TCP 80: HTTP and payload entry

Use an HTTP-aware frontend (candidate: Nginx or HAProxy HTTP mode) only for protocols that can be identified safely from HTTP request metadata:

- HTTP Host and URL path can route VLESS/VMess WebSocket or other explicitly supported HTTP-based transports to local backends.
- HTTP CONNECT payload-proxy mode may be provided as a distinct, authenticated feature with explicit destination allow-lists and abuse controls.
- SSH payload/direct modes need a documented client payload format and a tested server-side handler. Do not assume that a normal HTTP reverse proxy can convert arbitrary payload bytes into SSH.
- Plain/raw VLESS, native OpenVPN TCP, and arbitrary SSH streams cannot all share TCP 80 merely because they are assigned the same port.
- ACME HTTP-01 challenges must continue to work. Prefer a webroot or explicit /.well-known/acme-challenge/ route when the frontend owns port 80; do not stop the router or occupy port 80 unexpectedly during renewal.

### UDP: independent listeners and port allocation

UDP is managed separately from TCP routing. "UDP Direct" means an administrator may select an available UDP port (1-65535), not that multiple unrelated services can all bind every UDP port at once.

- Hysteria 2, OpenVPN UDP, and any future UDP service each need a distinct UDP bind unless a protocol-specific multiplexer is deliberately designed and tested.
- Check UDP listeners, firewall rules, provider firewall requirements, and configured port ranges before installation.
- Preserve existing Hysteria 2 and DNSTT UDP behavior. Do not change the user's existing firewall range automatically.
- Keep TCP and UDP conflict checks separate.

## Service compatibility matrix

| Requested mode | Public entry | Routing requirement | Design status |
|---|---|---|---|
| SSH Direct SSL | TCP 443 | TLS wrapper + unique SNI; TCP passthrough | Candidate |
| SSH Payload Direct | TCP 80 | Tested payload handler or dedicated listener | Candidate |
| SSH Payload Proxy | TCP 80/443 | Explicit HTTP proxy/CONNECT or TLS wrapper; authenticated and restricted | Candidate |
| SSH Payload + Proxy + SNI | TCP 80/443 | TLS wrapper for SNI on 443; HTTP proxy/payload handler on 80 | Candidate |
| VLESS REALITY | TCP 443 | Unmodified passthrough to Xray; unique REALITY SNI | Preserve first; router compatibility test required |
| VLESS TLS / WS | TCP 80/443 | SNI passthrough or HTTP Host/path routing, depending on TLS termination design | Candidate |
| VMess WS + TLS | TCP 443 | TLS SNI passthrough or TLS termination + WS path routing | Existing backend; test before moving |
| VLESS Payload Proxy | TCP 80 | HTTP-based transport and explicit path/host routing | Candidate; define client format |
| Trojan TLS | TCP 80/443 | TLS/SNI passthrough; backend must speak Trojan TLS | Candidate |
| UDP Direct | Chosen UDP port | Dedicated UDP listener and firewall allowance | Supported concept; not a shared socket |
| OpenVPN Direct TCP | TCP 1194 or chosen port | Dedicated native OpenVPN listener | Candidate |
| OpenVPN Direct UDP | UDP 1194 or chosen port | Dedicated native OpenVPN listener | Candidate |
| OpenVPN TLS/SNI | TCP 443 | Tested TLS wrapper; not assumed to be native OpenVPN | Candidate |
| OpenVPN WS / Payload + Proxy | TCP 80/443 | WebSocket-to-OpenVPN bridge/wrapper with compatible client | Candidate; integration test required |

## Configuration and management model

Add a Port & Routing Manager with these operations:

1. Inventory: show public listeners, service ownership, bind address, TCP/UDP protocol, and relevant firewall entries.
2. Plan: show the proposed SNI/Host/path-to-backend table and all detected conflicts without changing the server.
3. Add route: validate hostname, protocol, backend address/port, and service health before writing a route.
4. Apply: create timestamped backups, validate frontend/backend syntax, perform a controlled reload, and verify all expected listeners.
5. Roll back: restore the previous router and backend configuration from a selected backup.
6. Remove route: remove only the selected Africhome-managed route; never delete unrelated administrator configuration.
7. Diagnostics: show service state, recent relevant logs, listener map, certificate expiry, and firewall/provider-firewall reminders without exposing secrets.

Suggested state directory: /etc/africhome/port-routing/ with root-only state and timestamped backups. Generated router snippets should be clearly marked as Africhome-managed and must not overwrite administrator-owned configuration files.

## Installation phases

### Phase 0 — Read-only discovery

- Detect Ubuntu/Debian version, systemd, Xray version/config/service user, current TCP/UDP listeners, UFW/nftables/iptables state, certificate paths, and existing reverse proxies.
- Record the current VLESS + REALITY public listener and Xray config hash.
- Print a plan only. No service restarts, port moves, or firewall changes.

### Phase 1 — Isolated compatibility tests

- Build disposable local test configurations and temporary loopback listeners.
- Test SNI inspection against ordinary TLS, Trojan TLS, TLS-wrapped SSH, and the actual Xray REALITY client/server pair.
- Test HTTP Host/path routing and WebSocket upgrade behavior on a non-production port.
- Test OpenVPN only with the selected wrapper/client combination.
- Test UDP services independently.
- Reject any mode that cannot be distinguished reliably.

### Phase 2 — Optional TCP 80 routing

- Deploy the HTTP frontend on a maintenance-approved window.
- Preserve the ACME challenge route.
- Keep existing services on their current ports until the new listener and health checks pass.

### Phase 3 — Optional TCP 443 routing

- Require an explicit administrator confirmation and a verified provider-console rollback path.
- Configure the router and local backends while the original public 443 service is still intact on a temporary test port.
- Prove the REALITY SNI route with a real client, and prove all TLS routes independently.
- Only then perform a controlled cutover with an automatic rollback timer or equivalent watchdog.
- If REALITY passthrough fails any check, cancel the cutover and leave Xray directly bound to public 443.

### Phase 4 — Ongoing management

- Add/remove individual routes without rebuilding unrelated services.
- Renew certificates without interrupting unrelated routes.
- Reconcile firewall rules only for the selected service and port.
- Keep route inventory and backups after updates.

## Out of scope

The Africhome protocol menu must not add WireGuard, Iodine/SlowDNS, or ZIVPN. DNSTT remains the DNS tunnel service. Existing installations of excluded software are not automatically uninstalled.

## Acceptance criteria

- A dry-run plan reports all TCP and UDP conflicts before any changes.
- Existing VLESS + REALITY works before, during the test plan, and after rollback.
- REALITY traffic is never TLS-terminated by the router.
- Ordinary TLS routes require unique, verified SNI names.
- HTTP routes require explicit Host/path matches.
- Raw SSH and native OpenVPN are never advertised as multiplexable on a shared port without a tested wrapper.
- UDP services use distinct, conflict-checked listeners.
- Invalid frontend configuration never replaces a working configuration.
- Failed reload/cutover restores the previous config and service state.
- Tests cover syntax, route matching, rollback, certificate renewal, and service-account permissions.
- No installer action is run against a live VPS as part of CI.
