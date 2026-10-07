# Agent Guide

This file is the vendor-neutral working brief for coding agents in this
repository. It should be safe for Claude Code, Codex, local agents, or other
tools to read. Vendor-specific notes are explicitly marked and should not be
treated as general project requirements.

**General conventions, project narrative, and shared decisions live in
the sibling repo [`../dev-commons/`](../dev-commons/).** Read at least
[`../dev-commons/CONTEXT.md`](../dev-commons/CONTEXT.md) and
[`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) before substantive
work here. This file covers what's specific to `samba-addc-appliance`.

## Project Purpose

Build and test a Samba Active Directory Domain Controller appliance on Debian
13. The appliance has two core scripts:

- `prepare-image.sh`: one-time Debian image preparation.
- `samba-sconfig.sh`: whiptail TUI plus headless CLI for provision, join,
  hardening, diagnostics, and service maintenance.

This repo is one of six siblings under `Debian-SAMBA/` (alongside
`dev-commons`, `lab-kit`, `lab-router`, `appliance-core`, and
`smb-proxy-appliance`). It consumes `lab-kit` and `lab-router` at runtime
and vendors `appliance-core` during image preparation; see
[`../dev-commons/REPO-SPLIT.md`](../dev-commons/REPO-SPLIT.md) for the
full sibling layout, dependency map, and per-repo scope.

Start here if you are new to the environment:

- [`../dev-commons/CONTEXT.md`](../dev-commons/CONTEXT.md) — project narrative
- [`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) — coding/docs conventions
- [`../dev-commons/REPO-SPLIT.md`](../dev-commons/REPO-SPLIT.md) — sibling layout
- `docs/SETUP.md` — Mac + Hyper-V host + ISOs + sibling checkout
- `README.md` — repo map, lab build procedure, test workflow
- `docs/LAB-TESTING.md` — scenario model and test plan

## Current Lab Model

The current lab is Hyper-V based:

- Mac or local workstation runs the coding agent.
- Hyper-V host is reachable as `nmadmin@server`.
- `/Volumes/ISO` on the Mac maps to `D:\ISO\` on the host.
- `router1` provides NAT, DHCP, and DNS forwarding on `10.10.10.0/24`.
- `WS2025-DC1` is the first Windows Server 2025 DC for `lab.test`.
- `samba-dc1` is the Debian appliance VM under test.

Important addresses:

| Role | Hostname | IP |
| --- | --- | --- |
| Router | `router1` | `10.10.10.1` |
| Windows DC | `WS2025-DC1` | `10.10.10.10` |
| Samba DC under test | `samba-dc1` | `10.10.10.20` |
| Optional second Samba DC | `samba-dc2` | `10.10.10.21` |

Lab-only credentials may appear in docs and scripts. They are not production
secrets.

## Persistent Infrastructure

Do not tear these down casually:

- Hyper-V switch `Lab-NAT`
- VM `router1`
- VM `WS2025-DC1`
- AD domain `lab.test`
- Baseline GPOs and OU structure
- Prepared `samba-dc1` checkpoint `golden-image`

Scenario tests may revert `samba-dc1` and clean Samba-specific AD records.
They should not rebuild the persistent router or Windows DC unless explicitly
asked.

## Common Commands

Run a command on the Hyper-V host:

```bash
ssh nmadmin@server 'Get-VM | Format-Table Name,State,Uptime'
```

Run a command on router or Samba VM through the host:

```bash
ssh -J nmadmin@server hm@10.10.10.1 'sudo nft list ruleset'
ssh -J nmadmin@server debadmin@10.10.10.20 'sudo systemctl is-active samba-ad-dc'
```

Stage lab scripts to the host share:

```bash
mkdir -p /Volumes/ISO/lab-scripts
cp lab/hyperv/*.ps1 lab/hyperv/*.xml /Volumes/ISO/lab-scripts/
cp ../lab-kit/hypervisors/hyperv/*.ps1 /Volumes/ISO/lab-scripts/
cp ../lab-router/hypervisors/hyperv/*.ps1 /Volumes/ISO/lab-scripts/
```

Run scenario tests:

```bash
lab/run-scenario.sh --list
lab/run-scenario.sh smoke-prepared-image
lab/run-scenario.sh join-dc
```

Use `--verify-only` for fast assertion iteration against current VM state:

```bash
lab/run-scenario.sh join-dc --verify-only
```

## Checks

```bash
bash -n prepare-image.sh samba-sconfig.sh lab/run-scenario.sh lab/scenarios/*.sh
```

## Development Rules

- Prefer small, reviewable changes.
- Preserve existing lab compatibility unless the user asks for a breaking
  migration.
- Do not commit or publish ad-hoc test logs unless they are intentionally
  chosen as evidence.
- Do not revert user changes without explicit instruction.
- Keep reusable lab/router work moving toward the sibling repos, not deeper
  into this Samba repo.
- Add tests or scenario assertions when changing behavior.
- Use the headless `samba-sconfig` CLI for automation instead of driving the
  whiptail UI.

## Important Samba Interop Notes

- Samba does not implement DFSR. SYSVOL must be seeded or synced out of band.
- Every provision/join automatically mirrors AD domain DFS roots into managed
  `msdfs proxy` shares and keeps them converged. The separate optional
  tertiary-target mode materializes AD-replicated `msDFS-Linkv2` objects as
  MSDFS symlinks. See `docs/DFS-N.md` for both boundaries, parsing, and tests.
- The join path probes target forest functional level because Samba's default
  can be too low for modern Windows forests.
- The join path registers this DC's PTR record because Windows KCC can cache
  replication error 8524 when reverse DNS is missing.
- chrony is deliberately left deployment-neutral during image prep and pointed
  at the domain source during provision or join.
- TLS self-signed cert generation includes SANs, but production deployments
  should use a real CA path.

## Private Agent State

Agents may keep private local folders such as `.claude/`, `.codex/`,
`.cursor/`, `.continue/`, or `.aider*`. These are ignored and should not be
published.

Shared project knowledge belongs in tracked Markdown files, not in private
agent folders.

## Vendor-Specific Notes

### Claude Code

Claude Code reads `CLAUDE.md` by convention. In this repo, `CLAUDE.md` is a
compatibility entry point that points back to this neutral guide.

### Codex

Codex-style agents should use this file as the project brief and follow the
repo's normal git hygiene. Keep local `.codex/` state private.

### Local Lightweight Agents

Local agents are useful for boilerplate, scaffolding, lint-only edits, simple
renames, and repetitive doc generation. They should be given narrow ownership
and should not make broad architectural changes without human or senior-agent
review.
