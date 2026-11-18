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


## Individual customer accounts

DNSTT is a TCP-over-DNS transport, not a username/password account server.
For individual credentials, keep the DNSTT server upstream pointed at the
local SSH daemon (normally `127.0.0.1:22`) and authenticate each customer
with a separate non-root Linux SSH account.

The Africhome menu option **14) DNSTT customer accounts / custom DNS resolver**
loads `modules/dnstt_users.sh`. It creates accounts in the
`africhome-dnstt` group, generates a unique SSH password, and applies a Linux
account expiry using `chage`. Passwords are displayed once and are not written
to a plaintext credential database. Administrators can list, renew, disable,
re-enable, reset, and delete managed accounts.

The public DNSTT server key is not a customer password. Clients need the
server's public key to authenticate the DNSTT server, then use their own SSH
username/password to log in through the tunnel. Never give customers the VPS
root password or private server key.

Password authentication still depends on the existing sshd policy. The account
module does not globally enable password authentication or change firewall,
DNS, DNSTT service, or SSH daemon configuration automatically. If the server
uses key-only SSH authentication, a password-only client will not log in until
an administrator deliberately configures a suitable SSH policy.

## Custom recursive DNS resolver on the client

The DNSTT client chooses a recursive resolver for its encoded DNS queries.
The account menu generates client command guidance for:

- UDP DNS, such as `8.8.8.8:53`, `1.1.1.1:53`, or a custom
  `resolver.example.net:53` using `-udp`.
- DNS-over-TLS resolver addresses using `-dot`.
- DNS-over-HTTPS URLs using `-doh`.

This resolver is distinct from the authoritative nameserver hostname in the
operator's DNS delegation. Keep the existing delegated tunnel domain and
authoritative nameserver unchanged unless the operator explicitly requests a
DNS migration.

These options change the resolver used by a compatible DNSTT client; they do
not convert DNSTT into a general UDP tunnel. DNSTT's upstream remains a TCP
endpoint, normally the local SSH service. Do not configure the server upstream
as `8.8.8.8:53` when SSH customer accounts are required: a DNSTT server
instance forwards its TCP stream to its configured upstream, so that would
replace SSH rather than provide SSH and DNS simultaneously.

Validate the generated command with the exact client build and test from an
external network. Android apps may expose different resolver and key fields;
do not assume every app supports the same flags or credential layout.
