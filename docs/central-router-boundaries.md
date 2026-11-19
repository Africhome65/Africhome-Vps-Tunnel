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
