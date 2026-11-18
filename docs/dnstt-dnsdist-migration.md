# DNSTT alongside the existing iodine SlowDNS service

## Current deployment constraint

The Africhome VPS currently has one public IPv4 address. The existing
`africhome-slowdns.service` (iodine) owns public UDP port 53. DNSTT also
needs to receive DNS traffic, so starting both daemons directly on
`0.0.0.0:53` will cause a bind conflict.

Do not stop or replace the existing iodine service as part of DNSTT setup.

## Preferred design

Use dnsdist as the single public DNS front end and route each delegated
tunnel zone to its own loopback-only backend:

- dnsdist: public UDP/TCP port 53
- iodine: `127.0.0.1:5301`
- DNSTT: `127.0.0.1:5302`

dnsdist routes queries by DNS suffix to dedicated server pools. The iodine
domain already configured on the VPS must be read from
`/etc/africhome-slowdns.env`; it must not be hard-coded in the installer.
The DNSTT domain must be a separate, short delegated subdomain.

## Safe migration requirements

1. Back up the current iodine systemd unit and environment before changing
   anything.
2. Validate dnsdist is installed and its configuration passes its native
   config check before stopping or restarting iodine.
3. Create the DNSTT keypair with restrictive permissions. The private key
   must remain on the VPS and must never be printed, committed, or logged.
4. Configure iodine to listen only on loopback port 5301 and DNSTT only on
   loopback port 5302.
5. Configure dnsdist to listen on public port 53 and route only the matching
   delegated DNS suffix to each backend.
6. Preserve the existing iodine tunnel domain, shared password, tunnel
   interface, and customer accounts.
7. Apply firewall changes only after configuration validation. Permit DNS
   UDP 53; TCP 53 may be enabled for DNS fallback if required.
8. If any validation or service health check fails, restore the original
   iodine unit and dnsdist configuration and leave the existing tunnel
   service running.
9. Never claim end-to-end DNSTT operation until an external DNSTT client
   successfully opens the tunnel and reaches the intended SSH endpoint.

## Client configuration note

HTTP Injector's DNSTT fields must be populated from the actual DNSTT
deployment and verified app mode. The DNS resolver, delegated DNS host,
server public key, and local SSH forwarding endpoint are distinct values.
Do not reuse iodine's shared tunnel password as a DNSTT public key.

## Status

This document records the intended safe architecture. It does not claim
that DNSTT, dnsdist multiplexing, or an HTTP Injector client connection
has been installed or tested on a live VPS.
