# DFS-N on the Samba AD DC Appliance — Design

Design for adding **DFS Namespace (DFS-N)** support to
`samba-addc-appliance` so the appliance can serve as a tertiary
namespace target alongside two physical Windows Server primaries
and a Synology read-only fallback.

This document is the corrected, project-aligned successor to the
draft sketch at `../../add-dfsn-to-samba-addc.md`. The draft is
preserved for historical reference; this file is authoritative.

## 1. What this is and is not

**Is:** turning the Samba AD DC into a *namespace server* — i.e. a
machine that responds to DFS referral requests for one or more
domain-based namespaces by handing clients a list of folder
targets (server\share). The metadata that drives those referrals
lives in AD (`CN=Dfs-Configuration,CN=System,DC=…`) and replicates
to this DC via normal AD replication. The Samba-side job is to
materialize that metadata as MSDFS symlinks under a hosted share so
Samba's existing `msdfs root` referral path can serve it.

**Is not:** a DFS replication engine. Samba does not implement DFSR.
Folder *content* is replicated by the Windows primaries (and copied
to the Synology by some other mechanism the operator owns). This
appliance only carries namespace metadata.

**Is not:** a way to "promote" the appliance to tertiary status. The
priority of this DC as a namespace target is set on the Windows
side via `Set-DfsnRootTarget -Priority`. Symlink target ordering
within a single referral controls *folder-target* selection, which
is a separate layer.

## 2. Operator boundary (what Windows-side admins must do)

Before any of this matters on the Samba side, an admin on a Windows
DC must:

1. Add this Samba DC as a namespace root target. The cmdlet is
   `New-DfsnRootTarget` — note `New-`, not `Add-`. (Folder targets
   use `New-DfsnFolderTarget`. There is no `Add-Dfsn*` cmdlet
   despite PowerShell's usual verb convention.)
   ```powershell
   New-DfsnRootTarget -Path \\lab.test\Public `
     -TargetPath \\samba-dc1.lab.test\Public `
     -ReferralPriorityClass GlobalLow
   ```
   `New-DfsnRootTarget` validates target reachability — the
   appliance must already be joined to the domain *and* its DFS-N
   share already advertised by `smbcontrol smbd reload-config`
   before this call succeeds.
2. Once registered, raise/lower its priority any time with
   `Set-DfsnRootTarget`:
   ```powershell
   Set-DfsnRootTarget -Path \\lab.test\Public `
     -TargetPath \\samba-dc1.lab.test\Public `
     -State Online `
     -ReferralPriorityClass GlobalLow
   ```
3. Ensure "Clients fail back to preferred targets" is enabled on the
   namespace and that the per-folder targets carry the desired
   priority class (primary Windows servers as `SiteCostNormal` or
   higher, Synology fallback as `GlobalLow`).

This is documented in the appliance README, not enforced by code.

## 3. AD storage we read from (v2 / 2008 server mode)

Confirmed against a live WS2025 forest. **The on-disk shape
differs from what MS-DFSNM v1 documents** in three load-bearing
ways: container name, double-namespace nesting, and the format of
`msDFS-TargetListv2`.

For each namespace `<NS>`, AD carries:

| Object | DN under domain NC | Notes |
| --- | --- | --- |
| Namespace anchor | `CN=<NS>,CN=Dfs-Configuration,CN=System,<dn>` | `objectClass=msDFS-NamespaceAnchor`. **Note "Dfs-" not "Dfsn-".** |
| Link container | `CN=<NS>,CN=<NS>,CN=Dfs-Configuration,CN=System,<dn>` | The namespace name appears twice. Holds the link objects as children. |
| Each link | `CN=link-<guid>,CN=<NS>,CN=<NS>,CN=Dfs-Configuration,...` | `objectClass=msDFS-Linkv2`. |

The update tool's `ldbsearch` base is the link container — i.e. the
doubled-`<NS>` form.

`msDFS-LinkPathv2` is a UTF-8 string of the form `/<sub>/<link>`,
forward-slash separator, **leading slash always present**. Example
real values from the lab: `/Reports`, `/Quarterly Reports (FY26)`,
`/IT$Tools`, `/one`. The validator strips the leading slash and
treats the rest as a relative POSIX path.

`msDFS-TargetListv2` is a **UTF-16LE-encoded XML document** (with
optional BOM), not a packed binary blob. Real shape:

```xml
<?xml version="1.0" encoding="utf-16"?>
<targets majorVersion="2" minorVersion="0" targetCount="N"
         xmlns="http://schemas.microsoft.com/dfs/2007/03">
  <target state="online" priorityClass="siteCostNormal"
          priorityRank="0">\\SERVER\share</target>
  ...
</targets>
```

`ldbsearch` returns it base64-encoded; the parser decodes,
strips the BOM, decodes UTF-16, strips the default `xmlns`, and
walks `<target>` elements with stdlib `xml.etree`.

## 4. Parsing strategy

**Findings, after probing the appliance:** Debian's
`python3-samba` (12:4.22.x trixie) does **not** ship the
`samba.dcerpc.dfsblobs` module. `from samba.dcerpc import dfsblobs`
raises `ImportError`. **Also**: the v2 blob is XML, so an NDR
parser was never the right answer regardless. The actual parser
in `/usr/local/sbin/samba-dfs-parse-targets` decodes base64,
strips a UTF-16 BOM, decodes UTF-16(LE/BE), strips the default
`xmlns`, and walks `<target>` elements with stdlib
`xml.etree.ElementTree`. Output is one TSV record per target:

```
<priorityClass>\t<priorityRank>\t<state>\t<unc>
```

The classes (`globalHigh`, `siteCostHigh`, `siteCostNormal`,
`siteCostLow`, `globalLow`, `manual`) flow through to
`samba-sconfig`'s ordering helper, which sorts by class first and
then by an operator-supplied prefer-regex within each class. AD
priority is authoritative; the regex is a tiebreaker within a
priority bucket.

The helper lives at `/usr/local/sbin/samba-dfs-parse-targets`,
installed by `prepare-image.sh`. Bash stays the orchestrator;
Python is confined to "blob on stdin → TSV on stdout". A
self-test against a captured WS2025 blob runs during image-prep
and aborts the build on mismatch — the regression line for the
two Microsoft truths above.

## 5. Filesystem layout and smb.conf integration

Hosted share path: `/srv/samba/dfs_root/<NS>` (one subdir per
namespace). MSDFS symlinks live under there mirroring
`msDFS-LinkPathv2`. A sentinel file at the top of the share:

```
/srv/samba/dfs_root/.dfsn-managed
```

is written by `dfs-init` and checked by `dfs-update`. Without it,
update refuses to prune. This is the safety net against pointing
the tool at a directory that wasn't initialized for it.

smb.conf integration uses a **drop-in include** rather than
in-place editing of the main file:

```
# /etc/samba/conf.d/dfs-root.conf  (managed by samba-sconfig dfs-init)
[<share-name>]
    path = /srv/samba/dfs_root
    msdfs root = yes
    read only = yes
    vfs objects = acl_xattr
    guest ok = no
```

Main `smb.conf` carries a single line:

```
include = /etc/samba/conf.d/dfs-root.conf
```

added once, idempotently, by `dfs-init`. Removing DFS-N is then
just deleting the include line and the drop-in file — reversible
with no diff against the rest of the file.

`read only = yes` is correct for a namespace root: clients arrive,
receive a referral, and connect to the *target* server for I/O.
They never write to the namespace share itself. Privileged writes
(symlink creation, prune) happen as root on the local filesystem,
not over SMB.

`host msdfs = yes` is asserted in `[global]` if not already set
(default-on in modern Samba; assertion is cheap insurance).

## 6. Update logic and safety guards

`dfs-update` runs as root, takes one or more `--namespace <NS>`
arguments (or reads them from a config file written by
`dfs-schedule`), and performs:

1. **Lock**: `flock -n /run/samba-dfs-update.lock` or exit 0
   silently. `/tmp` is not used (world-writable, hijackable).
2. **LDAP query** against `/var/lib/samba/private/sam.ldb` for
   `(objectClass=msDFS-Linkv2)` under
   `CN=<NS>,CN=<NS>,CN=Dfs-Configuration,CN=System,<base-dn>`. Base DN
   is auto-derived from `samba-tool domain info` or
   `/etc/samba/smb.conf`'s realm; `--base-dn` is an explicit
   override.
3. **Empty-result guard**: if the query returns zero link
   objects, *log a warning and exit 0 without pruning*. Empty
   namespaces are valid; the prune happens only when we have a
   confirmed authoritative list.
4. **Sentinel guard**: refuse to operate if
   `/srv/samba/dfs_root/.dfsn-managed` is missing. Forces an
   explicit `dfs-init` first.
5. **Parse**: invoke the Python helper for each link's
   `msDFS-TargetListv2`. Output: TSV records, one per target
   (`priorityClass\tpriorityRank\tstate\tunc`).
6. **Validate paths and targets** (see §7).
7. **Order targets**: by AD-supplied priority class first, then
   by an operator-supplied per-namespace preference list (regex
   on UNC) for tie-breaking. Default tie-break: stable
   alphabetical by UNC. The operator preference covers the
   "primaries first, Synology last" intent without hard-coding
   server names in the tool.
8. **Materialize**:
   - Build target string `msdfs:server1\share1,server2\share2,…`.
   - Write to a temp symlink path: `ln -s "msdfs:…" "$link.tmp"`.
   - Atomic swap: `mv -T "$link.tmp" "$link"`.
   - This is genuinely atomic; `ln -sfT` is delete-then-create.
9. **Prune**: walk the namespace subtree. For each entry:
   - If symlink AND target starts with `msdfs:` AND not in the
     authoritative set → unlink.
   - If empty directory AND we created its parent chain → rmdir.
   - **Anything else (regular file, foreign symlink, non-empty
     dir we didn't put there) → leave alone and log a warning.**
   The tool never deletes things it didn't create.
10. **Reload Samba**: `smbcontrol smbd reload-config`. This is
    sufficient for adding a share section in modern Samba.
    `systemctl reload samba-ad-dc` is reserved for `[global]`
    edits.

## 7. Adversarial input handling

`dfs-update` runs as root and creates filesystem entries from
AD-sourced data. AD content is **not** trusted blindly — a
compromised domain admin or replication poisoning could otherwise
turn this into root-FS write-anywhere.

Validation rules applied to every parsed `msDFS-LinkPathv2`. Real
values from AD have a leading `/` and use `/` as the separator
(e.g. `/Reports`, `/Quarterly Reports (FY26)`):

- Reject empty input or any control char (`< 0x20`).
- Require a leading `/`. The validator strips it and treats the
  rest as a relative POSIX path.
- Reject if the value contains `\` anywhere — Windows uses
  backslash on the wire but stores forward slash in this
  attribute. A backslash is either a malformed entry (raw-LDAP
  injection) or a traversal attempt; reject either way.
- Reject if any path component is empty, `.`, or `..`.
- Reject if any component contains an NTFS-reserved character
  (`\`, `/`, `:`, `*`, `?`, `"`, `<`, `>`, `|`).
- After joining against the namespace root, `realpath -m` must
  remain a strict descendant of `/srv/samba/dfs_root/<NS>/`. This
  check runs *before* `mkdir -p` so a validator regression can't
  create directories outside the namespace root before being told
  no.
- Length cap of 200 chars on the relative path.

Validation rules applied to every parsed target UNC. Implemented
with bash string ops (not a single regex — escaping `[`, `]`, and
the structural backslashes inside `[[ =~ ]]` is fragile):

- Must start with `\\` followed by a server name and exactly one
  share component separated by a single `\`.
- Server: 1–63 chars, letters/digits/dot/underscore/dash.
- Share: 1–80 chars, letters/digits/dot/underscore/dollar/space/
  ampersand/parens/dash. Real share names commonly carry these.
- No commas (would corrupt the comma-joined symlink target list).
- No additional backslashes beyond the two structural ones.

Per-namespace and per-link validation failures are logged and
**skipped**, not fatal. A single malformed link doesn't take down
the whole update.

This pairs with the "test inputs should be adversarial" project
value: scenario tests for this feature must include link names
that collide with NSS, contain spaces, parentheses, dollar signs,
single-word link names, and at least one deliberately malformed
entry that the validator must reject without aborting the run.

## 8. systemd unit/timer

Service: `/etc/systemd/system/samba-dfs-update.service`

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-sconfig dfs-update
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

# Hardening — the tool needs to write under one tree and read sam.ldb.
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes
ReadWritePaths=/srv/samba/dfs_root /run /var/log/samba
ReadOnlyPaths=/var/lib/samba
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=yes
MemoryDenyWriteExecute=yes
```

Timer: `/etc/systemd/system/samba-dfs-update.timer`

```ini
[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
RandomizedDelaySec=2min
Persistent=true
Unit=samba-dfs-update.service

[Install]
WantedBy=timers.target
```

Default cadence is 30 minutes, not 5. DFS-N config changes slowly;
five-minute polling is operator overhead with no benefit.
`Persistent=true` catches missed runs after VM downtime.
`RandomizedDelaySec` matters once a second appliance is in play.

`dfs-schedule` writes both files, runs `daemon-reload`, enables and
starts the timer. `--interval` and `--namespaces` flags rewrite the
files in place; idempotent on repeat.

## 9. samba-sconfig integration

DFS-N is part of the existing two-script appliance pattern, not a
third top-level script.

**Helpers** (private; underscore prefix per convention):
`_dfs_get_base_dn`, `_dfs_normalize_link_path`,
`_dfs_validate_target_unc`, `_dfs_unwrap_ldif`, `_dfs_render_targets`,
`_dfs_order_targets`, `_dfs_write_symlink`, `_dfs_prune`,
`_dfs_write_drop_in`, `_dfs_remove_drop_in`, `_dfs_install_units`,
`_dfs_remove_units`, `_dfs_run_update`, `_dfs_update_one_namespace`,
`_dfs_apply_one_link`.

**Headless CLI** (each subcommand also takes `--help` via the
top-level usage):

| Subcommand | Inputs | Effect |
| --- | --- | --- |
| `dfs-init` | `SC_DFS_ROOT`, `SC_DFS_SHARE` (env) | Writes `/etc/samba/conf.d/dfs-root.conf`, inserts `include = …` into `[global]`, drops the global sentinel. Reload-config. |
| `dfs-configure NS [NS…]` | positional namespaces, `SC_DFS_PREFER` (env) | Writes `/etc/samba/dfs-update.conf`, creates per-NS dirs and per-NS sentinels. |
| `dfs-update` | `SC_DFS_DRY_RUN=1` (optional) | One sync pass over every configured namespace. |
| `dfs-schedule` | `SC_DFS_INTERVAL` (env) | Writes/enables the systemd timer + service. |
| `dfs-status` | — | Drop-in present? Config? Timer state? Last log lines? Managed symlinks? |
| `dfs-remove` | — | Removes drop-in, units, config; leaves filesystem alone. |

**TUI** (under main-menu item *DFS Namespace Server*) is at full
parity with the CLI. Each menu item delegates to a `cli_*` or
`_dfs_*` helper rather than reimplementing logic, so validation
rules (e.g. namespace-name regex, absolute-path check) are shared.
Items:

| # | Title | Calls |
| --- | --- | --- |
| 1 | Initialize namespace server (one-time) | `cli_dfs_init_inner` |
| 2 | Configure namespaces and prefer-list | `cli_dfs_configure` |
| 3 | Run sync now (dry-run) | `_dfs_run_update` with `SC_DFS_DRY_RUN=1` |
| 4 | Run sync now | `_dfs_run_update` |
| 5 | Schedule periodic sync | `cli_dfs_schedule_inner` |
| 6 | Pause / resume timer | `systemctl start/stop` |
| 7 | Show DFS-N status | `cli_dfs_status` |
| 8 | Remove DFS-N configuration | `cli_dfs_remove` |

The TUI also surfaces feedback the CLI doesn't: a verdict line on
sync runs (`OK (rc=0)` / `FAILED (rc=N)`), per-prompt validation
messages, and a header line on the menu showing
*State / Timer / Namespaces*. Pause/resume keeps the operator from
having to drop to a shell to toggle the timer for ad-hoc work.

**Image-prep delta**: `prepare-image.sh` installs
`/usr/local/sbin/samba-dfs-parse-targets` (Python, stdlib only)
and runs a self-test against a captured WS2025 blob. No new
packages — `python3-samba`, `ldb-tools`, and `flock` come with
the existing `samba-ad-dc` install.

## 10. Test plan

Scenario: `lab/scenarios/dfs-namespace.sh`. Validated end-to-end
against the live lab; the steps below describe what currently runs.

**pre_hook** (Windows-side setup via `Setup-DfsnTestNamespace.ps1`):

- Install `FS-DFS-Namespace` + `RSAT-DFS-Mgmt-Con` features (idempotent).
- Create `\\lab.test\Public` (DomainV2 mode).
- Create four folder links covering adversarial-input cases:
  - `Reports` — well-behaved baseline.
  - `Quarterly Reports (FY26)` — spaces, parens.
  - `IT$Tools` — dollar (NSS-collision adjacent).
  - `one` — single-word link.
- For each folder, attach three targets at distinct priority
  classes (primary `\\WIN-PRIMARY\Public` and secondary
  `\\WIN-SECONDARY\Public` at `SiteCostNormal`; fallback
  `\\synology-fb\Public-RO` at `GlobalLow`).
- Best-effort: inject a malformed link path `..\..\evil` via raw
  LDAP. WS2025's schema rejects this minimum-attribute object;
  the scenario tolerates that and continues. See §11.

**run_scenario**:

1. Bootstrap-install the parser helper from `/tmp/prepare-image.sh`
   if absent (handles golden images that predate DFS-N).
2. `samba-sconfig join-dc` to get this DC into the forest.
3. Wait for `msDFS-Linkv2` objects to appear in the local
   `sam.ldb` after replication.
4. `samba-sconfig dfs-init`, `dfs-configure Public` (with prefer
   regex `^\\WIN-`), `dfs-update`.
5. **Convergence**: `Modify-DfsnTestNamespace.ps1` adds
   `\\lab.test\Public\NewFolder` and removes `\\lab.test\Public\one`,
   then `dfs-update` runs again. This is the timer's reason for
   existing — without it the static state can't tell "wrote the
   right thing once" from "actually adapts to changes."

**verify** (each check returns 0/1, all aggregated):

- Drop-in file present and `include = …` in `[global]`.
- testparm parses `[dfs_root]` with `msdfs root = Yes`.
- All four post-convergence symlinks present with the
  primary-secondary-fallback target order.
- `one` is pruned after AD removed it.
- No `evil*` entry on disk.
- Sentinel guard: removing `.dfsn-managed` makes `dfs-update`
  exit 2 without filesystem changes.
- Empty-result guard: pointing at `NoSuchNamespace` does not
  prune existing symlinks (count before == count after).
- Timer is `active` after `dfs-schedule`.

**post_hook**: stop the timer so re-runs start from a clean slate.

Per project rule: this scenario was created in the same commit
range as the implementation, including the adversarial inputs and
the convergence step. Bug-fix commits later carry their own
regression tests.

## 11. Open questions / followups

- **Multi-namespace support**: first cut handles N namespaces by
  config; cross-namespace conflicts (two namespaces wanting the
  same share name) fail loudly at init.
- **TTL handling**: `msDFS-Ttlv2` per link could feed
  `dfs:referral_ttl` style hints, but Samba doesn't expose a
  per-symlink TTL knob; the namespace-wide TTL is what the client
  sees. Document, don't implement.
- **Site-aware referrals**: out of scope. If the operator needs
  this Samba DC to never win in-site against a Windows primary,
  AD site placement is the lever, not symlink ordering.
- **End-to-end coverage of validator rejection of malformed AD
  links is shallower than ideal.** WS2025's schema enforces that
  every `msDFS-Linkv2` object carries
  `msDFS-NamespaceIdentityGUIDv2`, `msDFS-LinkIdentityGUIDv2`,
  `msDFS-LinkSecurityDescriptorv2`, and friends. The lab's raw-LDAP
  injection (`Setup-DfsnTestNamespace.ps1` step 5) tries to mint a
  minimum-attribute object and AD rejects it before our Linux
  validator ever sees it. The scenario's "no `evil*` on disk"
  check therefore passes trivially. The path-validator and
  UNC-validator logic is exercised against 22 adversarial inputs
  by a local unit harness during development; promoting that to a
  proper end-to-end injection requires teaching the setup script
  to mint a fully-attributed bad link.

## 12. Out of scope

- DFSR / content replication (Samba doesn't implement it).
- Standalone (non-domain-based) namespaces.
- v1 / "Windows 2000 server mode" namespaces.
- Hosting the namespace metadata authoritatively from Samba (i.e.
  this Samba DC creating namespaces). The Windows DCs own the
  DFS-N configuration; this appliance is a passive replica.
- Site-cost manipulation. Read the sentence above twice.
- Cross-forest namespaces.
