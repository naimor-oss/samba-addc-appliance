# Samba AD DC update bundle

Every change after an image is built ships as one versioned bundle, built
and applied by the appliance-core update framework
(`../appliance-core/docs/lib-update.md`). This directory holds the DC's
part of it:

| File | Purpose |
| --- | --- |
| `hooks.sh` | recognise a pre-framework DC, backup list, preflight, stop/apply/verify/start |
| `ACCEPTS` | starting versions this bundle may be applied to (no wildcard) |
| `migrations/` | `NNN-name.sh`, run once per unit, in order (none yet) |

The version is `../VERSION`. `../updates/build-bundle.sh` builds
`dist/samba-addc-update-<version>.tar.gz` and `.sha256` from
`samba-sconfig.sh` plus the scripts `prepare-image.sh` generates
(`sysvol-sync`, `samba-dfs-parse-targets`, first-boot, init, login banner),
so a bundle and an image built from the same commit install the same files.

## What a bundle changes

- Replaces `samba-sconfig`, `sysvol-sync` and `samba-dfs-parse-targets`,
  the vendored appliance-core libs, and the first-boot/init/banner scripts
  where the DC already has them.
- Installs `samba-addc-update` and writes `/etc/samba-addc.release`.
- Never touches the AD database (`/var/lib/samba`), the DC's settings
  files, or Debian packages (Samba security updates arrive through apt).
- Pauses the DFS timers and waits for a running `sysvol-sync` while files
  are replaced, then restores them.

## Recognising a DC built before release identity

The production DC has no version marker. The bundle accepts it as
`0.0.0-legacy` only when `samba-sconfig` is installed, `smb.conf` has
`server role = active directory domain controller`, and there is no release
file. Anything else is refused.

## Refusals (nothing is changed)

- Unknown, unaccepted, or newer starting version.
- `dfs-update.conf` or `sysvol-sync.conf` cannot be read by the strict
  parser (it is named). A pre-v2 `sysvol-sync.conf` (`SYNC_TRANSPORT`,
  `REMOTE_DC`, ...) is migrated by re-running SYSVOL sync Configure in
  `samba-sconfig` first.

## Applying it

First bundle on the production DC:

```bash
sha256sum -c samba-addc-update-0.5.0.tar.gz.sha256
tar -xzf samba-addc-update-0.5.0.tar.gz
sudo ./samba-addc-update-0.5.0/install.sh
```

Afterwards, and on every image built from 0.5.0 or later:

```bash
sudo samba-addc-update apply samba-addc-update-X.Y.Z.tar.gz   # .sha256 next to it
samba-addc-update status
sudo samba-addc-update rollback                               # newest backup
```

Lab first: apply to a lab DC built from the same old image (T-UPG-1), run
the scenario suite (SYSVOL sync, DFS, Windows GPO retrieval), roll back and
verify again (T-UPG-4), then production. `tests/root/update-bundle.sh`
covers the same paths in a container against a simulated field DC.
