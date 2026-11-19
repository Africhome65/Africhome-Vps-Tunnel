# Protocol Integration Contracts

This document records the implementation boundary for the requested Africhome services. It is a development contract, not an installer or a claim that the listed transports are already operational.

## Existing implementation facts

- `modules/ssh_users.sh` creates and manages Linux accounts. It does not implement an SSH-over-TLS listener, payload parser, HTTP proxy, SNI router, or SSH gateway.
- `modules/xray.sh` can create a VLESS REALITY inbound, but its current setup flow can replace the whole Xray configuration after confirmation. It must not be used as the shared-router integration mechanism.
- `modules/vmess.sh` creates a VMess WebSocket + TLS inbound and terminates TLS inside Xray.
- `modules/trojan.sh` creates a Trojan TLS inbound and terminates TLS inside Xray.
- There is no OpenVPN integration module in this branch at this time.
- The central router module is currently a validation/planning layer; it does not bind sockets or configure services.

## Shared TCP ports: mandatory prerequisites

A shared public TCP listener on 80 or 443 may be introduced only after the selected frontend is proven to distinguish each requested client transport without corrupting it. Each backend must bind only to loopback. The frontend must preserve the original stream for protocols that require end-to-end TLS or custom handshakes.

A route is not considered implemented merely because a port and mode name appear in the catalogue. Each route requires:
1. A documented client transport and matching server-side protocol.
2. A backend process and explicit loopback bind address/port.
3. A frontend rule that can actually identify the traffic (SNI from a valid TLS ClientHello, HTTP Host/path for HTTP, or a protocol-aware payload handler).
4. Collision checks against all existing TCP listeners and route identifiers.
5. Configuration validation, backup, atomic replacement, service health verification, and rollback.
6. A client profile generated from the exact committed server configuration.
7. A reproducible interoperability test before capability is marked implemented.

## SSH transport contracts

The Linux account manager remains separate from the transport gateway.

- **SSH Direct SSL / TCP 443:** requires a TLS wrapper that forwards the decrypted or passed-through stream to a loopback SSH backend, with a clearly defined client-side TLS mode.
- **SSH Payload Direct / TCP 80:** requires a documented payload handshake and compatible client request format. A raw TCP forwarder is not a payload handler.
- **SSH Payload Proxy / TCP 80:** requires an HTTP proxy or payload-aware gateway, including authentication and CONNECT/upgrade policy where applicable.
- **SSH Payload + Proxy + SNI / TCP 443:** requires a valid TLS ClientHello/SNI routing strategy and a compatible SSH-over-TLS client. SNI alone cannot identify non-TLS payloads.
- **SSH Payload + Proxy / TCP 80:** requires explicit HTTP/payload parsing and a matching client profile.

No SSH gateway is marked implemented until those handlers, limits, logs, account mapping, and external client tests exist.

## Xray / V2Ray contracts

- **VLESS REALITY:** preserve the existing inbound, UUIDs, private key, short IDs, flow, and routing settings. REALITY is not ordinary TLS and must not be TLS-terminated by a generic HTTPS frontend. It is preserve-only behind a shared frontend until a compatible passthrough design is demonstrated.
- **VLESS or VMess WebSocket + TLS:** the TLS termination point must be singular. If Xray terminates TLS, the frontend must pass TLS through; if a frontend terminates TLS, the Xray backend must use a correctly configured non-TLS WS inbound. Never configure both sides to expect the same TLS layer.
- **VLESS payload/HTTP transport:** keep distinct from WebSocket. It needs its own supported Xray transport settings and client profile; do not relabel WS as payload.
- **V2Ray SSL:** define which protocol and TLS termination arrangement this label means before implementation.

The current standalone VMess module uses a TLS certificate directly in Xray and defaults to TCP 8443. The current REALITY setup can replace the whole Xray config. Both require safe integration refactoring before central routing can own ports 80/443.

## Trojan contracts

The current Trojan module terminates TLS inside Xray and defaults to TCP 8443. For shared TCP 443 or 80, select and test one design:
- TLS passthrough to a Trojan TLS backend, with routing based on a compatible ClientHello/SNI; or
- frontend TLS termination plus a backend configuration and client transport that explicitly support the resulting stream.

An HTTP reverse proxy is not automatically a valid Trojan gateway. Do not advertise Trojan on 80/443 until a matching client profile and end-to-end handshake test pass.

## OpenVPN contracts

No OpenVPN module is present in this branch. Implement separately for:
- Direct TCP 443, TCP 80, and TCP 1194.
- Direct UDP 1194.
- TLS/SNI TCP 443.
- WebSocket/payload/proxy mode.

Native OpenVPN TCP/UDP listeners require dedicated sockets unless a tested protocol-aware frontend supports the exact transport. WebSocket wrapping and payload/proxy modes require compatible client-side wrapping; a port mapping alone is insufficient. Keep UDP allocation independent from TCP routing and reject occupied ports.

## UDP services

- UDP Direct: configurable port, exact UDP-only conflict inventory, and no silent rebinding.
- Hysteria 2: preserve the existing service and its port/firewall/NAT arrangement unless a migration is explicitly approved.
- DNSTT: preserve its existing key, domain, service, and DNS routing. DNSTT is distinct from SlowDNS/Iodine and remains in scope. It must not be assumed to share an arbitrary UDP port with another protocol.

## Capability labels

Use these labels consistently in the menu, documentation, and generated output:
- **Implemented:** code exists and automated plus client interoperability checks pass.
- **Configuration available:** a standalone configuration path exists, but central routing/interoperability is not proven.
- **Planned:** catalogue or design only.
- **Preserve-only:** existing service/configuration must be retained; no shared-port claim is made.

## Excluded protocols

Do not add WireGuard, ZIVPN, Iodine, or SlowDNS to this product's protocol catalogue. DNSTT remains included.
