# DNSTT Client Compatibility

Africhome DNSTT is a transport layer, not a standalone VPN server or a
universal VPN-app import format. Compatibility depends on the client app's
implementation of the DNSTT wire protocol and its account/configuration model.

## Shared server architecture

1. Africhome runs the DNSTT server and forwards the tunnel stream to SSH on
   `127.0.0.1:22`.
2. A client app resolves the configured tunnel domain through a recursive DNS
   resolver and establishes the DNSTT session.
3. The client exposes the tunnel to its SSH/network stack.
4. The VPS SSH daemon authenticates the customer's individual Linux username
   and password. DNSTT's public key authenticates the tunnel server.

The recursive resolver (for example `8.8.8.8:53`) is not the authoritative
nameserver. DNS delegation and the tunnel domain are configured separately.

## App compatibility status (research, not device certification)

Official app listings currently advertise DNSTT support in these apps:

| Application | Published protocol claim | Africhome status |
|---|---|---|
| ZIVPN Tunnel | Lists “Slow DNS Tunnel (DNSTT)” and V2Ray over Slow DNS | Native DNSTT feature advertised; test against this server and confirm fields/export format |
| HTTP Injector | Lists “DNS Tunnel (DNSTT / SlowDNS)” | Native DNSTT feature advertised; test server interoperability and customer profile format |
| NapsternetV / NPV Tunnel | Lists DNSTT among supported protocols and supports file/QR/link/clipboard imports | Native DNSTT feature advertised; identify exact config schema and test import |
| HTTP Custom | Lists “SlowDNS” but does not explicitly identify DNSTT in the current published protocol list | Do not assume DNSTT wire compatibility; investigate whether its SlowDNS implementation is compatible |
| TLS Tunnel | Published listing confirms SSH/private-server features, but no DNSTT claim was found | No confirmed DNSTT support; do not advertise as compatible |

Sources:
- ZIVPN Google Play listing: https://play.google.com/store/apps/details?id=com.zi.zivpn
- HTTP Injector Google Play listing: https://play.google.com/store/apps/details?id=com.evozi.injector
- NapsternetV / NPV Tunnel Google Play listing: https://play.google.com/store/apps/details?id=com.napsternetlabs.napsternetv
- HTTP Custom Google Play listing: https://play.google.com/store/apps/details?id=xyz.easypro.httpcustom
- TLS Tunnel Google Play listing: https://play.google.com/store/apps/details?id=com.tlsvpn.tlstunnel

A published protocol claim is not proof that a particular app version interoperates
with Africhome's server settings. Record the app version, Android version, exact
mode, and successful end-to-end test before marking it verified.

## Required implementation approach

- Keep DNSTT server installation, keys, DNS delegation, and customer SSH
  accounts independent of any one Android VPN application.
- Prefer each app's native DNSTT implementation where it is documented. Do not
  assume every app requires an external `dnstt-client` process.
- Maintain a generic DNSTT profile with tunnel domain, recursive resolver,
  public key, SSH host/port, customer username, and account expiry.
- Build app-specific exports only from the app's documented import schema.
  NapsternetV's `.npv4` format must not be guessed or fabricated.
- Do not put SSH passwords in exported files by default. Deliver credentials
  separately through a secure channel.
- Never distribute the DNSTT private key or VPS root credentials.
- If an app's SlowDNS mode is not proven to use the same DNSTT protocol, mark
  it unverified rather than treating “SlowDNS” and “DNSTT” as synonyms.

## Acceptance tests before claiming Africhome support

1. Verify DNS delegation and reachability of the VPS DNSTT listener from an
   external network.
2. Test the official DNSTT client with the public key, tunnel domain, and
   selected recursive resolver.
3. For each native app, import/create a profile using its documented DNSTT
   mode and the Africhome server details.
4. Confirm the app establishes a tunnel and that SSH authenticates a non-root
   customer account.
5. Confirm wrong credentials are rejected and account disable/expiry prevents
   new SSH sessions.
6. Record app version, Android version, exact settings, logs, and a successful
   end-to-end test on mobile data and Wi-Fi.
7. Only then mark that app/server combination as verified.

## Security

The DNSTT public key authenticates the tunnel server. SSH credentials
authenticate each customer. The public key is safe to distribute; the private
key and root credentials are not.
