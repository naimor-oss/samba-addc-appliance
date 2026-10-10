# Development and Test Environment Setup

This guide is the from-scratch "start here" for someone who wants to
develop on or test the Samba AD DC appliance. It covers the Mac-side
tooling, Hyper-V host, external artifacts, and the sibling-repo layout.
After finishing this guide, follow the "First-Time Lab Setup" section
in the main [README](../README.md) to actually build the lab VMs.

> **Workstation (2026-10):** the supported workstation is Windows 11 with
> WSL2 and Hyper-V. Set it up with
> [`../../dev-commons/WSL2-LAB-SETUP.md`](../../dev-commons/WSL2-LAB-SETUP.md);
> the lab scripts pick the ISO share path, seed-ISO builder and checksum
> tool through `lab-kit/lib/lab-host.sh` (`/mnt/d/ISO` on WSL2). The
> macOS instructions below still describe the legacy Mac workflow.

## Overview

The lab is driven from a Mac and runs on a remote Hyper-V host. Three
git repositories live side by side on the Mac:

```text
Debian-SAMBA/
  lab-kit/               reusable lab orchestration (generic runner)
  lab-router/            reusable router VM builder
  samba-addc-appliance/  this repo: Samba appliance + Samba scenarios
```

Four VMs run on the Hyper-V host:

| VM | Purpose | Address |
| --- | --- | --- |
| `router1` | Debian NAT + DHCP + DNS forwarder | 10.10.10.1 |
| `WS2025-DC1` | Windows Server 2025 first DC for `lab.test` | 10.10.10.10 |
| `samba-dc1` | Debian appliance under test | 10.10.10.20 |
| `samba-dc2` (optional) | Second Samba DC for replication tests | 10.10.10.21 |

The Mac mounts an SMB share from the Hyper-V host (typically
`/Volumes/ISO` on the Mac = `D:\ISO\` on the host). This share is where
installer ISOs, built artifacts, and staged helper scripts live. The
runner jumps through the host via SSH to reach the VMs.

## Mac Prerequisites

| Tool | Required | Install |
| --- | --- | --- |
| Homebrew | yes | <https://brew.sh> |
| `qemu-img` | yes | `brew install qemu` |
| `git` | yes | Xcode CLT: `xcode-select --install` |
| `ssh`, `scp` | yes | macOS built-in |
| `curl` | yes | macOS built-in |
| `hdiutil` | yes | macOS built-in |
| `yq` | if using `--config YAML` | `brew install yq` (mikefarah v4) |
| `bsdtar` | optional | macOS built-in; handy for inspecting generated seed ISOs |

Generate an SSH keypair if you do not have one. The lab flow assumes
ed25519 at `~/.ssh/id_ed25519.pub`:

```bash
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```

## Hyper-V Host Prerequisites

The Hyper-V host is any Windows machine with the Hyper-V role enabled.
Windows Server 2025 was used during development.

Required on the host:

- Hyper-V role installed and working
- PowerShell 7 (`pwsh.exe`) on `PATH` (install from
  <https://aka.ms/powershell>)
- OpenSSH Server enabled, running, and allowed through the firewall
- An administrator account with key-based SSH from the Mac
- At least one **external** virtual switch that has upstream internet
  access. The router VM uses this as its WAN. The default switch name
  in the scripts is `PCI 1G Port 1`; override with
  `-WanSwitchName 'your-switch'` on `New-LabRouter.ps1` if yours
  differs.
- A directory shared over SMB to the Mac, with the host-side path
  `D:\ISO\` by default. The Mac's mount point is whatever you connect
  it as (typically `/Volumes/ISO`).

### Enabling OpenSSH Server on the host

As admin on the Hyper-V host:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service sshd -StartupType Automatic
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

Deploy your Mac public key so the Mac user can SSH without a password.
For admin accounts on Windows, the file is
`C:\ProgramData\ssh\administrators_authorized_keys` (root owner,
inherited from parent permissions disabled). See
<https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_server_configuration#administrative-user>.

### Making pwsh the default shell

Optional but convenient, so `ssh host 'Get-VM'` works without
invocation wrapping:

```powershell
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value (Get-Command pwsh.exe).Source -PropertyType String -Force
```

## External Artifacts

Download these to the SMB share (so both the Mac and the Hyper-V host
can see them). The stager and PowerShell scripts expect them at the
indicated filenames.

| Artifact | Default path on Mac | Where to get it |
| --- | --- | --- |
| Windows Server 2025 Evaluation ISO | `/Volumes/ISO/*WS*26100*_EVAL*.iso` | [Microsoft Evaluation Center](https://www.microsoft.com/evalcenter/evaluate-windows-server) |
| MSFT Security Baseline for WS2025 v2602 | `/Volumes/ISO/WS2025-2602-Security-Baseline.zip` | [Microsoft Security Compliance Toolkit](https://learn.microsoft.com/windows/security/threat-protection/security-compliance-toolkit-10) |

The Debian 13 generic cloud image used by both the router and the Samba
appliance is fetched automatically the first time you run
`stage-router-artifacts.sh` (lab-router) or `lab/stage-samba-base.sh`
(this repo) — you do not need to download a Debian ISO by hand. The
manual Debian netinst flow has been retired in favor of cloud-init.

Exact filenames used by default in the scripts (tweak via script
parameters if you use different names):

- `lab/hyperv/New-WS2025Lab.ps1` expects
  `D:\ISO\26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso`
  (pass `-IsoPath` to override)
- `lab/hyperv/New-SambaTestVM.ps1` expects
  `D:\ISO\debian-13-samba-base.vhdx` and
  `D:\ISO\<VMName>-seed.iso` — both produced by
  `lab/stage-samba-base.sh` (pass `-BaseVhdxPath` / `-SeedIso` to
  override). End-to-end builds usually go through
  `lab/build-fresh-base.sh` instead.
- `lab/hyperv/Apply-SecurityBaseline.ps1` expects
  `D:\ISO\WS2025-2602-Security-Baseline.zip` (pass `-BaselineZipPath`
  to override)

## Clone the Three Repos

All three repositories should sit under one parent directory. Many
scripts use relative paths like `../lab-router/...` that depend on
this layout.

```bash
mkdir -p ~/src/Debian-SAMBA && cd ~/src/Debian-SAMBA
git clone https://github.com/naimor-oss/lab-kit.git
git clone https://github.com/naimor-oss/lab-router.git
git clone https://github.com/naimor-oss/samba-addc-appliance.git
```

Verify:

```bash
ls -d lab-kit lab-router samba-addc-appliance
```

## Customizing Defaults for Your Host

The defaults in the scripts match the original developer's environment.
If your setup differs, these are the touch points:

| Setting | Default | Change in |
| --- | --- | --- |
| Hyper-V host DNS name | `server` | `samba-addc-appliance/lab/samba.env` (`LAB_HV_HOST`) |
| Host SSH user | `labadmin` | `samba-addc-appliance/lab/samba.env` (`LAB_HV_USER`) |
| Mac-side ISO share path | `/Volumes/ISO/lab-scripts` | `samba-addc-appliance/lab/samba.env` (`LAB_STAGE_DIR`) |
| Host-side ISO share path | `D:\ISO\lab-scripts` | `samba-addc-appliance/lab/samba.env` (`LAB_HOST_STAGE_DIR`) |
| VM admin user on Samba VM | `debadmin` | `samba.env` (`LAB_VM_USER`) and manual install |
| Router admin user | current macOS user | `../lab-router/configs/samba-addc.yaml` (`router.user`) or `--user` flag |
| External WAN switch name | `PCI 1G Port 1` | `-WanSwitchName` on `New-LabRouter.ps1` |
| Internal LAN switch name | `Lab-NAT` | `-LanSwitchName` on `New-LabRouter.ps1` and `-SwitchName` on `New-WS2025Lab.ps1` / `New-SambaTestVM.ps1` |
| Subnet and addresses | `10.10.10.0/24` | `../lab-router/configs/samba-addc.yaml` |

Do not edit these values in multiple places. The scripts are wired so
that `samba.env` + the YAML config are the only files you should need
to touch for host-specific settings.

## Verify Your Setup

Run these from the `samba-addc-appliance/` directory after cloning all
three repos. Every line should succeed.

```bash
# 1. The three siblings exist at the expected paths.
ls -d ../lab-kit ../lab-router >/dev/null && echo "siblings OK"

# 2. Mac tools.
for t in qemu-img hdiutil curl ssh scp git; do
    command -v "$t" >/dev/null || { echo "missing $t"; false; }
done && echo "mac tools OK"

# 3. Optional: yq if you want the YAML config path.
command -v yq >/dev/null && echo "yq OK (YAML config supported)" || echo "yq missing (use --extra-dnsmasq instead)"

# 4. SSH keypair.
[[ -f ~/.ssh/id_ed25519.pub ]] && echo "ssh key OK"

# 5. SSH to the Hyper-V host with pwsh. Replace labadmin@server if yours differs.
ssh labadmin@server 'pwsh -Command "(Get-VMSwitch | Where-Object SwitchType -eq \"External\").Name"'

# 6. ISO share is mounted and writable.
touch /Volumes/ISO/.write-test && rm /Volumes/ISO/.write-test && echo "ISO share OK"

# 7. Required external artifacts are present.
ls /Volumes/ISO/*.iso /Volumes/ISO/WS2025-2602-Security-Baseline.zip

# 8. Syntax check the three repos.
(cd ../samba-addc-appliance && bash -n prepare-image.sh samba-sconfig.sh \
    lab/run-scenario.sh lab/stage-samba-base.sh lab/build-fresh-base.sh \
    lab/scenarios/*.sh)
(cd ../lab-kit && bash -n bin/run-scenario.sh scenarios/common/*.sh)
(cd ../lab-router && bash -n scripts/stage-router-artifacts.sh)
echo "syntax checks OK"
```

## What Next

Return to the main [README "First-Time Lab Setup"](../README.md#first-time-lab-setup)
section. Working through it in order will:

1. Stage router artifacts with the YAML config.
2. Stage the Mac-side lab scripts to the host share.
3. Build `router1`.
4. Build `WS2025-DC1` and apply the Microsoft baseline.
5. Build `samba-dc1`, run `prepare-image.sh`, and checkpoint it as
   `golden-image`.

From then on, the daily loop is:

```bash
lab/run-scenario.sh smoke-prepared-image
lab/run-scenario.sh join-dc
```

When you change `prepare-image.sh` and need a fresh `golden-image`
checkpoint to run scenarios against, rebuild it end-to-end (no
attended Debian installer, no console clicks):

```bash
lab/build-fresh-base.sh -f       # -f removes the existing samba-dc1 first
```

That stages the cloud image + per-VM seed, creates the VM, waits for
cloud-init, runs `prepare-image.sh`, shuts down, and snapshots
`golden-image`. ~6 minutes start to finish, mostly unattended.

See [LAB-TESTING.md](LAB-TESTING.md) for scenario authoring and the
full test plan.
