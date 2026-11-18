# DNSTT Client Compatibility

Africhome DNSTT is a transport layer, not a standalone VPN protocol or a universal
VPN-app import format. The DNSTT client creates a local TCP listener; an SSH
client or another application that can use that listener must connect to it.

## Shared connection architecture

1. The device runs a compatible `dnstt-client` binary.
2. The client sends DNS tunnel traffic to a recursive resolver and reaches the
   configured DNSTT tunnel domain.
3. DNSTT exposes a local TCP listener on the device (the examples use
   `127.0.0.1:7001`).
4. A local SSH client connects to that listener using the customer's Linux
   username and password. The server's SSH daemon authenticates the customer.
5. The DNSTT server forwards the tunnel stream to the configured SSH service.

The recursive resolver (for example `8.8.8.8:53`) is not the authoritative
nameserver. The authoritative DNS delegation and DNSTT tunnel domain must be
configured separately.

## App compatibility status

No app below should be advertised as DNSTT-compatible until a real end-to-end
test has been completed with the named app version, Android version, and
connection mode.

| Application | Current status | What must be verified |
|---|---|---|
| ZIVPN | Not yet verified | Whether the selected mode can use an externally running DNSTT client/local TCP or SOCKS proxy, and whether its SSH fields map to the local listener |
| HTTP Injector | Not yet verified | Whether its SSH/proxy mode can target the local DNSTT listener without trying to establish a separate incompatible transport |
| HTTP Custom | Not yet verified | Whether its supported SSH/custom payload mode can use a local tunnel endpoint |
| NapsternetV | Not yet verified | Whether the app supports an external local TCP/SOCKS endpoint or a compatible import format |
| TLS Tunnel | Not yet verified | Whether the app can use an external DNSTT local listener; TLS Tunnel's own transport must not be assumed to be DNSTT |

## Required implementation approach

- Keep DNSTT server installation, keys, DNS delegation, and customer SSH
  accounts independent of any one Android VPN application.
- Distribute the DNSTT client binary separately for each supported platform,
  with checksums and platform-specific installation instructions.
- Generate a generic profile containing the tunnel domain, recursive resolver,
  public key, local listener address, SSH host/port, customer username, and
  account expiry. Never include the DNSTT private key.
- Do not put SSH passwords in exported files by default. Deliver credentials
  separately through a secure channel.
- Treat app-specific configuration exports as separate adapters. Only add an
  adapter after confirming the app's documented import schema and testing it
  on a real device.
- If an app cannot launch or connect to an external DNSTT client/local listener,
  mark it unsupported for this architecture rather than claiming compatibility.

## Acceptance tests before claiming support

1. Verify DNS delegation and reachability of the DNSTT server from an external
   network.
2. Start the platform's DNSTT client and confirm the local listener is created.
3. Connect an SSH client through the listener using a non-root customer account.
4. Confirm wrong credentials are rejected and the correct account is accepted.
5. Confirm account expiry/disable actions prevent new SSH sessions.
6. For each Android app, record app version, Android version, selected mode,
   exact local endpoint configuration, and a successful end-to-end test.
7. Test on mobile data and Wi-Fi; do not infer success from a server-side test.

## Security

The DNSTT public key authenticates the tunnel server. SSH username/password
authenticates the customer. Never distribute the DNSTT private key or VPS root
credentials. A public key is not a customer credential.
