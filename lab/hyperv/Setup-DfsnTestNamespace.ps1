<#
.SYNOPSIS
    Provision a DFS-N test namespace on WS2025-DC1 with adversarial folder
    paths, used by the dfs-namespace lab scenario.

.DESCRIPTION
    Runs on the Hyper-V host. PSDirects into WS2025-DC1 and:

      1. Installs the FS-DFS-Namespace role + RSAT (no-op if present).
      2. Creates a domain-based v2 namespace '\\<realm>\<NamespaceName>'
         hosted on WS2025-DC1 (no-op if the namespace already exists).
      3. Adds the Samba DC under test as a low-priority root target
         (Add-DfsnRootTarget … -ReferralPriorityClass GlobalLow).
      4. Creates a baseline set of DFS folders with adversarial names —
         spaces, parentheses, dollar — each pointing to a synthetic
         server\share UNC. The targets do not need to actually exist on
         the network for namespace metadata to replicate; the scenario
         only verifies that Samba materializes the link symlinks
         correctly.
      5. Optionally injects a deliberately malformed msDFS-LinkPathv2
         value via raw LDAP under the namespace container, so the Linux
         validator has something to reject. Skipped if -SkipMalformed.
      6. Forces inbound replication on the Samba target (best-effort) so
         the link objects are visible without waiting for the next
         scheduled cycle.

    Idempotent. Re-running over an existing namespace updates folder
    targets in place; existing folders matching the baseline are not
    re-created.

    Does NOT touch SYSVOL, computer accounts, or the Lab OU. Safe to
    re-run alongside join-dc cleanup.

.PARAMETER VMName
    Hyper-V VM name of the WS2025 DC. Default 'WS2025-DC1'.
.PARAMETER NamespaceName
    DFS-N namespace short name. Default 'Public'. Must be a single
    AD-safe label (no slashes, no spaces, no dots).
.PARAMETER SambaTarget
    Optional UNC root target to register for the Samba DC, e.g.
    '\\samba-dc1.lab.test\dfs_root'. New-DfsnRootTarget validates the
    target's reachability, so this only succeeds AFTER the Samba DC is
    joined to the domain AND dfs-init has been run on it. The
    dfs-namespace lab scenario does not need this registration to
    exercise symlink materialization (link metadata replicates via
    the domain NC regardless), so the scenario omits it. Pass
    explicitly when integration-testing client referrals.
.PARAMETER PrimaryUNC, SecondaryUNC
    Synthetic primary and secondary Windows server\share targets to
    embed in each folder. They do not need to be reachable for the test.
    Defaults: '\\WIN-PRIMARY\Public' and '\\WIN-SECONDARY\Public'.
.PARAMETER FallbackUNC
    Synthetic Synology fallback target. Default '\\synology-fb\Public-RO'.
.PARAMETER SkipMalformed
    Skip the raw-LDAP injection of a malformed link path. Useful when
    debugging; the scenario verify() expects the malformed entry to be
    present and rejected.
.PARAMETER Realm
    AD realm DNS root. Default 'lab.test'.
.PARAMETER Username
    Domain admin credential. Default 'LAB\Administrator'.
.PARAMETER PasswordPlain
    Lab-only credential. Documented in CLAUDE.md.

.EXAMPLE
    pwsh -File D:\ISO\lab-scripts\Setup-DfsnTestNamespace.ps1 `
        -SambaTarget '\\samba-dc1\dfs_root'
#>
[CmdletBinding()]
param(
    [string]$VMName        = 'WS2025-DC1',
    [string]$NamespaceName = 'Public',
    [string]$SambaTarget   = '',
    [string]$PrimaryUNC    = '\\WIN-PRIMARY\Public',
    [string]$SecondaryUNC  = '\\WIN-SECONDARY\Public',
    [string]$FallbackUNC   = '\\synology-fb\Public-RO',
    [switch]$SkipMalformed,
    [string]$Realm         = 'lab.test',
    [string]$Username      = 'LAB\Administrator',
    [string]$PasswordPlain = 'P@ssword123456!'
)

$ErrorActionPreference = 'Stop'

$cred = New-Object PSCredential(
    $Username,
    (ConvertTo-SecureString $PasswordPlain -AsPlainText -Force))

$inside = {
    param(
        [string]$NamespaceName,
        [string]$SambaTarget,
        [string]$PrimaryUNC,
        [string]$SecondaryUNC,
        [string]$FallbackUNC,
        [bool]  $SkipMalformed,
        [string]$Realm
    )

    $ErrorActionPreference = 'Continue'

    function Step($s) { Write-Host "[setup-dfsn] $s" }
    function Warn($s) { Write-Host "[setup-dfsn] WARN $s" -ForegroundColor Yellow }

    # 1. Install role + RSAT.
    Step "Ensuring FS-DFS-Namespace role + RSAT-DFS-Mgmt-Con are present"
    foreach ($f in @('FS-DFS-Namespace','RSAT-DFS-Mgmt-Con')) {
        $st = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($st -and -not $st.Installed) {
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
        }
    }
    Import-Module DFSN, ActiveDirectory -ErrorAction Stop

    # 2. Create the namespace if missing. Domain-based v2 (2008 mode) is
    #    the default for Add-DfsnRoot -Type DomainV2 on WS2025.
    $nsPath = "\\$Realm\$NamespaceName"
    $localShare = "C:\DFSRoots\$NamespaceName"
    if (-not (Get-DfsnRoot -Path $nsPath -ErrorAction SilentlyContinue)) {
        Step "Creating namespace $nsPath (DomainV2)"
        New-Item -ItemType Directory -Path $localShare -Force | Out-Null
        if (-not (Get-SmbShare -Name $NamespaceName -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $NamespaceName -Path $localShare `
                         -FullAccess 'Everyone' | Out-Null
        }
        New-DfsnRoot -Path $nsPath `
                     -TargetPath "\\$env:COMPUTERNAME.$Realm\$NamespaceName" `
                     -Type DomainV2 -EnableSiteCosting $false | Out-Null
    } else {
        Step "Namespace $nsPath already exists"
    }

    # 3. Add the Samba DC as a low-priority root target. The cmdlet is
    #    New-DfsnRootTarget (not Add-* — folder targets use Add, root
    #    targets use New). GlobalLow keeps the Samba replica behind
    #    in-site Windows targets even when site costing isn't tight —
    #    this is the operator-visible mechanism that makes the
    #    appliance "tertiary".
    if ($SambaTarget) {
        $existingTargets = Get-DfsnRootTarget -Path $nsPath -ErrorAction SilentlyContinue
        if (-not ($existingTargets | Where-Object { $_.TargetPath -ieq $SambaTarget })) {
            Step "Adding $SambaTarget as GlobalLow root target"
            try {
                New-DfsnRootTarget -Path $nsPath -TargetPath $SambaTarget `
                    -ReferralPriorityClass GlobalLow -ErrorAction Stop | Out-Null
            } catch {
                Warn "New-DfsnRootTarget failed: $($_.Exception.Message)"
            }
        } else {
            Step "Samba root target already registered: $SambaTarget"
            Set-DfsnRootTarget -Path $nsPath -TargetPath $SambaTarget `
                -ReferralPriorityClass GlobalLow `
                -ErrorAction SilentlyContinue | Out-Null
        }
    } else {
        Step "Skipping Samba root-target registration (-SambaTarget not provided)"
    }

    # 4. Baseline folders. Names chosen for adversarial coverage:
    #    - 'Reports'                       : well-behaved
    #    - 'Quarterly Reports (FY26)'      : spaces + parens
    #    - 'IT$Tools'                      : dollar
    #    - 'one'                           : single-word link (NSS collision risk)
    $folders = @(
        @{ Name = 'Reports';                  Note = 'baseline' }
        @{ Name = 'Quarterly Reports (FY26)'; Note = 'spaces+parens' }
        @{ Name = 'IT$Tools';                 Note = 'dollar' }
        @{ Name = 'one';                      Note = 'single-word' }
    )
    foreach ($f in $folders) {
        $folderPath = "$nsPath\$($f.Name)"
        if (-not (Get-DfsnFolder -Path $folderPath -ErrorAction SilentlyContinue)) {
            Step "Creating folder $folderPath ($($f.Note))"
            New-DfsnFolder -Path $folderPath -TargetPath $PrimaryUNC `
                -EnableTargetFailback $true | Out-Null
        }
        # Ensure all three targets are present and ordered by priority.
        # Cmdlet is New-DfsnFolderTarget (not Add-*; both root and folder
        # additions use New-*, only the verbs differ from PowerShell's
        # usual "Add" convention).
        foreach ($pair in @(
            @{Unc = $PrimaryUNC;   Cls = 'SiteCostNormal'},
            @{Unc = $SecondaryUNC; Cls = 'SiteCostNormal'},
            @{Unc = $FallbackUNC;  Cls = 'GlobalLow'}
        )) {
            $tgts = Get-DfsnFolderTarget -Path $folderPath -ErrorAction SilentlyContinue
            $exists = $tgts | Where-Object { $_.TargetPath -ieq $pair.Unc }
            if (-not $exists) {
                try {
                    New-DfsnFolderTarget -Path $folderPath -TargetPath $pair.Unc `
                        -ReferralPriorityClass $pair.Cls -ErrorAction Stop | Out-Null
                } catch {
                    Warn "New-DfsnFolderTarget $folderPath -> $($pair.Unc) failed: $($_.Exception.Message)"
                }
            } else {
                Set-DfsnFolderTarget -Path $folderPath -TargetPath $pair.Unc `
                    -ReferralPriorityClass $pair.Cls -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    # 5. Inject a malformed link path via raw LDAP. DFS Management
    #    cmdlets refuse to create one with '..' in it, which is exactly
    #    the input we want the Linux validator to reject. We mint the
    #    object directly under the namespace container.
    #
    #    Best-effort: if the AD layout differs from the assumed v2 path,
    #    or the schema rejects the bare object, log and continue. The
    #    scenario's "no evil* entry" check still passes — it just doesn't
    #    actively prove the validator did its job.
    Step "Step 5: malformed-link injection"
    if (-not $SkipMalformed) {
        # Get-ADObject -Identity throws ADIdentityNotFoundException even
        # with -ErrorAction SilentlyContinue (cmdlet author marked it
        # terminating). Use -SearchBase + -LDAPFilter instead, which
        # honors SilentlyContinue and returns empty for "not found".
        try {
            $domainNc = (Get-ADRootDSE).defaultNamingContext
            $nsDn     = "CN=$NamespaceName,CN=$NamespaceName,CN=Dfs-Configuration,CN=System,$domainNc"
            $bad      = "..\..\evil"
            $cn       = 'evil-test-link'

            $existing = Get-ADObject -SearchBase $nsDn -SearchScope OneLevel `
                -LDAPFilter "(&(objectClass=msDFS-Linkv2)(cn=$cn))" `
                -ErrorAction SilentlyContinue
            if ($existing) {
                Step "Malformed link already present: $($existing.DistinguishedName)"
            } else {
                Step "Injecting malformed link path '$bad' (raw LDAP)"
                # New-ADObject reports a clear error if the parent is
                # missing; no need for a separate parent existence check.
                New-ADObject -Name $cn -Path $nsDn `
                    -Type 'msDFS-Linkv2' `
                    -OtherAttributes @{ 'msDFS-LinkPathv2' = $bad } `
                    -ErrorAction Stop
            }
        } catch {
            Warn "Malformed-link injection skipped: $($_.Exception.Message)"
        }
    } else {
        Step "Malformed-link injection skipped (-SkipMalformed)"
    }

    # 6. Print a brief summary the scenario can grep.
    Step '--- result ---'
    "Namespace: $nsPath"
    Get-DfsnRootTarget -Path $nsPath | Format-Table TargetPath, ReferralPriorityClass -AutoSize | Out-String
    Get-DfsnFolder -Path "$nsPath\*" |
        ForEach-Object { "Folder: $($_.Path)" }
}

Invoke-Command -VMName $VMName -Credential $cred `
    -ArgumentList $NamespaceName, $SambaTarget, $PrimaryUNC, $SecondaryUNC, $FallbackUNC, ([bool]$SkipMalformed), $Realm `
    -ScriptBlock $inside
