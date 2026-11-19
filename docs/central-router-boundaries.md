# Central TCP router: current safe implementation boundary

The central router is being built in stages. The current HAProxy renderer is a
**configuration generator only**. It accepts an explicit JSON route manifest
and writes a candidate TCP/SNI passthrough configuration to standard output.

## Supported by the renderer

- One TCP listener on port 443.
- TLS ClientHello SNI matching.
- Distinct, case-insensitive unique DNS names per listener.
- Loopback-only backends (127.0.0.1 or ::1).
- Rejecting unmatched connections rather than sending them to an arbitrary service.

Example manifest:

~~~json
{
  "routes": [
    {
      "name": "xray_reality",
      "sni": "reality.example.com",
      "backend_host": "127.0.0.1",
      "backend_port": 1443
    }
  ]
}
~~~

Render without applying:

~~~bash
python3 scripts/render-central-router.py routes.json
~~~

## HTTP Host/path renderer for port 80

A separate generator, `scripts/render-http-router.py`, creates a candidate
HAProxy HTTP frontend for TCP port 80. It supports unique Host/path-prefix
matchers, loopback-only HTTP backends, WebSocket-compatible HTTP proxying, and
a 421 rejection for unmatched requests. It sorts more-specific path prefixes
before broader routes.

Example invocation:

~~~bash
python3 scripts/render-http-router.py http-routes.json
~~~

This is ordinary HTTP Host/path routing. It is not an SSH payload gateway and
does not automatically translate arbitrary SSH payloads into HTTP proxy
requests. Each WebSocket service still needs a compatible server-side inbound
and client profile.

## Important limitations

- It does not install HAProxy, write /etc/haproxy, bind port 443, edit firewall
  rules, reload services, or change any existing Xray listener.
- It does not terminate TLS. It forwards the original TLS stream unchanged.
- It does not install or apply either generated frontend automatically.
- It does not implement SSH payload/proxy gateways or OpenVPN WebSocket/TLS wrappers.
- A route is only usable after its backend has been configured to listen on the
  specified loopback address and port and client interoperability has been tested.
- Existing VLESS REALITY must remain available until a separately reviewed
  migration plan proves the new frontend/backend arrangement works.

Never apply a generated configuration to a live VPS without a separate backup,
validation, rollback, port-ownership and maintenance-window procedure.


## Native OpenVPN management

The menu includes a separate native OpenVPN management module for package
installation, a local Easy-RSA certificate authority, UDP/TCP server setup,
client profile generation, certificate revocation, and service status.

This native module does **not** claim OpenVPN WebSocket, payload-proxy, or SNI
support. Those require separately tested wrappers and compatible clients.
It does not edit UFW/nftables or enable IP forwarding/NAT. Open the selected
transport/port in the provider firewall and complete a separately reviewed
routing/firewall setup before offering full-tunnel internet service.

The CA private key stays in the root-only Easy-RSA PKI directory. Runtime
server certificates, keys, CRL and tls-crypt material are copied to a
service-readable directory with restricted permissions. Exported client
profiles are root-only and contain private keys.


## Combined TCP 80/443 candidate configuration

`scripts/render-central-haproxy.py` accepts a single JSON manifest containing
both `tls_routes` and `http_routes`, then renders one HAProxy configuration
with a single global/defaults section and separate port 443 TLS passthrough and
port 80 HTTP Host/path frontends.

Example:

~~~json
{
  "tls_routes": [
    {"name":"reality","sni":"reality.example.com","backend_host":"127.0.0.1","backend_port":1443}
  ],
  "http_routes": [
    {"name":"websocket","host":"ws.example.com","path_prefix":"/tunnel","backend_host":"127.0.0.1","backend_port":10080}
  ]
}
~~~

Generate and inspect a candidate without applying it:

~~~bash
python3 scripts/render-central-haproxy.py routes.json
~~~

This is still a configuration generator. It does not claim that the listed
backends exist, that a particular client protocol is compatible, or that a
live listener can safely be migrated. Do not apply it to the live VPS until
backend modules, port ownership, service rollback, and client interoperability
have all been verified.


The terminal menu also provides a **Generate central HAProxy candidate** action.
It reads a user-supplied regular JSON manifest, validates and renders it, and
stores a root-only candidate at `/root/africhome-haproxy-candidate.cfg`.
When HAProxy is installed, its parser checks the candidate. This action never
writes `/etc/haproxy`, binds ports, changes firewall rules, or reloads services.


## SSH over TLS backend

The menu can configure a stunnel service that accepts TLS only on a loopback
backend port and forwards decrypted traffic to the local SSH daemon on
127.0.0.1:22. It validates the supplied SNI hostname, certificate validity,
certificate/key match, root-only private-key permissions, and loopback port
availability. Regular certificate files are accepted; standard Let's Encrypt
live symlinks are accepted only when they resolve inside
`/etc/letsencrypt/archive`. The existing deploy hook restarts this backend
when its matching live certificate renews.

This backend does not bind public TCP 443 or change the central HAProxy
configuration. A matching SNI route must be added to a reviewed candidate
manifest, then validated and activated only after the REALITY-preservation
migration plan is proven. The client must use an SSH-over-TLS wrapper compatible
with stunnel; raw SSH clients cannot connect directly to the TLS backend.

This is not an HTTP payload gateway or authenticated HTTP CONNECT proxy.


A compatible client-side stunnel profile can expose a local SSH endpoint. For
example, after the public SNI route is active:

~~~ini
client = yes
foreground = yes
[africhome-ssh-client]
accept = 127.0.0.1:2222
connect = ssh.example.com:443
sni = ssh.example.com
verifyChain = yes
CAfile = /etc/ssl/certs/ca-certificates.crt
checkHost = ssh.example.com
~~~

The SSH application then connects to 127.0.0.1:2222. This is an example
configuration, not a generated mobile-client profile; verify that the target
client supports stunnel and the selected TLS settings.


## Guarded HAProxy apply transaction (new, not yet approved for this VPS)

`scripts/apply-central-haproxy.sh --apply` is a separate explicit activation
step. It requires a root-owned mode-0600 candidate generated by the combined
renderer, an inactive HAProxy service, and both public TCP ports 80 and 443 to
be free. It also requires the operator to type `APPLY` at the confirmation
prompt. It validates the candidate with the HAProxy binary, backs up an
existing root-owned config, installs the new config by same-directory atomic
rename, starts HAProxy, verifies the service and both listeners, and enables
startup only after those checks pass. If startup or verification fails, it
attempts to stop HAProxy and restores the prior config (or removes the new
config if none existed). If the stop command fails and HAProxy is still active,
it deliberately does not replace the configuration underneath the running
process; it leaves the original backup in place and reports a critical manual
recovery condition. This failure path is covered by a mocked regression test.

The apply transaction does not change firewall rules, Xray, or other services.
It is deliberately designed to refuse an already-active HAProxy service or
any existing listener on TCP 80/443. It has not been used on the live VPS.

**Important for the current VPS:** VLESS REALITY already owns TCP 443. This
apply script must refuse to run there until a separately tested migration
moves REALITY to a compatible loopback backend and verifies client
interoperability. The generic TLS SNI passthrough renderer does not by itself
prove REALITY compatibility. The apply script's tests use mocked services;
they are not a production migration or end-to-end protocol test.
