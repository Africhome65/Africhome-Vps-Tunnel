# DNSTT migration note (supersedes the earlier dnsdist proposal)

The earlier proposal to use dnsdist to multiplex iodine and DNSTT is no
longer selected. Africhome uses a direct DNSTT server. Each installer must
prompt users for their own delegated tunnel domain and authoritative
nameserver hostname; no maintainer domain or nameserver may be hard-coded.

See [DNSTT bootstrap and safe migration](dnstt-migration.md) for the user-owned
DNS configuration flow, bootstrap, local SSH-forwarding test, domain-length
MTU limitation, and safe migration requirements.

Do not stop iodine or take over public UDP 53 until an external DNSTT client
has been tested and the operator explicitly approves the switch.
