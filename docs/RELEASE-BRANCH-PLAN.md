# Release branch and pull-request plan

This document records the current GitHub integration topology. It is not approval to merge or deploy.

## Active stacked integration chain

The current release candidate is `fix/dnstt-transactional-install`. Its intended merge order is:

1. **PR #4** `feature/central-port-routing-architecture` → `main`
   - Establishes the central-routing base, installer/licence safeguards, inventory, OpenVPN foundation, SSH TLS backend, and related regression tests.
2. **PR #5** `feature/central-dnstt-integration` → `feature/central-port-routing-architecture`
   - Adds DNSTT management and its account/domain/service integration on top of the routing base.
3. **PR #7** `fix/dnstt-transactional-install` → `feature/central-dnstt-integration`
   - Adds transactional DNSTT/Hysteria hardening, shared VMess/REALITY TCP 443 candidate/apply logic, OpenVPN PKI hardening, and current installer branch selection.

The GitHub compare API confirmed each stacked edge is strictly ahead with no commits behind at the time of this review:
- PR #4 base branch to PR #5 head: 77 commits ahead, 0 behind.
- PR #5 base branch to PR #7 head: 139 commits ahead, 0 behind.

Keep these pull requests in draft until the remaining protocol and disposable-server tests are complete. Do not merge them automatically or change their base branches as a shortcut.

## Older overlapping pull requests

The following open draft PRs are separate historical lines and must not be merged independently into `main` without a fresh diff review:

- **PR #1** `feature/dnstt-dnsdist` — older DNSTT implementation line.
- **PR #2** `feature/dnstt-custom-password` — adds custom-password handling on top of PR #1.
- **PR #3** `feature/hysteria-custom-domain-udp` — earlier standalone Hysteria implementation.

The current release-candidate tree already contains DNSTT custom-password prompts and the Hysteria module, but the older PRs are divergent from the active routing chain. Treat them as feature references, not as safe merge candidates. Confirm any feature unique to those branches against the current tree and add a regression test before closing or superseding them.

## Current repository snapshot

- Default branch: `main`.
- Active release-candidate branch: `fix/dnstt-transactional-install`.
- Active PR chain: #4 → #5 → #7.
- All six historical PRs remain open and draft at the time this document was prepared; PRs #1–#3 are not part of the active stack.
- The latest complete GitHub Actions run before this document was added passed on commit `c7837974b0fc6543da69d8d95507545ef387ff8a` (run `44896061187`).

## Release gate before merging

1. Finish and regression-test the explicitly requested transport modes; do not label catalogue-only modes as implemented.
2. Complete clean Ubuntu install/upgrade/rollback tests on a disposable VPS.
3. Test generated profiles with actual Android clients, including reconnect, invalid credentials, expiry/revocation, and certificate renewal.
4. Verify shared TCP 443 with both VLESS REALITY and VMess clients while preserving the existing live VPS services.
5. Review every PR diff, then merge the stack in order only after explicit release approval.
6. Tag a release only after the final merged commit has a green full CI run and a documented rollback plan.

## Safety

- No merge is authorized by this document.
- No live VPS changes are authorized by this document.
- Do not deploy from `main` until the reviewed release chain has been merged and validated.
