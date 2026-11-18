# DNSTT bootstrap and safe migration

## User-owned domain and nameserver

Every operator must configure their **own** DNS names. The project does not
ship Africhome's personal domain, nameserver hostname, DNS password, or tunnel
credentials as defaults. During setup, ask the operator for:

- Their delegated DNSTT tunnel domain (the DNS zone/name used by DNSTT).
- Their authoritative nameserver hostname (the NS target hostname they own
  or control and will point at their VPS).

Configure and save these values locally with:

```bash
sudo bash scripts/configure-dnstt-domain.sh
```

The script validates both values as DNS hostnames and stores them in
`/etc/africhome-dnstt/server.env` with mode 0600. It backs up an existing
configuration before replacing it. It does not make DNS changes automatically.
The operator must create the required A record, NS delegation, and registrar
glue when their DNS provider requires it. The nameserver hostname's A record
must point to that operator's VPS public IP. DNS setup varies by registrar.

Do not use a hard-coded project maintainer domain in scripts, examples that
look copyable, service units, client profiles, or generated instructions.
Always read the operator's saved configuration. Never overwrite an existing
domain silently; show the current value and request confirmation/edit input.

## Design decision

Africhome's DNSTT path is a direct DNSTT server, not dnsdist multiplexing.
Do not install dnsdist for this design. Users may use any domain and
nameserver hostname they control, subject to valid DNS delegation and
provider support. The operator can keep an existing domain; no new or shorter
domain is forced.

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

The script installs build prerequisites, uses Go 1.21+ or installs a
checksum-verified Go toolchain, builds DNSTT server/client binaries, and
creates a protected keypair only if one does not already exist. It preserves
an existing complete keypair and refuses to overwrite an incomplete pair.

The bootstrap deliberately does not stop iodine, bind UDP 53, change DNS
records, change firewall rules, or create/start a DNSTT service. The private
key stays on the VPS and is never committed or distributed; clients receive
only the public key.

## Prepare the DNSTT service

After the binaries, keypair, and operator-owned DNS values are configured,
prepare the systemd unit:

```bash
sudo bash scripts/install-dnstt-service.sh
```

The script asks for the UDP listen address (default `:53`) and SSH upstream
(default `127.0.0.1:22`). It stores service settings in
`/etc/africhome-dnstt/service.env` with mode 0600 and installs
`africhome-dnstt.service`. It does not enable or start the service. If UDP
port 53 is occupied by iodine, the script reports the conflict and leaves
iodine untouched. Do not start DNSTT until the planned migration has stopped
the old listener and verified the rollback procedure.

Inspect the generated unit before activation:

```bash
sudo systemctl cat africhome-dnstt
```

The systemd unit reads the operator's saved tunnel domain and upstream; it
does not contain the maintainer's domain or nameserver.

## Verified development test

The development VPS used its own configured domain and nameserver, with:
- DNSTT server: `127.0.0.1:5300/UDP`
- DNSTT upstream: `127.0.0.1:22`
- DNSTT client local listener: `127.0.0.1:7000/TCP`
- A connection to the local listener returned an OpenSSH server banner.

This confirms local stream forwarding only. It does **not** prove external
DNS delegation, external UDP/53 reachability, mobile-client settings, or
end-to-end public service operation.

## Domain length and MTU

DNSTT client payload MTU depends on the tunnel domain length. The development
test reported server MTU 932 and client MTU 126 with its existing domain.
Do not claim that raising server `-mtu` fixes a client-side domain-derived
limit. Keep the user's domain when requested and measure real throughput;
never silently substitute another domain.

## Required migration safeguards

1. Back up the current iodine unit and root-only environment file.
2. Preserve existing DNS names, iodine password, tunnel interface, SSH
   accounts, and expiry records.
3. Validate DNSTT config and service unit before any public port change.
4. Obtain explicit operator approval before stopping iodine and binding DNSTT
   to public UDP 53.
5. Keep a tested rollback path that restores and re-enables iodine.
6. Verify DNS delegation and UDP/53 from an external network, then connect
   using an external DNSTT client and complete an SSH login.
7. Do not claim HTTP Injector compatibility until its exact DNSTT mode and
   resolver, domain, public key, and local forwarding settings are tested.

## Status

Local DNSTT build and SSH-banner forwarding are verified on Ubuntu 22.04.5
x86_64. External DNS-path and mobile-client testing remain outstanding.
