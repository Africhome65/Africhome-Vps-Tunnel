# Africhome VPS Tunnel

A terminal-only VPS installation and management toolkit for Ubuntu 22.04+ and Debian 11+. No web panel.

## Implemented modules

- SSH Linux account creation, listing, locking/unlocking, and expiry management
- Fail2ban installation and status
- UFW status and guarded enablement
- Basic nftables filtering for common BitTorrent ports (not comprehensive torrent detection)
- WireGuard installation, server setup, client profile creation, peer listing, and client removal
- SlowDNS SSH using iodine, with systemd service management and client instructions
- Xray installation and VLESS + REALITY TCP server setup, service controls, and client import URI
- VMess over WebSocket + TLS inbound management, client import URI, status, and removal\n- Trojan over TLS inbound management, generated password, client URI, status, and removal\n- Shadowsocks AEAD inbound management using Xray, client URI, status, and removal\n- Managed VLESS, VMess, and Trojan accounts with manual and daily automatic expiry

## Planned / not yet implemented

- Per-client connection/concurrency limits (not implemented)

## Requirements

- Ubuntu 22.04 or newer, or Debian 11 or newer
- Root access
- Public IP or DNS endpoint and provider firewall access for tunnel ports
- For WireGuard: UDP 51820 (or chosen port)
- For SlowDNS: delegated DNS subdomain and UDP 53
- For VLESS REALITY: chosen TCP port (default 443)
- For VMess and Trojan: a DNS name pointing to the VPS and an existing valid TLS certificate/private key\n- For Shadowsocks: a reachable public IP or DNS name; TCP and UDP on the selected port

## Installation

Review scripts before running:

```bash
git clone https://github.com/Africhome65/Africhome-Vps-Tunnel.git
cd Africhome-Vps-Tunnel
sudo bash install.sh
sudo africhome
```

## SlowDNS SSH notes

- SlowDNS uses iodine DNS tunnelling; it is not a V2Ray transport.
- The menu accepts a tunnel domain and nameserver hostname, then displays the required A, registrar glue, NS-delegation, and UDP 53 firewall records. These records must be created at the domain registrar/DNS provider; the script cannot register glue records automatically.
- The server uses iodine's default 1130-byte tunnel MTU explicitly. Client instructions retain lazy mode (`-L 1`) and the maximum upstream hostname length (`-M 255`); fragment sizing remains automatically negotiated rather than forcing a potentially incompatible value.
- Create Trial (default one day) and Normal (administrator-selected days) SSH accounts. Each account gets a separate generated SSH password and Linux account-expiry date. Linux enforces expiry; admins can list, renew, lock, unlock, or delete managed accounts.
- The iodine tunnel password is shared by all tunnel clients; it is not a per-customer credential. Customer-specific access control and expiry are enforced by their separate SSH accounts.
- After the DNS tunnel is established, SSH is reached at `10.77.0.1`.
- DNS tunnels have inherently limited throughput and can be blocked or rate-limited. Lazy mode and fragment negotiation help, but actual speed depends on the DNS resolver/relay, network path, and client. Use strong credentials and SSH keys where practical.

## WireGuard notes

- Server config: `/etc/wireguard/wg0.conf`.
- Client profiles: `/root/africhome-wireguard-clients/`; they contain private keys and must be transferred securely.
- Setup enables IPv4 forwarding and configures NAT/forwarding through WireGuard hooks.
- Open the selected UDP port in both UFW (if active) and the VPS provider firewall.
- Client profiles route IPv4 traffic through the VPN; IPv6 is not configured by this module.

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
