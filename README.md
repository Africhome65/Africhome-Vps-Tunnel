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
- DNSTT DNS tunnel server installation, persistent server keys, systemd service management, and SSH TCP 22 upstream
- Managed VLESS, VMess, and Trojan accounts with manual and daily automatic expiry

## Planned / not yet implemented

- Per-client connection/concurrency limits (not implemented)

## Requirements

- Ubuntu 22.04 or newer, or Debian 11 or newer
- Root access
- Public IP or DNS endpoint and provider firewall access for tunnel ports
- For DNSTT: delegated DNS subdomain, nameserver hostname, and inbound UDP 53
- For VLESS REALITY: chosen TCP port (default 2053)
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

## DNSTT DNS tunnel

- The server listens on public UDP 53 and forwards tunnelled TCP streams to `127.0.0.1:22`. UDP 53 is the DNS listener; TCP 22 is the SSH upstream.
- The module builds the official DNSTT server from the upstream Go module at a pinned version, verifies the downloaded Go toolchain archive against the SHA-256 published by go.dev, creates a persistent keypair, and installs a hardened systemd service running as an unprivileged account with only the capability needed to bind UDP 53.
- Configure DNS delegation at your provider: create an A record for a nameserver host (for example `ns1.example.com`) pointing to the VPS IPv4 address, then an NS record delegating the tunnel zone (for example `t.example.com`) to that nameserver. The nameserver host must be outside the delegated tunnel zone. Add glue when your registrar/provider requires it. Do not proxy these DNS records through a CDN.
- Before starting, the module checks that the delegated zone resolves to the configured nameserver and that the nameserver has an A record (when DNS lookups are available). Ensure UDP 53 is free before starting the service. If UFW is already active, the module adds UDP 53; it does not enable UFW. Also open UDP 53 in the VPS provider firewall.
- The server public key is displayed by the management menu and stored at `/etc/africhome/dnstt/server.pub`; the private key remains on the server at `/etc/africhome/dnstt/server.key` with restricted permissions. Never copy the private key to a client.
- The menu's **Generate client resolver command** supports custom recursive resolvers using UDP DNS (`-udp 8.8.8.8:53`), DNS over TLS (`-dot 8.8.8.8:853`), or DNS over HTTPS (`-doh https://dns.google/dns-query`). You can enter a network/provider-specific resolver address or URL. UDP port 53 is plaintext; DoT/DoH are encrypted between the client and recursive resolver. The selected recursive resolver must permit the tunnel's DNS queries and reach the delegated zone.
- Example UDP client command: `dnstt-client -udp 8.8.8.8:53 -pubkey-file server.pub t.example.com 127.0.0.1:7000`. Replace the resolver, public-key file, tunnel zone, and local port as appropriate. For encrypted DNS, prefer `-dot resolver.example:853` or `-doh https://resolver.example/dns-query`. Then connect SSH to `127.0.0.1:7000`.
- The recursive resolver is configured on each **client device**, not as a DNS service on the VPS. The VPS DNSTT server remains the authoritative endpoint for the delegated tunnel zone.
- A successful service start and syntax/CI checks do not prove DNS delegation or end-to-end tunnel connectivity. Validate from an external network before relying on the tunnel.

## Xray VLESS REALITY notes

- The module installs Xray using the upstream XTLS Xray-install script and creates a VLESS + REALITY TCP inbound (default port 2053, leaving TCP 443 available for VMess WebSocket + TLS).
- Existing `/usr/local/etc/xray/config.json` files are not overwritten during VLESS setup.
- The module validates the generated configuration with `xray run -test` before restarting the service.
- Open the selected TCP port in the VPS provider firewall.
- Client import URIs are credentials. Do not post them publicly or commit them to Git.

## VMess WebSocket + TLS notes

- VMess adds an inbound to the existing Xray JSON config; it preserves other inbounds and creates a timestamped backup first.
- Supply a domain and matching certificate/key files already installed on the VPS. The module does not issue certificates or configure DNS.
- The module validates the resulting config before restarting Xray and restores the backup if validation or restart fails.
- The default listener is TCP 443. Open the selected TCP port in the VPS provider firewall. UFW is updated only if already active.
- Client import URIs contain account credentials; keep them private.

## Security and limitations

Review scripts before running them. SSH account passwords are displayed as you type them in the terminal for easier copying; avoid screen sharing or terminal recording while entering credentials. Keep VPS console access available when changing firewall/network settings. Torrent-port filtering is only a basic port rule and can be bypassed; it is not application-level torrent detection. These modules have not been tested on every VPS provider or network configuration. Do not treat publication or JSON validation as proof of live service operation.

## License

License to be determined.

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
