# Africhome VPS Tunnel

A terminal-only VPS installation and management toolkit for Ubuntu 22.04+ and Debian 11+. No web panel.

## Implemented modules

- SSH Linux account creation, listing, locking/unlocking, and expiry management
- Loopback-only SSH-over-TLS backend using stunnel, with certificate/SNI validation and no public listener changes
- Fail2ban installation and status
- UFW status and guarded enablement
- Basic nftables filtering for common BitTorrent ports (not comprehensive torrent detection)
- Xray installation and VLESS + REALITY TCP server setup, service controls, and client import URI
- VMess over WebSocket + TLS inbound management, client import URI, status, and removal
- Trojan over TLS inbound management, generated password, client URI, status, and removal
- Shadowsocks AEAD inbound management using Xray, client URI, status, and removal
- Hysteria 2 server management pinned to official `v2.14.0` installer/binary artifacts with architecture-specific SHA-256 verification, user-defined domain, UDP port or port-hopping range, Let's Encrypt TLS, and client URI
- Managed VLESS, VMess, and Trojan accounts with manual and daily automatic expiry
- Read-only TCP/UDP listener, firewall, and relevant service inventory for future port-routing planning
- Read-only Xray inbound inventory showing tags, protocol, bind address, port, network, and security mode without printing client credentials or private-key paths
- DNSTT server/client bootstrap, protected keypair preservation, operator-owned domain and nameserver configuration, and a prepared systemd service that is not started automatically
- DNSTT customer SSH accounts with expiry, timed trials, renew/disable/reset/delete controls, recursive resolver guidance (UDP/DoT/DoH), and a password-free TXT + public-key configuration export
- Read-only DNSTT deployment inventory showing common file presence, service units, and UDP listeners without exposing keys
- Native OpenVPN UDP/TCP server management, Easy-RSA certificate authority, client profile generation, certificate listing/revocation, service status, plus a separate read-only deployment inventory

## Central routing status

- Central TCP 443 SNI, TCP 80 HTTP Host/path, and combined HAProxy renderers are available.
- VMess + VLESS REALITY shared TCP 443 has a review-only candidate generator and an explicit transactional apply command. It changes Xray/HAProxy only after root/licence checks and typed APPLY confirmation; it does not change DNS or firewall rules.
- Shared TCP 443 client interoperability remains unverified on a disposable VPS. Other shared-port modes remain planned until their handlers and client interoperability are implemented and tested.
- VLESS REALITY is passed through by SNI and must not be treated as ordinary TLS termination.
- SSH account management creates Linux users; the separate stunnel backend provides an SSH-over-TLS loopback service, but public SNI routing and payload/proxy gateway modes are still pending.
- Native OpenVPN direct UDP/TCP server and certificate-based client management are implemented. OpenVPN WebSocket, payload-proxy, TLS/SNI wrapper modes, automatic firewall/NAT setup, and shared-port router integration are not implemented. The module deliberately does not change UFW/nftables or enable IP forwarding.
- See [the central routing architecture contract](docs/CENTRAL-ROUTING-ARCHITECTURE.md) for required backend, safety, and compatibility rules.

## Planned / not yet implemented

- Per-client connection/concurrency limits (not implemented)

See [deployment readiness](docs/DEPLOYMENT-READINESS.md) for the current implementation boundary and remaining work before production use.

## Requirements

- Ubuntu 22.04 or newer, or Debian 11 or newer
- Root access
- Public IP or DNS endpoint and provider firewall access for tunnel ports
- For VLESS REALITY: chosen TCP port (default 443)
- For VMess and Trojan: a DNS name pointing to the VPS and an existing valid TLS certificate/private key
- For Shadowsocks: a reachable public IP or DNS name; TCP and UDP on the selected port

## Installation

**Release candidate — not ready for VPS deployment.**

The public default `main` branch is not yet the consolidated release candidate. Development work is under draft PRs #4, #5 and #7. Do not run `install.sh` or deploy this branch until those changes are reviewed, consolidated into `main`, and all release gates are passed.

For source review only:

```bash
git clone --branch fix/dnstt-transactional-install https://github.com/Africhome65/Africhome-Vps-Tunnel.git
cd Africhome-Vps-Tunnel
```

The deployment command will be restored here when the public `main` branch is ready.

## DNSTT setup and customer accounts

- Menu options 26-28 build the official DNSTT binaries, preserve or create the protected server keypair, save the operator's own tunnel domain and authoritative nameserver, and prepare the systemd unit.
- Menu option 28 deliberately does not enable or start the service, stop another DNS tunnel, edit registrar records, or change firewall rules. Public UDP activation is a separate migration that requires checking current listeners and provider firewall settings.
- The DNSTT UDP listener accepts a selected port from 1 through 65535. The default is UDP 53; the chosen port must be free and reachable through the provider firewall.
- The bootstrap fetches the signed upstream DNSTT release tag `v1.20260501.0` and verifies its pinned tag-object and commit hashes before building; existing source checkouts at a different commit are not silently changed.
- Menu option 29 manages separate non-root SSH customer accounts, validity, timed trial accounts, and client configuration export. DNSTT transports TCP over DNS; SSH authenticates each customer.
- Client configuration exports contain the DNSTT public key and resolver command, but never the SSH password or server private key. The password for a generated account is shown once; custom passwords are entered with hidden input and confirmation.
- Client resolver guidance supports UDP, DNS-over-TLS, and DNS-over-HTTPS. The recursive resolver is not the authoritative nameserver used for DNS delegation.
- Android client compatibility and external UDP reachability still require testing with the exact client app and network.

## Xray VLESS REALITY notes

- The module installs Xray using the upstream XTLS Xray-install script and creates a VLESS + REALITY TCP inbound.
- Existing `/usr/local/etc/xray/config.json` files are not overwritten during VLESS setup.
- The module validates the generated configuration with `xray run -test` before restarting the service.
- Open the selected TCP port in the VPS provider firewall.
- Client import URIs are credentials. Do not post them publicly or commit them to Git.

## VMess WebSocket + TLS notes

- VMess adds an inbound to the existing Xray JSON config; it preserves other inbounds and creates a timestamped backup first. Direct mode defaults to TCP 8443. Menu option 5 can render a review-only shared TCP 443 candidate: it moves the VLESS REALITY and VMess Xray inbounds to distinct loopback ports and generates HAProxy TLS SNI passthrough routes. This does not apply the candidate or change live services; external VLESS REALITY and VMess client interoperability on the shared listener remains unverified.
- Supply a domain and matching certificate/key files already installed on the VPS. The module does not issue certificates or configure DNS.
- The module validates the resulting config before restarting Xray and restores the backup if validation or restart fails.
- Open the selected TCP port in the VPS provider firewall. UFW is updated only if already active.
- Client import URIs contain account credentials; keep them private.

## Shared TCP 443 candidate

- The VMess menu's shared-443 candidate generator reads the existing Xray config and requires exactly one VLESS REALITY inbound with valid `serverNames`.
- It generates a new Xray candidate with VLESS REALITY on loopback TCP 1443 and VMess WebSocket + TLS on loopback TCP 8443, plus a TLS SNI passthrough HAProxy candidate on public TCP 443.
- The VMess SNI domain must be covered by the supplied certificate and must differ from all VLESS REALITY `serverNames`. The generator checks certificate hostname coverage and certificate/private-key matching, safely supports normal Let's Encrypt live symlinks, and the menu checks that the Xray service account can read both files.
- Candidate files are written under a root-only directory and include a TLS route manifest, VMess client details, and a protected VMess state file. After apply, the existing VMess status/client-detail functions use the saved UUID/domain/port/path; generic VMess removal is blocked while shared mode is active to protect VLESS REALITY.
- The apply command prints the protected backup directory. To deactivate shared mode, restore the saved Xray/HAProxy configs and prior VMess state from that backup; do not use the ordinary VMess remove option.
- VMess menu option 6 can apply a reviewed candidate after the operator types `APPLY`. It backs up the active Xray and complete HAProxy configs, validates both candidates, moves Xray to loopback first, confirms TCP 443 is free, then starts HAProxy and confirms HAProxy owns TCP 443. It attempts to restore both configs and prior service states if any step fails.
- Applying the candidate replaces the complete `/etc/haproxy/haproxy.cfg`; review and back up any non-Africhome HAProxy configuration first. The apply script does not change DNS, UFW or provider firewall rules. Keep the backup directory it prints.
- Review the generated Xray and HAProxy candidates before deployment. HAProxy must be able to inspect the ClientHello SNI for the selected VLESS REALITY clients; confirm this with real clients before production use.

## Security and limitations

- Hysteria config files are root-owned and group-readable only by the `hysteria` service account (mode 0640); private keys are restricted to that account. Setup and certificate renewal include rollback safeguards, but forced-failure and disposable-VPS testing remain release gates.
- The public default `main` branch is not yet the consolidated release candidate. Until the development PRs are reviewed and merged, use the explicit development branch shown above for testing only.

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

- Use menu option 9 to install/update Hysteria 2 and configure the server.
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
