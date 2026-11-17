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

## Planned / not yet implemented

- VMess
- Trojan
- Shadowsocks
- Expanded protocol user and expiry management

## Requirements

- Ubuntu 22.04 or newer, or Debian 11 or newer
- Root access
- Public IP or DNS endpoint and provider firewall access for tunnel ports
- For WireGuard: UDP 51820 (or chosen port)
- For SlowDNS: delegated DNS subdomain and UDP 53
- For VLESS REALITY: chosen TCP port (default 443)

## Installation

Review the scripts before running:

```bash
git clone https://github.com/Africhome65/Africhome-Vps-Tunnel.git
cd Africhome-Vps-Tunnel
sudo bash install.sh
sudo africhome
```

## SlowDNS SSH notes

- SlowDNS uses iodine DNS tunnelling; it is not a V2Ray transport.
- Delegate a subdomain to a nameserver on this VPS and configure registrar glue records where required.
- UDP port 53 must be available. Do not stop an existing DNS service blindly.
- After the DNS tunnel is established, SSH is reached at `10.77.0.1`.
- DNS tunnels are slow and can be blocked or rate-limited. Use strong credentials and SSH keys.

## WireGuard notes

- Server config: `/etc/wireguard/wg0.conf`.
- Client profiles: `/root/africhome-wireguard-clients/`; they contain private keys and must be transferred securely.
- Setup enables IPv4 forwarding and configures NAT/forwarding through WireGuard hooks.
- Open the selected UDP port in both UFW (if active) and the VPS provider firewall.
- Client profiles route IPv4 traffic through the VPN; IPv6 is not configured by this module.

## Xray VLESS REALITY notes

- The module installs Xray using the upstream XTLS Xray-install script and creates a VLESS + REALITY TCP inbound.
- Existing `/usr/local/etc/xray/config.json` files are not overwritten.
- The module validates the generated configuration with `xray run -test` before restarting the service.
- Open the selected TCP port in the VPS provider firewall. UFW is updated only if it is already active.
- Client import URIs are credentials. Do not post them publicly or commit them to Git.
- REALITY configuration and client compatibility depend on the installed Xray version; verify from an external network before production use.

## Security and limitations

Review scripts before running them. Keep VPS console access available when changing firewall/network settings. Torrent-port filtering is only a basic port rule and can be bypassed; it is not application-level torrent detection. These modules have not been tested on every VPS provider or network configuration. Do not treat publication or shell syntax checks as proof of live service operation.

## License

License to be determined.
