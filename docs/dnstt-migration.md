# DNSTT bootstrap and safe migration

## Design decision

Africhome's DNSTT path is a direct DNSTT server, not dnsdist multiplexing.
Do not install dnsdist for this design. The operator wants to retain the
existing DNS domain; setup must prompt for and preserve the operator's actual
delegated tunnel domain rather than forcing a new or shorter domain.

DNSTT and iodine cannot both bind the same public UDP port 53 on the same
address. Keep the existing iodine service running while building and testing
DNSTT on a temporary local UDP port. Do not switch public port 53 until the
operator explicitly approves the maintenance window and the external client
test has passed.

## Automated bootstrap

Run as root:

```bash
sudo bash scripts/install-dnstt.sh
```

The script:

1. Installs build prerequisites.
2. Uses an installed Go version 1.21 or newer, or installs Go 1.27.4 for
   x86_64 after verifying the pinned SHA-256 checksum.
3. Clones the official DNSTT source if it is not already checked out.
4. Builds `dnstt-server` and `dnstt-client` into `/usr/local/bin`.
5. Creates a DNSTT keypair in `/etc/africhome-dnstt` only when neither key
   exists. It preserves an existing complete keypair and refuses to
   overwrite an incomplete pair.
6. Sets the private key to mode 0600 and the public key to mode 0644.

The script deliberately does not stop iodine, bind UDP 53, change DNS records,
change firewall rules, or create/start a DNSTT service. It is safe to run
before the migration decision.

The private key must never be copied into Git, printed in logs, or shared with
clients. Only the public key is distributed to clients.

## Verified development test

The following test topology was used during development:

- DNSTT server: `127.0.0.1:5300/UDP`
- DNSTT upstream: `127.0.0.1:22` (the local SSH daemon)
- DNSTT client local listener: `127.0.0.1:7000/TCP`
- The existing configured tunnel domain was supplied unchanged to both ends.
- A TCP connection to `127.0.0.1:7000` returned an OpenSSH server banner.

This confirms local DNSTT stream forwarding to SSH. It does **not** prove that
public DNS delegation, external UDP/53 reachability, mobile-client settings,
or end-to-end service operation work.

## Domain length and MTU

The DNSTT client calculates its payload MTU from the tunnel domain length.
A long existing domain can therefore leave less payload capacity. In the
development test, the server reported effective MTU 932 while the client
reported effective MTU 126. Do not try to fix this merely by increasing the
server's `-mtu`: the client's domain-derived capacity is a separate limit.

Keep the existing domain if that is the operator's requirement, document the
resulting capacity, and measure real transfer performance. Do not silently
replace it with a shorter domain or claim a speed improvement without a
measured test.

## Required migration safeguards

1. Read and back up the current iodine unit and root-only environment file.
2. Preserve the existing tunnel domain, nameserver host, iodine password,
   tunnel interface, SSH accounts, and expiry records.
3. Confirm the DNSTT keypair exists and has restrictive permissions.
4. Validate the proposed DNSTT systemd unit before enabling it.
5. Ensure the current iodine service is stopped only after the operator
   explicitly approves the switch; then bind DNSTT to public UDP 53.
6. Keep a tested rollback path that restores the original iodine unit and
   environment and re-enables iodine if DNSTT fails.
7. Verify UDP/53 from an external network, then connect with an external
   DNSTT client and complete an SSH login or equivalent end-to-end test.
8. Do not claim HTTP Injector compatibility until the exact app/client mode
   and its DNSTT resolver, domain, public key, and local forwarding fields
   have been tested.

## Status

The build and local SSH-banner forwarding steps have been completed on one
Ubuntu 22.04.5 x86_64 VPS. External DNS-path and mobile-client testing are
still outstanding. This documentation describes the validated scope and
must not be read as a claim that public DNSTT service is already deployed.
