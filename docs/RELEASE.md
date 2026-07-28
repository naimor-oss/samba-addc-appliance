# Building, Releasing, and Deploying the Samba AD DC Appliance

This guide covers the end-to-end release workflow: producing the
host-agnostic deploy-master image, packaging it into the four
distribution formats, and importing it on each supported hypervisor.

## Artifact catalog

`lab/export-deploy-master.sh` produces the same disk content in four
forms. Pick the one your hypervisor imports natively:

| File | Size (approx) | Use for |
| --- | --- | --- |
| `samba-addc-appliance-vYYYY.MM.DD.vhdx` | ~2.5 GB | Hyper-V (lossless native format) |
| `samba-addc-appliance-vYYYY.MM.DD.qcow2` | ~1.4 GB | KVM, libvirt, Proxmox VE, Nutanix AHV, OpenStack |
| `samba-addc-appliance-vYYYY.MM.DD.vmdk` | ~470 MB | Standalone streamOptimized VMDK (rare; most VMware users want the OVA) |
| `samba-addc-appliance-vYYYY.MM.DD.ova` | ~500 MB | VMware (ESXi, vSphere, Workstation, Fusion); VirtualBox |
| `SHA256SUMS` | small | Integrity verification — `shasum -a 256 -c SHA256SUMS` |

All four files are independently usable; you do not need them all to deploy.

## Producing a release

### Prerequisites on the build operator's Mac

- Hyper-V host reachable over SSH as `nmadmin@server` (per `samba.env`).
- `qemu-img` from `brew install qemu`.
- `ovftool` at `/Volumes/Data/Developer/Debian-SAMBA/ovftool/ovftool`
  (override with `OVFTOOL=...`). macOS Gatekeeper may refuse a couple of
  ovftool's bundled dylibs the first time it runs; allow them in System
  Settings → Privacy & Security and re-run until it succeeds. Subsequent
  runs work without intervention.
- The Hyper-V host's `D:\ISO\` directory is mounted on the Mac as
  `/Volumes/ISO/`.
- `samba-dc1` on Hyper-V has a `deploy-master` checkpoint
  (post-prepare-image, pre-firstboot — produced by
  `lab/build-fresh-base.sh`).

### Build a fresh deploy-master

If you don't already have one, or want a fresh master with the latest
`prepare-image.sh`:

```bash
lab/build-fresh-base.sh -f
```

That produces both `deploy-master` (host-agnostic, ship-this-one) and
`golden-image` (Hyper-V-tailored, used by the test scenarios). About 7
minutes from a warm cache.

### Run the export pipeline

```bash
lab/export-deploy-master.sh
```

Defaults: VM=`samba-dc1`, snapshot=`deploy-master`, version=today's date
(`Y.M.D`). Override with `-V 2026.04.27` to set a specific version
string, or `-s some-other-snapshot` to export a different checkpoint.

The script:

1. `Export-VMSnapshot` on Hyper-V → `D:\ISO\Export\samba-addc-appliance-vYYYY.MM.DD\`.
2. `Convert-VHD` on the host follows the differencing chain to produce a
   self-contained `merged.vhdx` (the original parent + diff are removed
   to save SMB transfer time).
3. The .vhdx is copied to `dist/<version>/` on the Mac and converted by
   `qemu-img` into qcow2 (compat=1.1) and streamOptimized vmdk.
4. A minimal .vmx (vmx-19, EFI, Secure Boot off, 2 vCPU, 2 GB RAM,
   pvscsi disk + vmxnet3 NIC, debian12-64 guestOS) is fed to ovftool to
   bundle the vmdk into a sha256-manifested .ova.
5. `shasum -a 256` over all four artifacts produces `SHA256SUMS`.
6. The host-side export tree is removed (use `--keep-export` to retain
   it for inspection).

### Validate the OVA

`ovftool` can introspect its own output:

```bash
/Volumes/Data/Developer/Debian-SAMBA/ovftool/ovftool dist/<ver>/<name>.ova
```

Expected: 1 disk (20 GB capacity, ~1.4 GB sparse), 2 vCPU, 2 GB RAM,
vmxnet3 NIC, vmx-19, debian12_64guest.

### Verify before distribution

```bash
cd dist/samba-addc-appliance-vYYYY.MM.DD
shasum -a 256 -c SHA256SUMS
```

Distribute the four artifacts + `SHA256SUMS` together. There is no
release-side signing today (internal use); add detached `.asc`
signatures if/when you publish externally.

## Importing the appliance

### Hyper-V

```powershell
# Copy the .vhdx into a permanent location on the host:
Copy-Item samba-addc-appliance-vYYYY.MM.DD.vhdx D:\Lab\samba-dc-prod\

# Create the VM:
New-VM -Name samba-dc-prod -Generation 2 `
       -MemoryStartupBytes 2GB `
       -SwitchName 'YourSwitch' `
       -VHDPath D:\Lab\samba-dc-prod\samba-addc-appliance-vYYYY.MM.DD.vhdx
Set-VMProcessor -VMName samba-dc-prod -Count 2
Set-VMMemory -VMName samba-dc-prod -DynamicMemoryEnabled $false
Set-VMFirmware -VMName samba-dc-prod -EnableSecureBoot Off
Add-VMNetworkAdapter -VMName samba-dc-prod -SwitchName 'YourSwitch'
Start-VM samba-dc-prod
```

Notes:

- **Generation 2**, UEFI, **Secure Boot OFF** (the cloud image bootloader
  isn't signed by Microsoft's UEFI CA).
- Don't enable Dynamic Memory — AD DCs need fixed RAM.
- Use offline (Standard) checkpoints, not Production checkpoints.

### KVM / libvirt / virt-manager

```bash
# Place the qcow2 in the libvirt images dir
sudo install -o libvirt-qemu -g kvm -m 0660 \
    samba-addc-appliance-vYYYY.MM.DD.qcow2 /var/lib/libvirt/images/samba-dc-prod.qcow2

# Create the VM
virt-install \
    --name samba-dc-prod \
    --memory 2048 --vcpus 2 \
    --disk path=/var/lib/libvirt/images/samba-dc-prod.qcow2,bus=virtio \
    --network network=default,model=virtio \
    --boot uefi \
    --os-variant debian12 \
    --import --noautoconsole
```

Notes:

- The image boots UEFI; use `--boot uefi` (libvirt picks a non-Secure-Boot
  OVMF firmware variant).
- virtio-blk disk + virtio-net NIC are recommended; the Debian kernel
  has both built-in.

### Proxmox VE

```bash
# Upload the qcow2 to the Proxmox host (via SCP / Web UI / NFS); then:
qm importdisk 9000 \
    /path/to/samba-addc-appliance-vYYYY.MM.DD.qcow2 \
    local-lvm

# Bind the imported disk to a fresh VM:
qm create 9000 \
    --name samba-dc-prod \
    --memory 2048 --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --bios ovmf --machine q35 \
    --efidisk0 local-lvm:0 \
    --scsihw virtio-scsi-pci \
    --scsi0 local-lvm:vm-9000-disk-0 \
    --boot c --bootdisk scsi0
qm start 9000
```

(Replace `9000`, `local-lvm`, and `vmbr0` with site-appropriate values.)

Notes:

- `bios=ovmf` (UEFI). EFI disk is required by Proxmox's UEFI mode.
- virtio-scsi for the disk; virtio for the NIC.

### VMware (ESXi / vSphere)

GUI:

1. **vSphere Client → Deploy OVF Template → Local file**, pick the
   `.ova`.
2. Defaults are fine; you may want to change network mapping and disk
   datastore.
3. Power on after deploy.

CLI:

```bash
ovftool --acceptAllEulas \
    --datastore=datastore1 \
    --net:nat='VM Network' \
    samba-addc-appliance-vYYYY.MM.DD.ova \
    'vi://administrator@vsphere.local@vcenter.example.com/Datacenter/host/Cluster/Resources'
```

### VMware Workstation / Fusion

`File → Open` and pick the `.ova`. The appliance imports as a new VM,
EFI/Secure-Boot-off automatically picked up from the OVF descriptor.

### VirtualBox

```bash
VBoxManage import samba-addc-appliance-vYYYY.MM.DD.ova \
    --vsys 0 --vmname samba-dc-prod \
    --vsys 0 --memory 2048 --cpus 2
```

Or `File → Import Appliance` in the GUI.

Notes:

- VirtualBox renames `vmxnet3` to its closest equivalent at import; pick
  Intel PRO/1000 MT (e1000) if you want max compatibility, or virtio-net
  for performance.
- Secure Boot off is preserved from the OVF.

### Nutanix AHV (Prism)

1. **Prism → Storage → Image Configuration → Upload Image**, select the
   `.qcow2`. Set image type to DISK.
2. **VM → Create VM**, pick the uploaded image as a new disk, set 2 vCPU
   / 2 GB RAM, attach a network, save and power on.

Nutanix AHV is KVM under the hood; the same considerations as KVM apply.

## First boot of a deployed VM

The image is host-agnostic by design, so the first time a VM boots from
this disk, `samba-firstboot.service` runs once and tailors itself:

1. `systemd-detect-virt` identifies the hypervisor. For Hyper-V it
   additionally probes the chassis-asset-tag DMI string to distinguish
   Azure from on-prem.
2. The matching guest-agent package is installed offline from
   `/var/cache/samba-appliance/vmtools/<pkg>/`. Possible packages:
   - `qemu-guest-agent` (KVM/Proxmox/Nutanix/AWS Nitro/Xen)
   - `open-vm-tools` (VMware)
   - `hyperv-daemons` (Hyper-V on-prem and Azure)
   - `cloud-init` (added on Azure / AWS for IMDS-driven SSH-key injection)
   - `cloud-guest-utils` (always — provides growpart for first-boot
     root-partition resize when a cloud allocates more disk than the
     master image carries)
3. Recommended VM hardware for the detected platform is printed to the
   serial console and to `/etc/motd.d/01-samba-firstboot` so the SSH
   login banner shows it until an admin removes the file.
4. Unused per-package caches are deleted to keep the image clean.
5. The marker `/var/lib/samba-firstboot.done` is touched and the unit
   disables itself; subsequent boots are no-ops.

If you want to force firstboot to re-fire (for example to test a
re-deployment locally), `rm /var/lib/samba-firstboot.done && systemctl
enable samba-firstboot.service && reboot`.

## Logging in

The deployed appliance gives you **three** independent ways in. You only
need one of them to work:

1. **SSH with a baked-in key.** The deploy-master was prepared by an
   operator whose pubkey(s) lived under `lab/keys/*.pub` at master-build
   time. SSH login as `debadmin` with any of those keys has worked since
   first boot. Coordinate out-of-band: get the operator to confirm a
   fingerprint, or have them rebuild after dropping your pubkey into
   `lab/keys/`. (Releases produced for outside distribution may have an
   empty `lab/keys/` and rely entirely on path 2 or 3 below.)

2. **Console password.** `debadmin` ships with a documented default
   password — **`samba-appliance-please-change-me`** — that works only
   at the hypervisor's console. Over SSH, password auth is disabled
   (`ssh_pwauth: false`). The TTY1 wizard (next section) forces you to
   change this password before you can mark setup complete, so the
   default is a strictly time-limited credential.

3. **TTY1 console wizard.** Open the hypervisor's console on a freshly
   deployed VM and you land directly in `samba-init`, a whiptail-driven
   setup wizard. From there you can configure the network (DHCP or
   static), change the password, add your own SSH public key, set the
   hostname, and view the `samba-firstboot` log — all without any
   network connectivity. This is the path to use when DHCP didn't work
   on the deployment network and SSH therefore can't reach the VM.

### The TTY1 setup wizard

`samba-init` runs on `/dev/tty1` via a `getty@tty1.service` autologin
override on every boot until **`/var/lib/samba-init.done`** exists. Once
the wizard's "Mark setup complete" option is picked, the override is
removed and TTY1 falls back to the standard login prompt.

Wizard menu:

| # | Action | Notes |
|---|---|---|
| 1 | Show network & setup status | Hostname, all NIC IPs, default route, DNS, AD-DC service state — pure read-only |
| 2 | Configure network | DHCP or static; writes `/etc/netplan/60-samba-init.yaml` and runs `netplan apply` |
| 3 | Change debadmin password | Required before "Mark setup complete" succeeds |
| 4 | Add an SSH authorized_keys entry | Paste a complete key, or type an Ed25519 key as four validated 17-character parts; fingerprint is confirmed before appending |
| 5 | Set hostname | NetBIOS-compatible (1-15 chars, starts with a letter) |
| 6 | Show samba-firstboot log | Diagnostics from the host-tailoring step |
| S | Drop to a root shell | Escape hatch for when the wizard isn't enough |
| D | Mark setup complete and proceed to login | Refused while default password is still active |

For QEMU/KVM deployments whose browser console is based on noVNC
(including Synology VMM), ordinary browser paste does not reach a Linux
text console. In Chrome, the optional
[`KVM Console Paste`](https://chromewebstore.google.com/detail/kvm-console-paste/acogolacfpbgbddopekjchlckaggmjkd)
extension can simulate the necessary keystrokes after it is allowed for
the VMM site. If browser extensions are not permitted, use the wizard's
four-part Ed25519 entry method instead.

To re-arm the wizard after marking it done (for example, to re-test the
flow on a re-imaged VM), reverse the marker:

```bash
sudo rm /var/lib/samba-init.done
sudo cp /usr/local/sbin/samba-init.getty-dropin \
        /etc/systemd/system/getty@tty1.service.d/samba-init.conf
sudo systemctl daemon-reload && sudo reboot
```

(The drop-in template lives next to the wizard for exactly this purpose.)

### The login banner (MOTD)

On every login (SSH or post-wizard console) `/etc/update-motd.d/15-samba-net-status`
prints a short status block: hostname, every NIC's address, default
gateway, DNS resolvers, whether the wizard is still pending, and whether
`samba-ad-dc` is running. This is the boot-time "what's wrong, why can't
I reach this thing" diagnostic. Removing the file silences the banner.

### Recovery if all three login paths fail

Extremely rare (operator's key was lost, default password was changed
to something forgotten, AND the wizard was already marked complete). To
recover:

1. Boot the VM into a Linux rescue ISO (or attach the disk to another
   Linux VM as a secondary disk).
2. Mount the root partition.
3. Either reset the password (`chroot` and `passwd debadmin`), or write
   a new pubkey to `/home/debadmin/.ssh/authorized_keys`, or delete
   `/var/lib/samba-init.done` and reinstall the getty drop-in to
   re-arm the wizard.
4. Detach the disk, boot normally.

For cloud platforms with IMDS (AWS, Azure), `samba-firstboot` installs
`cloud-init` which accepts SSH-key injection via the platform's
metadata service on subsequent boots — typically the cleanest recovery
path on those targets.

## Provisioning the deployed DC

After first boot is reachable, run the appliance configurator:

```bash
ssh debadmin@<deployed-vm-ip>
sudo samba-sconfig
```

The TUI walks you through:

1. **Domain Operations** → either *Provision New Forest* (standalone)
   or *Join Existing Forest as DC / RODC* (mixed-Samba/Windows or
   pure-Samba).
2. **SYSVOL Replication** → configure the periodic puller (default
   15-min interval, machine-Kerberos auth, Windows-DC-preferred
   discovery).
3. **Security Hardening** → applies signing/min-protocol/etc. settings
   to `smb.conf`.

For unattended deployments, the headless CLI subcommands are:

```bash
# Provision a new forest:
sudo env SC_REALM=corp.example SC_NETBIOS=CORP \
         SC_PASS='SecretAdminPwd!' \
         samba-sconfig provision-new

# Join an existing forest:
sudo env SC_REALM=corp.example SC_NETBIOS=CORP \
         SC_DC=10.0.0.10 \
         SC_ADMIN=Administrator SC_PASS='ExistingPwd!' \
         samba-sconfig join-dc
```

Both subcommands are exercised by `lab/scenarios/provision-new.sh` and
`lab/scenarios/join-dc.sh`; see those for the assertions a working
provision/join is expected to satisfy.

## Versioning

Date-based: `vYYYY.MM.DD`. The export script uses today's date by
default; override with `-V 2026.04.27` if you're rebuilding a specific
release.

## Known issues

- The deployed image has no console password and only the build
  operator's SSH key. See [Recovery if the SSH key is lost](#recovery-if-the-ssh-key-is-lost).
- VirtualBox renames the vmxnet3 NIC at import; manual NIC
  reconfiguration may be needed.
- Hyper-V users converting from the .vhdx to a different hypervisor
  should note the differencing-VHDX trap: the snapshot's saved disk
  references its parent path and is not portable on its own.
  `lab/export-deploy-master.sh` handles this with `Convert-VHD` before
  pulling.
- The .ova is ovftool-produced and validates against the OVF 1.0
  schema. Strict OVF 2.0 importers (some Nutanix builds) may reject it;
  use the .qcow2 instead.
- macOS bash 3.2 limitations affect contributors writing scenarios:
  parameter-expansion case conversion (`${var,,}` / `${var^^}`) is
  unavailable; use `tr` instead.
