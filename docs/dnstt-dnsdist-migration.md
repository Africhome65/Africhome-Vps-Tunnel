# DNSTT migration note (supersedes the earlier dnsdist proposal)

The earlier proposal to use dnsdist to multiplex iodine and DNSTT is no
longer the selected design. Africhome's current DNSTT plan is DNSTT only,
with the operator's existing tunnel domain retained. No dnsdist service or
new/shorter domain is required by this design.

See [DNSTT bootstrap and safe migration](dnstt-migration.md) for the current
automated build/key setup, verified local SSH-forwarding test, domain-length
MTU limitation, and safe migration requirements.

Do not stop iodine or take over public UDP port 53 until an external DNSTT
client has been tested and the operator explicitly approves the switch.
