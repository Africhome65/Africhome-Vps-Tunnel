# Africhome VPS Tunnel

A terminal-only VPS installation and management toolkit for Ubuntu 22.04+ and Debian 11+. No web panel.

## Implemented modules

- SSH Linux account creation, listing, locking/unlocking, and expiry management
- Fail2ban installation and status
- UFW status and guarded enablement
- Basic nftables filtering for common BitTorrent ports (not comprehensive torrent detection)
- Xray installation and VLESS + REALITY TCP server setup, service controls, and client import URI
- VMess over WebSocket + TLS inbound management, client import URI, status, and removal
- Trojan over TLS inbound management, generated password, client URI, status, and removal
- Shadowsocks AEAD inbound management using Xray, client URI, status, and removal
- Hysteria 2 server management with a user-defined domain, UDP port or port-hopping range, Let's Encrypt TLS, and client URI
- Managed VLESS, VMess, and Trojan accounts with manual and daily automatic expiry
- Read-only TCP/UDP listener, firewall, and relevant service inventory for future port-routing planning

## Central routing status

- Central TCP/UDP route validation and planning primitives are available; they do not configure listeners, proxies, firewall rules, or services.
- The requested shared-port modes remain planned until their protocol handlers and client interoperability are implemented and verified.
- VLESS REALITY is preserve-only for the shared-router work and must not be treated as ordinary TLS.
- SSH account management creates Linux users only; it does not provide an SSH TLS/payload gateway.
- OpenVPN integration is not yet present.
- See [the central routing architecture contract](docs/CENTRAL-ROUTING-ARCHITECTURE.md) for required backend, safety, and compatibility rules.

## Planned / not yet implemented

- Per-client connection/concurrency limits (not implemented)

## Requirements

- Ubuntu 22.04 or newer, or Debian 11 or newer
- Root access
- Public IP or DNS endpoint and provider firewall access for tunnel ports
- For VLESS REALITY: chosen TCP port (default 443)
- For VMess and Trojan: a DNS name pointing to the VPS and an existing valid TLS certificate/private key
- For Shadowsocks: a reachable public IP or DNS name; TCP and UDP on the selected port

## Installation

Review scripts before running:

```bash
git clone https://github.com/Africhome65/Africhome-Vps-Tunnel.git
cd Africhome-Vps-Tunnel
sudo bash install.sh
sudo africhome
```

## Xray VLESS REALITY notes

- The module installs Xray using the upstream XTLS Xray-install script and creates a VLESS + REALITY TCP inbound.
- Existing `/usr/local/etc/xray/config.json` files are not overwritten during VLESS setup.
- The module validates the generated configuration with `xray run -test` before restarting the service.
- Open the selected TCP port in the VPS provider firewall.
- Client import URIs are credentials. Do not post them publicly or commit them to Git.

## VMess WebSocket + TLS notes

- VMess adds an inbound to the existing Xray JSON config; it preserves other inbounds and creates a timestamped backup first.
- Supply a domain and matching certificate/key files already installed on the VPS. The module does not issue certificates or configure DNS.
- The module validates the resulting config before restarting Xray and restores the backup if validation or restart fails.
- Open the selected TCP port in the VPS provider firewall. UFW is updated only if already active.
- Client import URIs contain account credentials; keep them private.

## Security and limitations

Review scripts before running them. Keep VPS console access available when changing firewall/network settings. Torrent-port filtering is only a basic port rule and can be bypassed; it is not application-level torrent detection. These modules have not been tested on every VPS provider or network configuration. Do not treat publication or JSON validation as proof of live service operation.

## Unified account, domain, and security roadmap

The planned unified account manager, centralized domain/certificate manager, Fail2ban hardening, and optional BitTorrent firewall policy are specified in [the account/domain/security roadmap](docs/ACCOUNT-DOMAIN-SECURITY-ROADMAP.md). This is a staged implementation plan, not a claim that every listed feature is already available. In particular, torrent port filtering is not comprehensive torrent detection, and each protocol must pass its own account lifecycle tests before it is advertised as supported.

## Licence system

- Installation requires a valid, digitally signed **lifetime licence key** before package installation or persistent system changes.
- Each key is issued offline for one specific VPS fingerprint (the SHA-256 hash of `/etc/machine-id`) and has no expiry date.
- On the target VPS, run `sudo bash scripts/license.sh fingerprint` and send the resulting fingerprint to the licence administrator.
- The administrator issues a key offline with `bash admin/issue-license.sh /secure/path/license-private.pem LICENCE_ID VPS_FINGERPRINT`. Supply the generated one-line key privately to the customer.
- The installer verifies the Ed25519 signature and VPS fingerprint locally, then stores the accepted key at `/etc/africhome/license.token` with root-only access. Later installer runs reuse and recheck the saved key without asking the customer to enter it again.
- No Cloudflare account, web dashboard, hosting, domain, API token, online database, or recurring payment is required for licence verification.
- Keep the Ed25519 private signing key offline and never commit it or install it on customer VPSs. The matching public key is stored at `keys/license-public.pem`.
- VPS binding is a practical clone deterrent, not hardware-backed anti-tamper protection. A root administrator can alter local identifiers or patch local scripts. Offline keys cannot be globally revoked or centrally checked after issuance.
- OpenSSL must already be available for the initial verification; the installer deliberately verifies the key before installing packages.

## Trojan TLS notes

- Trojan adds a tagged inbound to the existing Xray JSON config and preserves other inbounds.
- Supply a domain and matching certificate/key files already installed on the VPS. The module does not issue or renew certificates.
- The module checks for Xray port conflicts, backs up the config, validates it with `xray run -test`, and restores the backup if validation or restart fails.
- Open the selected TCP port in the VPS provider firewall. UFW is updated only if already active.
- The generated client URI contains the account password; keep it private. Removing the inbound leaves its firewall rule unchanged.

## Shadowsocks notes

- Shadowsocks is configured as an Xray inbound using the AEAD cipher `aes-128-gcm`.
- The module generates a random password, checks Xray inbound port conflicts, backs up the config, validates it, and restores the backup if validation or restart fails.
- Both TCP and UDP on the selected port must be allowed by the VPS provider firewall. UFW rules are added only if UFW is already active.
- The generated `ss://` URI contains the password. Keep it private. Removing the inbound leaves firewall rules unchanged.

## Protocol account expiry

- The protocol account manager can add, list, and remove separately identified VLESS, VMess, and Trojan clients on existing Xray inbounds.
- Accounts can be assigned an expiry date or set to never expire. Enable the daily systemd timer from the protocol account menu to remove expired managed clients automatically.
- Expiry is checked daily, so an account can remain usable until the next scheduled run unless an administrator selects the manual cleanup action.
- The manager only tracks accounts it creates. Existing initial accounts and accounts added outside Africhome are not automatically enrolled.
- This module does not currently impose per-user connection/concurrency limits. Those require separate Xray policy/routing design and must not be confused with expiry.
- Client credentials are shown at creation time. Configure client import details to match the selected inbound's transport and security settings.

## Security and installer audit notes

- The installer checks for Ubuntu 22.04+ or Debian 11+ and installs the core command-line dependencies used by the menu and protocol modules.
- The Fail2ban action creates an Africhome SSH jail only when one does not already exist, detects the active SSH daemon port (falling back to 22), validates the Fail2ban configuration, and enables the service.
- UFW is not enabled automatically. If an administrator chooses to enable it, the script allows the detected SSH TCP port before enabling UFW; additional protocol ports must still be opened deliberately.
- The optional nftables BitTorrent filter is a common-port block only. It is not comprehensive detection and is runtime-only unless an administrator configures persistence separately.

## Hysteria 2 notes

- Use menu option 11 to install/update Hysteria 2 and configure the server.
- Each VPS administrator supplies their own domain. Its DNS A/AAAA records must point to the VPS before requesting a certificate. The module obtains a Let's Encrypt certificate using the HTTP-01 standalone challenge, so inbound TCP 80 must be reachable and not occupied during issuance.
- Choose one UDP port (1-65535), or a port-hopping range such as 20000-30000. Hysteria's native Linux port hopping listens on the first port and redirects the rest of the range using nftables or iptables. The service needs NET_ADMIN capability for this feature.
- The module adds the selected UDP port/range to UFW only when UFW is already active. The same UDP port/range must also be allowed in the VPS provider firewall/security group. Avoid ports already used by other services; a range must not overlap other listeners or firewall-managed services.
- A Let's Encrypt deploy hook copies renewed certificates into the Hysteria certificate directory with restricted ownership and permissions, then restarts Hysteria.
- Hysteria client URIs contain credentials. Keep them private. Port-hopping clients must be configured with the same port range and must support Hysteria 2 port hopping.
- This module backs up an existing Hysteria config before replacement. It does not alter Xray, DNSTT, WireGuard, or unrelated service configurations.


## Port and routing discovery

- The Port & Routing Manager currently provides read-only discovery of TCP/UDP listeners, UFW, nftables, iptables, and relevant systemd service states.
- This stage does not install a proxy, change a listener, alter firewall rules, move VLESS REALITY, or restart services.
- Provider/cloud firewalls are not visible from inside the VPS and must be checked in the provider control panel.
- Central TCP 443 routing is a planned feature. REALITY must be passed through unchanged and will remain directly bound to public TCP 443 unless SNI passthrough is proven with the actual Xray client/server combination and an explicit administrator-approved migration.
- Raw SSH, native OpenVPN, and unrelated UDP services are not assumed to be multiplexable on one socket. TLS wrappers, WebSocket bridges, or dedicated ports must be selected and tested per mode.
- See [the port-routing architecture](docs/PORT-ROUTING-ARCHITECTURE.md) for constraints, phases, and acceptance criteria.

## Excluded protocols

WireGuard, Iodine/SlowDNS, and ZIVPN are not part of the Africhome protocol menu. DNSTT remains the DNS tunnel service. Existing installations of excluded software are not automatically removed.
