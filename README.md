# Samba AD DC Appliance

This repository builds and tests a small **Samba Active Directory Domain
Controller appliance** on Debian 13. The appliance is meant to feel like
a headless server product: deploy a prepared image, finish initial
configuration at the console, run a local `sconfig`-style tool to
provision or join a domain.

## Where do I start?

| If you want to … | Read |
| --- | --- |
| **Deploy** the appliance from a release artifact (`.ova` / `.qcow2` / `.vhdx`) on your hypervisor | [`docs/RELEASE.md`](docs/RELEASE.md) — import recipes per hypervisor, first-boot wizard, day-one configuration |
| **Build your own master** image, run the test lab, or contribute changes | [`docs/SETUP.md`](docs/SETUP.md) — Mac tools, Hyper-V host, external artifacts, sibling-repo checkout, and the "First-Time Lab Setup" walkthrough below |
| Understand the **test methodology** | [`docs/LAB-TESTING.md`](docs/LAB-TESTING.md) — scenario runner, existing scenarios, planned coverage |
| Understand the **sibling-repo split** | [`../dev-commons/REPO-SPLIT.md`](../dev-commons/REPO-SPLIT.md) — boundaries among all six repositories |
| Look up **shared coding/docs/test conventions** | [`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) |

The appliance is exercised against a Windows Server 2025 forest with
Microsoft security baseline GPOs applied. The lab is built from six
sibling repositories living next to each other on disk:

- [`dev-commons`](../dev-commons/) — cross-cutting docs, templates, tooling
- [`lab-kit`](../lab-kit/) — reusable appliance lab orchestration
- [`lab-router`](../lab-router/) — simple reusable lab router VM
- [`appliance-core`](../appliance-core/) — shared runtime libraries vendored during image preparation
- `samba-addc-appliance` — this Samba appliance and its scenarios
- [`smb-proxy-appliance`](../smb-proxy-appliance/) — SMB1↔SMB3 proxy appliance (joins this lab as a member server)

The lab exists because most of the important behavior is interoperability
behavior: Kerberos, LDAP signing, Samba replication, Windows KCC
expectations, DNS, and SYSVOL handling.

## Repository Map

| Path | Purpose |
| --- | --- |
| `prepare-image.sh` | One-time Debian image preparation. Installs Samba AD DC dependencies, PowerShell, chrony, nftables, and appliance helper scripts. |
| `samba-sconfig.sh` | Main appliance configuration tool. Provides the whiptail TUI and a small headless CLI for automated tests. |
| `lab/` | Samba test harness: runner, env, scenarios, and Hyper-V helpers under `lab/hyperv/`. Generic pieces (revert, router) live in the sibling repos. |
| `lab/hyperv/` | Hyper-V/WS2025-specific PowerShell + unattend XML: WS2025 DC build, baseline apply, Samba test VM creation, AD cleanup, verification. |
| `lab/run-scenario.sh` | Mac-side test runner that reverts the Samba VM, cleans the Windows lab state, pushes current scripts, runs a scenario, and verifies results. Stages PS scripts from this repo plus `../lab-kit/hypervisors/hyperv/` and `../lab-router/hypervisors/hyperv/`. |
| `lab/scenarios/` | Scenario definitions. `join-dc.sh` is the current end-to-end additional-DC test; `dfs-namespace.sh` exercises DFS-N tertiary-target behavior end-to-end with adversarial folder names. |
| `test-results/` | Distilled historical notes, topology, and regression reports. Raw `*.log` transcripts are local-only. |
| `docs/SETUP.md` | From-scratch development + test environment setup. Read this first. |
| `docs/LAB-TESTING.md` | Scenario runner model, existing + planned scenarios, useful assertions. |
| `docs/RELEASE.md` | Per-hypervisor import recipes, first-boot wizard, day-one configuration. |
| `AGENTS.md` | Samba-appliance-specific agent brief. |
| `CLAUDE.md` | Claude Code compatibility pointer back to `AGENTS.md`. |
| `HANDOFF.md` | Retired placeholder; points at the maintained docs above. |

Cross-cutting docs (sibling-layout reference, coding conventions,
multi-agent process, project narrative) live in
[`../dev-commons/`](../dev-commons/) and are linked from
[`AGENTS.md`](AGENTS.md).

## Intended Workflow

1. Build the persistent lab infrastructure once:
   - `router1`, a Debian NAT/DHCP/DNS-forwarder VM.
   - `WS2025-DC1`, the first Windows Server 2025 DC for `lab.test`.
   - Microsoft baseline GPOs linked into the lab domain.

2. Create a Debian test VM, install Debian manually, then run
   `prepare-image.sh` once.

3. Checkpoint the prepared Debian VM as `golden-image`.

4. Iterate on `samba-sconfig.sh` and the lab tests by running scenarios from
   the Mac:

   ```bash
   lab/run-scenario.sh join-dc
   ```

5. Promote fixes into the appliance scripts only after the scenario verifies
   them end to end.

## Lab Topology

The v2 lab uses a realistic DHCP/NAT layout. The Samba VM starts life like a
normal appliance would: attached to a LAN, receiving DHCP, with internet access
through a gateway.

| Role | VM | IP | Notes |
| --- | --- | --- | --- |
| Gateway / DHCP / DNS forwarder | `router1` | `10.10.10.1` | Debian cloud image, NAT through the external Hyper-V switch. |
| First Windows DC | `WS2025-DC1` | `10.10.10.10` | Owns `lab.test`, reverse zone, baseline GPOs. |
| Samba DC under test | `samba-dc1` | `10.10.10.20` | Debian 13 appliance candidate. |
| Optional second Samba DC | `samba-dc2` | `10.10.10.21` | Useful for Samba-to-Samba SYSVOL and replication tests. |

DHCP reservations live in the sibling `lab-router` repo at
[`configs/samba-addc.yaml`](../lab-router/configs/samba-addc.yaml) (or
the equivalent dnsmasq snippet at `configs/samba-addc.dnsmasq.conf`).
Hyper-V VM MAC addresses in the PowerShell scripts are pinned to match
those reservations.

## First-Time Lab Setup

Environment prerequisites (Mac tools, Hyper-V host, external ISOs, SSH to
the host, sibling-repo checkout) are covered in
[`docs/SETUP.md`](docs/SETUP.md). The steps below assume that guide has
been followed and all verification commands pass. Everything here runs
from the Mac unless noted.

### 1. Stage router artifacts

Router staging now lives in the sibling `lab-router` repo. Prefer the YAML
config (requires `yq`; `brew install yq`):

```bash
../lab-router/scripts/stage-router-artifacts.sh \
    --config ../lab-router/configs/samba-addc.yaml
```

The pre-YAML invocation using the raw dnsmasq snippet still works if you
don't want to install `yq`:

```bash
../lab-router/scripts/stage-router-artifacts.sh \
    --extra-dnsmasq ../lab-router/configs/samba-addc.dnsmasq.conf
```

This creates or refreshes:

- `/Volumes/ISO/debian-13-router-base.vhdx`
- `/Volumes/ISO/router1-seed.iso`

The VHDX is reused; the seed ISO is cheap to regenerate whenever the router
cloud-init templates or dnsmasq reservations change.

### 2. Stage host-side lab scripts

The host needs PowerShell scripts from all three sibling repos staged into one
place:

```bash
mkdir -p /Volumes/ISO/lab-scripts
cp lab/hyperv/*.ps1 lab/hyperv/*.xml /Volumes/ISO/lab-scripts/
cp ../lab-kit/hypervisors/hyperv/*.ps1 /Volumes/ISO/lab-scripts/
cp ../lab-router/hypervisors/hyperv/*.ps1 /Volumes/ISO/lab-scripts/
```

Repeat this after editing any PowerShell or unattend files. `lab/run-scenario.sh`
also re-stages from all three sources automatically on every run.

### 3. Build the router

Run on the Hyper-V host through SSH:

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-LabRouter.ps1'
```

Verify from the Mac:

```bash
ssh -J nmadmin@server hm@10.10.10.1 'cat /var/log/router-ready.marker; sudo nft list table ip nat'
```

### 4. Build the WS2025 domain controller

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-WS2025Lab.ps1'
```

Wait until promotion and phase 2 complete. You can poll the completion
marker from the host:

```bash
ssh nmadmin@server 'pwsh -Command "Invoke-Command -VMName WS2025-DC1 -Credential (Get-Credential LAB\\Administrator) -ScriptBlock { Test-Path C:\\Setup\\setup-complete.marker }"'
```

`FirstLogon-PromoteToDC.ps1` registers a RunOnce that completes phase 2
automatically after the post-promotion reboot; no manual intervention is
needed beyond waiting.

Then apply the Microsoft baseline:

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Apply-SecurityBaseline.ps1'
```

### 5. Build the Samba appliance image

**Prerequisite — drop your SSH public key(s) into `lab/keys/`** so the
deployed image will accept your login. See
[`lab/keys/README.md`](lab/keys/README.md). The directory is gitignored
except for the README, so a fresh clone always starts empty.

```bash
cp ~/.ssh/id_ed25519.pub lab/keys/$(whoami).pub
```

Then a single command stages a Debian cloud-init seed, creates the
Hyper-V VM, runs `prepare-image.sh`, and snapshots the result as
`golden-image`. No attended installer, no console clicks:

```bash
lab/build-fresh-base.sh -f       # -f removes any existing samba-dc1 first
```

Under the hood:

1. `lab/stage-samba-base.sh` produces `D:\ISO\debian-13-samba-base.vhdx`
   (one-time Debian generic-cloud → VHDX conversion, ~60 s) plus a
   per-VM `D:\ISO\samba-dc1-seed.iso` carrying hostname, the keys you
   placed in `lab/keys/`, a `debadmin` user with passwordless sudo, and
   a documented default password for console-only fallback access.
2. `lab/hyperv/New-SambaTestVM.ps1` creates a Gen2 VM with a
   differencing VHDX rooted on the base, the seed ISO mounted as DVD,
   MAC pinned to the dnsmasq reservation. Boots, cloud-init applies
   the seed once, the VM is reachable on `10.10.10.20`.
3. `prepare-image.sh` runs unattended over SSH (~5 minutes), then
   reboots; `samba-firstboot` detects the hypervisor and installs
   matching guest-agent packages offline.
4. Two checkpoints land on `samba-dc1`:
   - `deploy-master` — host-agnostic, intended for export and
     redistribution (see [`docs/RELEASE.md`](docs/RELEASE.md)).
   - `golden-image` — Hyper-V tailored, used by the test scenarios.

Verify reachability after the build:

```bash
ssh -J nmadmin@server debadmin@10.10.10.20 'sudo -n true && echo OK'
```

When deployed elsewhere, the appliance presents a console-side text
menu first (network status, password change, SSH-key paste, halt/reboot)
and only opens the whiptail TUI once the operator picks `[I]nteractive`.
See the "First boot" section in [`docs/RELEASE.md`](docs/RELEASE.md).

## Running Tests

List scenarios:

```bash
lab/run-scenario.sh --list
```

Run the prepared-image smoke test:

```bash
lab/run-scenario.sh smoke-prepared-image
```

Run the main join regression:

```bash
lab/run-scenario.sh join-dc
```

Useful iteration flags:

```bash
lab/run-scenario.sh join-dc --verify-only
lab/run-scenario.sh join-dc --no-reset --no-cleanup
lab/run-scenario.sh join-dc --dry-cleanup
```

Every run writes a transcript to `test-results/<scenario>-<timestamp>.log`.

`lab/run-scenario.sh` is a thin wrapper around `../lab-kit/bin/run-scenario.sh`.
It sets `LAB_ENV=lab/samba.env`, resolves the scenario short-name to a file in
`lab/scenarios/`, and forwards flags. The `--no-cleanup` / `--dry-cleanup`
flags set `SC_SKIP_CLEANUP` / `SC_DRY_CLEANUP` env vars which scenarios read
in their `pre_hook` (only `join-dc` uses them today — the smoke scenario
has no AD cleanup).

For the full test plan and important tests to add next, see
[`docs/LAB-TESTING.md`](docs/LAB-TESTING.md).

## Releasing and Deploying

`lab/export-deploy-master.sh` packages the host-agnostic `deploy-master`
checkpoint into four interchange formats (vhdx / qcow2 / vmdk / ova
plus `SHA256SUMS`) under `dist/<version>/`. Deployers import the matching
artifact on their hypervisor; first boot fires `samba-firstboot`, which
detects the actual virt environment and offline-installs the right guest
agent from the pre-staged cache.

Full workflow + per-hypervisor import recipes (Hyper-V, KVM/libvirt,
Proxmox, VMware, VirtualBox, Nutanix AHV) and the SSH-key-from-builder
caveat live in [`docs/RELEASE.md`](docs/RELEASE.md).

## Important Design Notes

- Samba does not implement DFSR. SYSVOL replication is handled explicitly by
  `sysvol-sync` and by SMB-based seeding after a Windows join. Whole-tree ACL
  resets run through `samba-sysvol-acl-reset.service`, so a large domain can
  take as long as needed without depending on the initiating SSH connection.
  The foreground client prints elapsed heartbeats; a replacement session can
  inspect `samba-sconfig sysvol-acl-status` and
  `/var/log/samba/sysvol-acl-reset.log`. A failed reset makes the join report a
  partial failure instead of being silently ignored.
- Existing domain-based DFS namespace roots are protected automatically
  during provision or join. The DC reads replicated root-target metadata,
  creates managed `msdfs proxy` shares, excludes itself to prevent referral
  loops, and converges every five minutes. A failed or conflicting update
  retains the last known-good configuration and makes the join report a
  partial failure; operators can retry with `samba-sconfig dfs-root-sync`.
- Separately, DFS-N can be configured as a tertiary fallback namespace
  target via the interactive *DFS Namespace Server* menu or the remaining
  `samba-sconfig dfs-*` commands. The appliance reads replicated link metadata,
  parses the UTF-16LE-XML `msDFS-TargetListv2` blobs, and atomically
  materializes MSDFS symlinks under a hosted namespace share. Tertiary
  status is set on the Windows side (`New-DfsnRootTarget` to register,
  then `Set-DfsnRootTarget -ReferralPriorityClass GlobalLow`) —
  symlink ordering is only a within-referral hint. Design,
  AD-storage truth checks, and adversarial-input rules:
  [`docs/DFS-N.md`](docs/DFS-N.md).
- Samba's default AD DC functional level can be too low for modern Windows
  forests. `samba-sconfig` probes rootDSE and passes the matching functional
  level to `samba-tool domain join`.
- Windows KCC can report replication error `8524` if the Samba DC's PTR record
  is missing. The join flow registers the PTR and forces KCC afterward.
- The image preparation script avoids baking internet NTP sources into chrony.
  Domain time is configured during provision or join, where the correct source
  is known.
- The generated TLS certificate is self-signed but includes SANs. Production
  deployments should replace it with a CA-issued certificate or a managed local
  CA workflow.

## Current Status

The current implemented regression is `join-dc`: revert the prepared Debian
image, join it to the WS2025 forest as an additional DC, validate Samba and
Windows-side replication, ensure SYSVOL is populated, and verify the TLS cert
has SAN entries.

Next useful work is documentation polish, more scenarios, and broader
headless `samba-sconfig` commands so tests can cover provision, RODC, firewall,
hardening, diagnostics, and SYSVOL sync without driving the TUI.
