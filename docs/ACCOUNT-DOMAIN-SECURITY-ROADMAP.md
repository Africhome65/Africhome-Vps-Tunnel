# Account, Domain, and Security Management Roadmap

Status: implementation specification; not yet implemented as a unified feature set.

## Current implementation status (development branch)

The central metadata registry foundation is now implemented in `modules/account_registry.sh`. It stores a stable account ID, label, expiry timestamp, and service-side references/status only; it deliberately does not store passwords, private keys, or client URIs. SSH Linux account creation now registers metadata after the OS account and password are successfully created; SSH expiry changes synchronize the registry. SSH password entry is hidden and confirmed. Xray VLESS, VMess, and Trojan account creation now registers a service record after the native Xray config has been validated and restarted. Xray renew, revoke, and expiry operations also synchronize the corresponding registry status/expiry.

This is an initial adapter integration, not yet a complete cross-service account manager. Hysteria, OpenVPN, Shadowsocks, and DNSTT still require their own verified account adapters before they can be shown as centrally managed. The registry menu currently reports records registered by integrated adapters.

## Product goal

Build Africhome as one terminal-based VPS administration system. An administrator should be able to manage accounts, domains, certificates, security policy, and service health from one menu, while each protocol is configured through a protocol-specific adapter.

This document extends the central port-routing architecture. It does not authorize a live VPS migration or modify existing service configuration.

## 1. Unified account manager

### Supported account lifecycle

The central account manager should support:

- Create an account for one service or a selected set of compatible services.
- Set a duration in days, an explicit expiry date/time, or never-expire.
- List active, suspended, expired, and pending accounts.
- Renew, suspend, reactivate, and revoke accounts.
- Display or export client connection details at creation time and on an explicit administrator request.
- Run scheduled expiry enforcement and provide a manual dry-run cleanup.
- Record who performed each administrative action and when.

### Service adapters

The account registry is the source of account metadata, not a replacement for each protocol's native account store. Each adapter must implement create, verify, disable/revoke, renew where supported, and status operations.

Initial adapter targets:

| Service | Account representation | Expiry enforcement |
|---|---|---|
| SSH | Dedicated Linux account, not shared system login | Lock account and terminate sessions when configured; delete only on explicit policy |
| VLESS / VMess / Trojan | Xray client entry with stable managed account ID | Remove/disable managed client and validate Xray config before reload |
| Shadowsocks | Dedicated inbound/client identity where supported by chosen Xray configuration | Revoke only the selected managed identity |
| Hysteria 2 | Native authenticated user/credential mapping supported by installed version | Revoke the selected credential; verify server-side auth behavior |
| OpenVPN | Per-user certificate and certificate revocation list | Revoke certificate and update CRL; never share a common client certificate |
| DNSTT | Only if the installed DNSTT implementation supports distinct per-user credentials | Do not claim per-user expiry until the exact auth model is verified |

Do not advertise a service as account-managed until its adapter has a working integration test. Do not add WireGuard, Iodine/SlowDNS, or ZIVPN. DNSTT remains the only DNS tunnel.

### Account data and safety

- Use a root-owned state directory such as /var/lib/africhome/accounts with restrictive permissions.
- Assign an immutable internal account ID; do not use usernames alone as cross-service identity.
- Store only the metadata and secrets required for recovery. Prefer hashes for passwords where the service supports hash-based authentication.
- Never log passwords, private keys, full client URIs, or certificate private material.
- Write state atomically, validate service configuration before applying changes, and retain timestamped backups.
- Make account creation idempotent and prevent duplicate service identities.
- Protect against deleting unmanaged accounts or unrelated Xray inbounds.
- Make bulk creation transactional where possible: if one selected service fails, clearly report partial success and provide safe rollback/reconciliation.

### Expiry scheduler

- Use a systemd service and timer, not a long-running shell loop.
- Run as root only where required; use least privilege for read-only/reporting tasks.
- Enforce expiry using UTC timestamps and clearly display local time to the administrator.
- Provide dry-run, status, last-run, and manual-run actions.
- Handle clock changes, reboot, missing services, invalid state, and transient failures safely.
- Notify the administrator of failures without exposing credentials.
- Do not silently delete Linux home directories or user data on expiry.

## 2. Central domain and certificate manager

### Domain inventory

Allow an administrator to add a domain once and assign it to supported services. Store:

- Domain and optional subdomain.
- DNS A/AAAA resolution results and expected VPS addresses.
- Intended service, transport, SNI/Host role, and backend.
- Certificate issuer, paths, SAN names, expiry, and renewal method.
- Last verification result and timestamp.

### Operations

- Add, validate, list, assign, unassign, and remove domain records.
- Check DNS before certificate issuance.
- Issue certificates through a supported ACME method.
- Renew certificates centrally and deploy copies through service-specific hooks.
- Verify private-key permissions and certificate/key public-key match.
- Check SAN/hostname coverage and expiry before applying.
- Keep backups and roll back failed certificate deployment.
- Preserve HTTP-01 challenge routing if port 80 is managed by a frontend; support DNS-01 where credentials and provider integration are deliberately configured.

A single certificate may cover multiple hostnames through SANs or a wildcard, but wildcard issuance generally requires DNS-01. Never assume that one certificate or one hostname fits every service. Do not share private-key files with unrelated service accounts; use restricted per-service copies or narrowly scoped group permissions.

## 3. Torrent and abuse controls

Provide a clearly labelled optional BitTorrent policy:

- Block common BitTorrent TCP/UDP ports using managed nftables sets/chains.
- Allow the administrator to inspect the proposed rules before applying.
- Preserve existing firewall rules and never flush the firewall.
- Track only Africhome-owned rules and remove only those rules on uninstall.
- Support enable, disable, status, dry-run, and rollback.
- Explain that port-based filtering is incomplete and cannot reliably identify all encrypted or non-standard BitTorrent traffic.
- Do not claim deep-packet inspection or comprehensive torrent prevention.

Add optional connection/rate limits for supported services, with safe defaults and per-service configuration. Avoid broad limits that can lock out legitimate clients.

## 4. Fail2ban and host hardening

### Fail2ban

- Detect the active SSH daemon port and actual log backend.
- Validate jail configuration before enabling or reloading.
- Preserve existing administrator jails and local overrides.
- Add SSH protection first; add service-specific jails only when reliable log formats and filters are tested.
- Provide status, banned IP list, unban, test-filter, and log inspection.
- Use conservative ban thresholds and document recovery/unban procedures.
- Never enable a jail whose filter has not been validated against representative logs.

### Additional host security

- Root-only ownership and restrictive permissions for secrets and managed state.
- Validate all user input; quote shell variables; avoid eval and unsafe command construction.
- Download installers over HTTPS, verify upstream signatures/checksums where available, and pin or validate versions.
- Avoid piping unaudited remote scripts directly into a root shell.
- Use least-privilege service users, systemd hardening options where compatible, and explicit capabilities.
- Optional SSH key-only mode, root-login restriction, and SSH port changes must include preflight checks and a rollback path to avoid lockout.
- Optional unattended security updates with controlled reboot policy.
- Audit administrative actions, configuration changes, failed operations, and expiry events.
- Back up before every mutation and validate rollback procedures.
- Provide a security audit command that reports findings without automatically changing settings.
- Avoid claiming any VPS script is impossible to hack; document residual risks and keep dependencies updated.

## 5. Unified menu experience

Proposed top-level menu groups:

1. Dashboard and system health
2. Account manager
3. Domain and certificate manager
4. Protocol services
5. Port and routing manager
6. Firewall and torrent policy
7. Fail2ban and host security
8. Backups, audit, and restore
9. Logs and diagnostics
0. Exit

The account manager should allow a single workflow: select username/label, choose one or more supported services, choose duration in days or never-expire, review the plan, confirm, then show generated connection details once.

## 6. Recommended additions

- Per-service online/offline health checks and listener ownership.
- Account labels, notes, and optional quota/connection policy where the protocol supports it.
- Export/import of account metadata with secrets excluded by default.
- Encrypted backup option for secrets and certificates.
- Restore wizard with preflight validation.
- Admin confirmation for destructive actions and bulk operations.
- Read-only audit mode and dry-run mode for all firewall, routing, and account changes.
- Structured machine-readable status output for future integrations, without introducing a public web panel.

## 7. Implementation phases and acceptance criteria

### Phase A — Audit existing modules

Inventory existing SSH, Xray account, Hysteria, DNSTT, security, installer, and expiry implementations. Identify what is genuinely implemented, what is partial, and what is missing. Preserve existing user work and avoid changing live services.

### Phase B — Account registry and adapters

Implement registry schema, safe state storage, SSH and Xray adapters, tests, expiry scheduler, and reconciliation. Add other service adapters only after verifying their native account APIs.

### Phase C — Domain and certificate manager

Implement domain inventory, DNS validation, ACME integration, service-specific certificate deployment, renewal tests, and rollback.

### Phase D — Security controls

Harden Fail2ban, implement managed torrent firewall rules, security audit, rate limiting where supported, and backup/restore tests.

### Phase E — Integrated installer and menu

Integrate modules with dependency checks, dry-run, confirmation prompts, upgrade compatibility, and clean uninstall of Africhome-owned resources only.

### Phase F — Test and staged VPS rollout

Run CI and disposable integration tests first. On the VPS, start with read-only audit and backup verification. Test new features on isolated ports/accounts. Do not migrate VLESS REALITY, modify DNSTT, alter existing Hysteria firewall ranges, or replace working services without explicit approval and a rollback plan.

### Release gates

- Every advertised account-managed service passes create/list/renew/expire/revoke tests.
- Expiry survives reboot and is timezone-safe.
- Domain assignment validates DNS and certificate SANs.
- Certificate renewal does not expose private keys or interrupt unrelated services.
- Firewall changes are scoped, reversible, and never flush existing rules.
- Fail2ban filters are tested against actual logs.
- Torrent feature clearly states its port-filtering limitations.
- Installer is idempotent and does not reset or overwrite unmanaged configuration.
- Backup restore and rollback are tested.
- No live VPS service is changed by CI.
