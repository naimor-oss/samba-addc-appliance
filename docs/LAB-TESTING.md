# Lab Testing Guide

This guide describes the tests that matter for the Samba AD DC appliance and
how to add them to the lab scenario runner.

The goal is not only "does Samba start?" The goal is to prove that a prepared
Debian appliance can interoperate with a hardened Windows Server 2025 forest in
the places administrators actually depend on: DNS, Kerberos, LDAP, SMB,
replication, SYSVOL, certificates, and recovery from common deployment mistakes.

## Test Runner Model

`lab/run-scenario.sh` runs from the Mac. It is a thin wrapper that invokes the
generic `../lab-kit/bin/run-scenario.sh` with `LAB_ENV=lab/samba.env`. A
scenario is a shell file in `lab/scenarios/` that defines:

| Function | Required | Purpose |
| --- | --- | --- |
| `run_scenario` | yes | Performs the action under test, usually over SSH into `samba-dc1`. |
| `verify` | yes | Asserts the desired final state and returns non-zero on failure. |
| `pre_hook` | no | Optional setup after VM revert and push, e.g. WS2025-side AD cleanup. |
| `post_hook` | no | Optional evidence collection or cleanup after verification. |

The generic pipeline (from `lab-kit`) is:

1. Stage helper scripts listed in `LAB_STAGE_SOURCES` to `LAB_STAGE_DIR`
   (`/Volumes/ISO/lab-scripts`). For Samba this pulls from this repo plus
   `../lab-kit/hypervisors/hyperv/` and `../lab-router/hypervisors/hyperv/`.
2. Revert `samba-dc1` to `golden-image` via `Revert-TestVM.ps1`.
3. Push `prepare-image.sh` and `samba-sconfig.sh` to the VM.
4. Run `LAB_POST_PUSH_CMD` (installs `samba-sconfig` under `/usr/local/sbin`).
5. `pre_hook` (scenario-owned — this is where AD cleanup now lives, e.g. in
   `join-dc.sh`; the smoke scenario does not need cleanup).
6. `run_scenario` and `verify`.
7. `post_hook`.
8. Transcript is written to `test-results/<scenario>-<timestamp>.log`.

## Existing Scenario

### `join-dc`

Purpose: prove a prepared Samba appliance can join a hardened WS2025 forest as
an additional writable DC.

What it covers today:

- `samba-sconfig join-dc` headless CLI.
- Forest functional-level probing.
- Domain join using existing admin credentials.
- Samba service startup.
- Windows-side DNS/PTR behavior.
- Forced KCC after PTR creation.
- Initial SYSVOL seed from `//WS2025-DC1/sysvol`.
- Samba-side DRS health.
- Windows-side replication verification.
- TLS certificate SAN presence.

Run:

```bash
lab/run-scenario.sh join-dc
```

Iterate only on verification:

```bash
lab/run-scenario.sh join-dc --verify-only
```

### `dfs-namespace`

Purpose: prove the Samba DC can serve as a tertiary domain-based DFS-N
namespace target — read AD-replicated link metadata, validate it against
adversarial input, materialize MSDFS symlinks, and refuse to prune in
unsafe states. Background and design in [`DFS-N.md`](DFS-N.md).

What it covers:

- `samba-sconfig dfs-init` writes a `conf.d` drop-in (read-only namespace
  share, msdfs root) and the global sentinel.
- `samba-sconfig dfs-configure` records namespaces and the prefer-regex.
- `samba-sconfig dfs-update` parses `msDFS-TargetListv2` blobs via the
  `samba-dfs-parse-targets` Python helper, validates each
  `msDFS-LinkPathv2` and target UNC, applies prefer-list ordering, and
  atomically writes msdfs symlinks under the namespace root.
- Adversarial inputs covered by the namespace setup: spaces+parens
  (`Quarterly Reports (FY26)`), dollar (`IT$Tools`), single-word
  (`one`). A deliberately malformed `..\..\evil` link is also
  attempted via raw LDAP; AD's schema rejects the minimum-attribute
  object before our validator runs, so the on-disk check passes
  trivially. The path-validator and UNC-validator surfaces are
  exercised end-to-end against 22 adversarial inputs by a local
  unit harness during dev — see `docs/DFS-N.md` §11.
- Convergence: after the initial sync, the scenario adds a new
  folder on WS2025-DC1 and removes an existing one, then re-runs
  `dfs-update`. The new symlink must appear, the removed one must
  prune, and the rest must stay intact. This is the timer's reason
  for existing — without it the static state can't tell "wrote the
  right thing once" from "actually adapts to changes."
- Sentinel guard: removing `.dfsn-managed` makes the next update
  return rc=2 without filesystem changes.
- Empty-result guard: pointing at a non-existent namespace must not
  prune existing links.
- Schedule path installs and starts the systemd timer.

Run:

```bash
lab/run-scenario.sh dfs-namespace
```

Lab-side prerequisites:

- `Setup-DfsnTestNamespace.ps1` — creates the namespace and the four
  test folders.
- `Modify-DfsnTestNamespace.ps1` — drives the convergence step
  (add `NewFolder`, remove `one`).
- `Reset-DfsnTestNamespace.ps1` — idempotent teardown for re-runs.

All three are staged automatically by the runner. The scenario does
**not** register the Samba DC as a namespace root target — that
requires the appliance to already be joined and serving the share,
and `New-DfsnRootTarget` validates target reachability. Tertiary-
priority registration is a deployment-time concern, not part of the
test surface.

## Important Tests To Add

The following tests are the highest-value next additions. They are written in
the order they should be implemented.

### 1. Smoke Test: `smoke-prepared-image`

Purpose: verify the golden image is still a clean appliance base before any
domain operation.

Assertions:

- `samba-sconfig` is installed and executable.
- `samba-ad-dc` is disabled/inactive.
- `smbd`, `nmbd`, and `winbind` are masked or inactive as intended.
- `/etc/samba/smb.conf` does not exist.
- `pwsh`, `nft`, `ldapsearch`, `smbclient`, `samba-tool`, and `chronyd` exist.
- chrony has no hard-coded internet pools before deployment.
- `/etc/krb5.conf` is the skeleton.
- DNS and internet connectivity work through `router1`.
- first-boot marker behavior is predictable.

Why it matters: failed joins are much easier to debug when the base image is
known-good and deliberately unprovisioned.

Status: implemented in `lab/scenarios/smoke-prepared-image.sh`.

### 2. New Forest Provision: `provision-new-forest`

Purpose: verify Samba can be the first DC in a new forest, not only a joined DC.

Assertions:

- `samba-tool domain provision` succeeds through the appliance flow.
- `samba-ad-dc` starts and stays active.
- DNS SRV records exist locally.
- Kerberos TGT acquisition works.
- SYSVOL and NETLOGON shares are available.
- chrony is configured as the domain time source.
- hardening block is inserted into `[global]`, not a share section.
- TLS certificate has DNS and IP SAN entries.
- firewall can be enabled without blocking AD ports.

Needed script support: add a headless `samba-sconfig provision` command or keep
this as a TUI/manual test until that exists.

### 3. RODC Join: `join-rodc`

Purpose: verify the RODC path stays healthy as code changes.

Assertions:

- `SC_ROLE=RODC samba-sconfig join-dc` or a dedicated CLI path completes.
- The DC object is read-only in AD.
- Password replication policy is sane.
- DRS status is healthy for the partitions an RODC should hold.
- SYSVOL seed still succeeds.
- write attempts that should fail do fail clearly.

Why it matters: RODC joins are similar enough to writable joins to accidentally
reuse broken assumptions, but different enough to deserve their own regression.

### 4. Hardening Compatibility: `hardening-ws2025`

Purpose: prove the appliance remains compatible with WS2025 security posture.

Assertions:

- LDAP simple bind without TLS/signing fails when expected.
- SASL/GSSAPI signed LDAP bind succeeds.
- Kerberos uses strong encryption.
- SMB signing is mandatory.
- SMB1/SMB2 negotiation is refused according to configured min protocol.
- LDAPS serves the appliance certificate with SANs.
- `testparm -s` reports no global-parameter-in-share-section warnings.

Why it matters: hardening regressions often look like client compatibility
issues unless tested explicitly.

### 5. SYSVOL Sync: `sysvol-sync-smb`

Purpose: prove the out-of-band SYSVOL workaround remains operational.

Assertions:

- `samba-sconfig` can write SMB sync config without exposing credentials in
  world-readable files.
- `sysvol-sync` pulls from `//WS2025-DC1/sysvol`.
- Deleted and changed files converge locally.
- `samba-tool ntacl sysvolreset` completes.
- Logs are written to `/var/log/samba/sysvol-sync.log`.
- The scheduled cron entry or future systemd timer exists and runs.

Why it matters: Samba has no DFSR, so this is not optional operational glue.

### 6. DNS Reverse Zone Edge Cases: `join-no-reverse-zone`

Purpose: verify the join path gives useful output when a reverse zone is absent.

Assertions:

- Join succeeds even when PTR registration cannot.
- Output clearly states the reverse zone is missing.
- Verification detects Windows-side replication risk.
- The failure mode is documented in the test log.

Why it matters: many real AD environments do not have every reverse zone
created ahead of time.

### 7. Second Samba DC: `join-samba-to-samba`

Purpose: verify Samba-to-Samba behavior and SSH-based SYSVOL sync.

Assertions:

- `samba-dc2` joins using `samba-dc1` as source.
- DRS is healthy both ways.
- SSH transport for `sysvol-sync` works.
- push and pull modes do not race or delete unexpectedly.

Why it matters: Windows interop and Samba-only topologies exercise different
paths.

### 8. Upgrade Safety: `manual-upgrade-policy`

Purpose: ensure update policy does not accidentally upgrade Samba unattended.

Assertions:

- security-only and full-auto policies blacklist Samba/Kerberos/Winbind
  packages.
- manual policy does not install packages automatically.
- `get_update_policy` reports the state accurately.

Why it matters: unattended Samba upgrades on a DC can be a production outage.

## Scenario Template

Use this as a starting point for new files under `lab/scenarios/`.

```bash
# lab/scenarios/example.sh

run_scenario() {
    ssh_vm 'sudo samba-sconfig --help'
}

verify() {
    local rc=0

    say "samba-sconfig exists"
    ssh_vm 'test -x /usr/local/sbin/samba-sconfig' || rc=1

    say "example assertion"
    ssh_vm 'true' || rc=1

    return "$rc"
}
```

Prefer assertions that check final state instead of relying only on command
exit codes. Keep evidence in the log: print the relevant `systemctl`, `dig`,
`samba-tool`, `repadmin`, or `openssl` output before deciding pass/fail.

## Verification Commands Worth Reusing

From Samba:

```bash
sudo systemctl is-active samba-ad-dc
sudo samba-tool drs showrepl
sudo samba-tool domain level show
sudo samba-tool fsmo show
sudo net ads info -P
sudo testparm -s
dig @localhost _ldap._tcp.lab.test SRV +short
openssl x509 -noout -ext subjectAltName -in /var/lib/samba/private/tls/cert.pem
```

From WS2025:

```powershell
repadmin /replsummary
repadmin /showrepl /errorsonly
Get-ADDomainController -Filter *
Resolve-DnsName 10.10.10.20
Resolve-DnsName samba-dc1.lab.test
Get-DnsServerResourceRecord -ZoneName '10.10.10.in-addr.arpa'
```

## Adding Headless Commands

When a scenario needs to drive TUI-only behavior, add a focused headless
subcommand to `samba-sconfig.sh` instead of scripting whiptail. The current
pattern is:

- Validate required environment variables with `: "${VAR:?message}"`.
- Reuse the same helper functions as the TUI.
- Print progress lines prefixed with `[sconfig]`.
- Return non-zero only for failures the test should treat as scenario failure.

Good candidates:

- `samba-sconfig provision`
- `samba-sconfig harden`
- `samba-sconfig enable-firewall`
- `samba-sconfig sysvol-sync configure-smb`
- `samba-sconfig sanity`

## Test Data Hygiene

- Treat logs in `test-results/` as evidence. Keep representative passing logs,
  but avoid committing every ad-hoc run.
- Never rely on stale AD objects. Use `Reset-LabDomainState.ps1` before join
  scenarios unless deliberately testing dirty-state recovery.
- Keep passwords lab-only. The default `P@ssword123456!` appears throughout
  this repo because the lab is disposable and isolated.
- Do not tear down `router1` or `WS2025-DC1` casually. They are persistent
  fixtures.
