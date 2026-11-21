# Android client acceptance matrix

This document separates protocol support in the server from actual Android-app interoperability. A protocol name in the menu or an app-store description is not proof that an Africhome profile works.

## Known project-side profile contracts

| Service | Server-side contract | Android acceptance requirement |
|---|---|---|
| DNSTT | DNSTT server forwards the tunnel stream to SSH on loopback; each customer authenticates with an individual Linux SSH account. | The app must implement the DNSTT wire protocol or invoke a compatible DNSTT client. Verify tunnel domain, recursive resolver, public key, SSH host/port and customer credentials. |
| VLESS REALITY | Xray VLESS REALITY; generated client URI must preserve UUID, Vision flow, SNI, fingerprint, public key and short ID. | Import the exact generated `vless://` URI into an Xray-compatible Android client and verify direct and shared-443 modes separately. |
| VMess WebSocket + TLS | Xray VMess WS/TLS; shared-443 candidate routes SNI to the loopback VMess backend. | Import the generated VMess profile and test TLS/SNI, WebSocket path, authentication, reconnect and shared TCP 443. |
| Hysteria 2 | Hysteria 2 over UDP with TLS and username/password authentication. | Use a Hysteria 2-capable client; verify server name, UDP reachability, authentication and certificate renewal. |
| OpenVPN native | OpenVPN UDP or TCP with per-client certificates and revocation. | Import the generated `.ovpn` profile into an OpenVPN-compatible Android client; verify certificate validation and revoked-client rejection. |
| SSH over TLS | Stunnel TLS frontend is currently a loopback backend only; no public SNI route or universal Android wrapper is implied. | A client-side TLS wrapper compatible with the chosen SSH app must be specified and tested before this mode is advertised. |

## Recommended primary Android client

**Primary target: NPV Tunnel (NapsternetV), Android.** Its current Google Play listing explicitly names VLESS, VMess, Hysteria2, SSH and DNSTT, plus custom Xray JSON configuration. That gives the project the broadest single-app overlap across its current proxy/tunnel protocols. This is a recommendation for the first interoperability test target, not a claim that Africhome profiles have already passed.

- Official Google Play listing: https://play.google.com/store/apps/details?id=com.napsternetlabs.napsternetv
- Test in this order: DNSTT; VLESS REALITY; VMess WebSocket/TLS; Hysteria2; then any SSH mode actually exposed by the script.
- Confirm the app version and the precise import schema before implementing NPV-specific QR, link or `.npv4` exports. Do not guess a proprietary format.
- Exclude WireGuard from all Africhome-generated profiles and menus even though the app supports it.

**Separate OpenVPN client:** use OpenVPN Connect for the native OpenVPN profile. NPV Tunnel is not the acceptance target for OpenVPN. If a future SSH-over-TLS or SSH payload mode needs a specific client wrapper, select that client only after its exact protocol contract is implemented and tested.

**Fallback for Xray/Hysteria2-only testing:** NekoBox for Android is a good secondary client for VLESS/REALITY, VMess and Hysteria2, but it is not the primary DNSTT acceptance target. Use the project's upstream GitHub releases/documentation and verify the distribution source carefully; do not install unofficial repackaged builds.

## Candidate apps discussed during planning

NapsternetV / NPV Tunnel, HTTP Injector, HTTP Custom and TLS Tunnel have been mentioned as possible Android clients. No app/version has yet been certified against the current Africhome server configuration.

- Do not assume that an app's “SlowDNS” feature implements the DNSTT wire protocol.
- Do not fabricate an NPV, HTTP Injector or other proprietary import file/QR schema.
- Do not label an app compatible until a real profile has been imported and a connection has succeeded.
- WireGuard and ZIVPN are excluded from this project and must not be added to the client catalogue.

## DNSTT profile fields

A generic DNSTT profile/export may contain only the public connection information needed by the client:

- Tunnel domain and recursive resolver endpoint.
- DNSTT server public key.
- SSH host and port.
- Customer Linux username and account expiry/status.

Do not include the DNSTT private key, VPS root credentials, or SSH password in a public export. Deliver customer passwords separately through a secure channel.

The recursive resolver is not the authoritative nameserver. DNS delegation for the DNSTT domain must be configured and verified independently.

## Required mobile acceptance record

For every app/protocol combination, record:

1. App name and exact version.
2. Android version and device model.
3. Profile source and exact non-secret settings.
4. Network used (mobile data and Wi-Fi).
5. Successful tunnel establishment and SSH/VPN traffic.
6. Reconnect after network interruption.
7. Wrong-credential rejection.
8. Expiry/revocation behavior where applicable.
9. Relevant sanitized logs and timestamp.

Only a passing record changes the status from **planned/unverified** to **verified**. A successful shell test, server-side listener, or generated profile alone is not an Android interoperability test.
