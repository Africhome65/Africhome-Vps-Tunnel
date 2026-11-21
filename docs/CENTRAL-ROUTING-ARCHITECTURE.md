# Central Port Routing and Protocol Integration

## Status

This document is the implementation contract for central port routing. The central-router menu module remains a validation/planning layer. Separate scripts now provide HAProxy renderers, read-only preflight, and guarded apply transactions. A VMess + VLESS REALITY shared-TCP-443 candidate and guarded apply path exist, but external client interoperability has not been proven; do not treat this as production-ready or as support for every catalogue mode.

## Required architecture

- A single, explicitly managed TCP frontend may own public TCP 80 and/or 443.
- Protocol backends must bind to loopback-only addresses and distinct backend ports.
- TCP routing may use SNI only when the client sends a usable TLS ClientHello and the selected backend can accept the forwarded byte stream.
- HTTP Host/path and WebSocket routing require an HTTP-aware frontend and a matching client transport.
- UDP is allocated independently by exact protocol/port socket. A port is not shareable merely because two services use UDP.
- Existing listeners and firewall rules must be inventoried and backed up before any migration. The implementation must never silently replace an existing listener.

## VLESS REALITY preservation

VLESS REALITY is not an ordinary TLS-terminated inbound. Do not place it behind a TLS-terminating proxy and do not rewrite it as a normal TLS backend. Preserve the existing Xray inbound and its credentials during all unrelated changes.

A TCP passthrough frontend may be considered only after confirming that its ClientHello/SNI inspection is compatible with the actual REALITY handshake and that the REALITY route is selected deterministically. The current candidate/apply code renders a passthrough route and validates local Xray/HAProxy configuration, but this does not prove REALITY interoperability. External VLESS REALITY connection/reconnect tests through the shared listener remain a release blocker. If compatibility cannot be demonstrated, keep REALITY on its existing dedicated public socket or a separate IP. No automatic migration is permitted.

## Xray backend integration

The existing Xray module creates VLESS REALITY directly in the Xray config. The VMess module supports a standalone TLS inbound and a separate shared-443 candidate workflow that renders a loopback VMess WS/TLS backend alongside a loopback REALITY backend. The guarded apply script can transactionally update Xray and HAProxy after explicit confirmation and preflight checks. This path still requires disposable-VPS rollback and external client testing. Trojan remains a standalone TLS-terminating inbound and is not a shared-router backend.

Before extending shared routing to another protocol or transport:
1. Introduce a tagged, loopback-bound backend profile for each supported Xray transport.
2. Merge inbounds into the existing JSON config; never replace the full config as part of a mode add.
3. Preserve every unknown inbound, outbound, routing rule, DNS setting, and API setting.
4. Reject duplicate tags and backend socket collisions before writing.
5. Write to a temporary file, validate with the installed Xray binary, retain a permission-preserving backup, then atomically replace.
6. Do not restart Xray or change firewall rules until the user explicitly confirms the reviewed change.
7. Generate client links from the exact saved backend settings, not from assumed defaults.

### Transport boundaries

- VLESS REALITY: preserve as a dedicated REALITY inbound; no TLS termination.
- VLESS/VMess WebSocket over TLS: can be a loopback backend only when TLS termination and WebSocket forwarding are deliberately assigned to one layer. Do not terminate TLS twice.
- VLESS over HTTP/payload: not equivalent to WebSocket. Require an explicit Xray transport, path/Host definition, and matching client support.
- Trojan TLS: either TLS passthrough to a backend that terminates TLS, or deliberate frontend termination with a compatible Trojan backend mode. Do not assume a generic HTTP reverse proxy can carry raw Trojan.
- A direct/raw TCP inbound cannot share a socket with another raw listener without a protocol-aware discriminator.

## SSH gateway boundaries

The current SSH account module manages Linux users; it is not an SSH-over-TLS gateway or HTTP payload proxy.

Any future gateway must be a separate component with:
- a loopback-only SSH backend or a deliberately selected sshd listener;
- a documented TLS wrapper or protocol-aware proxy;
- explicit SNI/Host/payload rules and client configuration examples;
- authentication forwarding that does not expose Linux passwords in logs;
- connection limits, timeouts, audit logging, and a clean removal/rollback path.

Do not advertise SSH Direct SSL, Payload Direct, Payload Proxy, or Payload + Proxy + SNI as implemented until the corresponding gateway and client interoperability are tested.

## OpenVPN and UDP

The OpenVPN module provides native TCP/UDP server management, Easy-RSA CA and client-certificate lifecycle, profile export, revocation, status, and read-only inventory. It does not implement TLS/SNI or WebSocket wrapper modes, payload/proxy modes, automatic firewall/NAT setup, or central-router integration. Those modes require a separately designed wrapper/bridge and compatible client. Native OpenVPN TCP/UDP listeners remain dedicated sockets unless a tested frontend explicitly supports that transport.

UDP Direct, Hysteria 2, and DNSTT require exact port allocation and conflict detection. Preserve the current Hysteria 2 and DNSTT deployment. DNSTT remains included; WireGuard, ZIVPN, Iodine, and SlowDNS remain excluded.

## Required safety gates before activation

- Read-only inventory of TCP/UDP listeners and firewall state.
- Explicit route table showing public socket, discriminator, backend socket, and service owner.
- Collision check across every proposed route, including duplicate SNI names.
- Backup of all affected service configs and firewall state.
- Config validation for every affected daemon.
- User approval before firewall edits, service restarts, listener migration, or installation.
- External client interoperability test for each mode before it is marked supported.

## Capability labels

Use only these labels in menus and documentation:
- **Implemented**: code exists and its required local and external interoperability tests have passed.
- **Configuration available**: code can generate and validate a configuration, but live connectivity has not been proven.
- **Planned**: design/catalogue only; no operational handler.
- **Preserve-only**: existing deployment is retained; no new shared-routing support is claimed.
