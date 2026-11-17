# Africhome VPS Tunnel

A terminal-based VPS installation and management toolkit for Ubuntu 22.04+ and Debian 11+.

## Implemented

- Terminal-only management menu (no web panel)
- SSH Linux account creation, listing, locking/unlocking, and expiry management
- Fail2ban installation and status
- UFW status and guarded enablement
- Basic nftables filtering for common BitTorrent ports (not comprehensive torrent detection)
- WireGuard installation, server setup, client profile creation, peer listing, and client removal
- SlowDNS SSH server using iodine, with systemd service management and client instructions

## Planned / not yet implemented

- Xray/V2Ray: VMess and VLESS
- Trojan and Shadowsocks
- Expanded protocol user, expiry, and service management

## Requirements

- Ubuntu 22.04 or newer, or Debian 11 or newer
- Root access
- Public IPv4 address for WireGuard server setup
- UDP port 51820 (or chosen port) allowed by the VPS provider firewall

## Installation

Run the installer from the repository after reviewing its contents:

```bash
git clone https://github.com/Africhome65/Africhome-Vps-Tunnel.git
cd Africhome-Vps-Tunnel
sudo bash install.sh
```

Then launch:

```bash
sudo africhome
```

## SlowDNS SSH notes

- SlowDNS uses iodine DNS tunnelling; it is not a V2Ray transport.
- You must delegate a subdomain to a nameserver on this VPS and configure registrar glue records where required.
- The service listens on UDP 53. If another DNS daemon already uses that port, do not stop it blindly; resolve the conflict first.
- Clients need an iodine client and connect to SSH at `10.77.0.1` after the DNS tunnel is established.
- DNS tunnels are slow and can be blocked or rate-limited by networks. Use strong tunnel credentials and SSH keys.

## WireGuard notes

- Server configuration is written to `/etc/wireguard/wg0.conf`.
- Client profiles are stored under `/root/africhome-wireguard-clients/` with restrictive permissions. Transfer them securely; they contain private keys.
- Setup enables IPv4 forwarding and installs NAT/forwarding rules through WireGuard's PostUp/PostDown hooks.
- If UFW is active, the selected WireGuard UDP port is allowed. You must also allow it in your VPS provider/cloud firewall.
- The generated client profile routes IPv4 traffic through the VPN. IPv6 is not configured by this module.
- Keep VPS console access available when changing firewall/network settings.

## Security and limitations

Review scripts before running them. Never commit client or server private keys. Torrent-port filtering is only a basic port rule and can be bypassed; it is not reliable application-level torrent detection. This project has not yet been tested on every VPS provider or network configuration.

## License

License to be determined.
