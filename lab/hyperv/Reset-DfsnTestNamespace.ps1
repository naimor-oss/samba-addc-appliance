<#
.SYNOPSIS
    Tear down the DFS-N test namespace on WS2025-DC1.

.DESCRIPTION
    Companion to Setup-DfsnTestNamespace.ps1. Idempotent. Removes:

      1. The malformed CN=evil-test-link link object (raw LDAP).
      2. All folders under the namespace.
      3. All root targets, then the namespace itself.
      4. The local C:\DFSRoots\<NamespaceName> SMB share + path.

    Leaves SYSVOL, GPOs, computer accounts, and the Lab OU alone. Safe
    to run when nothing exists — exits 0 with a "nothing to remove" line.

.PARAMETER VMName
    Hyper-V VM name. Default 'WS2025-DC1'.
.PARAMETER NamespaceName
    Namespace short name. Default 'Public'.
.PARAMETER Realm
    AD realm DNS root. Default 'lab.test'.
.PARAMETER DryRun
    Print intended actions without applying them.

.EXAMPLE
    pwsh -File D:\ISO\lab-scripts\Reset-DfsnTestNamespace.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$VMName        = 'WS2025-DC1',
    [string]$NamespaceName = 'Public',
    [string]$Realm         = 'lab.test',
    [string]$Username      = 'LAB\Administrator',
    [string]$PasswordPlain = 'P@ssword123456!',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$cred = New-Object PSCredential(
    $Username,
    (ConvertTo-SecureString $PasswordPlain -AsPlainText -Force))

$inside = {
    param([string]$NamespaceName, [string]$Realm, [bool]$DryRun)

    $ErrorActionPreference = 'Continue'

    Import-Module DFSN, ActiveDirectory -ErrorAction SilentlyContinue
    $nsPath = "\\$Realm\$NamespaceName"
    $report = New-Object System.Collections.Generic.List[string]
    function Note($s) { $report.Add($s) }

    # 1. Remove the malformed link object (created via raw LDAP). This must
    #    happen before namespace removal because Remove-DfsnRoot won't touch
    #    objects DFS Management doesn't recognize as well-formed.
    try {
        $domainNc = (Get-ADRootDSE).defaultNamingContext
        # Link container DN under v2 namespaces: doubled namespace
        # component, "Dfs-Configuration" (no "n"). See setup script.
        $nsDn     = "CN=$NamespaceName,CN=$NamespaceName,CN=Dfs-Configuration,CN=System,$domainNc"
        $bad      = Get-ADObject -Identity "CN=evil-test-link,$nsDn" -ErrorAction SilentlyContinue
        if ($bad) {
            Note "Remove malformed link: $($bad.DistinguishedName)"
            if (-not $DryRun) {
                Remove-ADObject -Identity $bad.DistinguishedName -Recursive -Confirm:$false
            }
        }
    } catch { Note "WARN malformed-link cleanup: $($_.Exception.Message)" }

    # 2. Folders under the namespace.
    if (Get-DfsnRoot -Path $nsPath -ErrorAction SilentlyContinue) {
        try {
            Get-DfsnFolder -Path "$nsPath\*" -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Note "Remove folder: $($_.Path)"
                    if (-not $DryRun) {
                        Remove-DfsnFolder -Path $_.Path -Force -Confirm:$false
                    }
                }
        } catch { Note "WARN folder cleanup: $($_.Exception.Message)" }

        # 3. Remove the namespace. Remove-DfsnRoot cascades to root
        #    targets — explicitly removing them first leaves the
        #    namespace in a degraded state where Remove-DfsnRoot can no
        #    longer enumerate its members and fails.
        try {
            Note "Remove namespace: $nsPath (cascades to root targets)"
            if (-not $DryRun) {
                Remove-DfsnRoot -Path $nsPath -Force -Confirm:$false
            }
        } catch { Note "WARN namespace cleanup: $($_.Exception.Message)" }
    } else {
        Note "Namespace $nsPath not present"
    }

    # 4. Local SMB share + filesystem path.
    if (Get-SmbShare -Name $NamespaceName -ErrorAction SilentlyContinue) {
        Note "Remove SMB share: $NamespaceName"
        if (-not $DryRun) {
            Remove-SmbShare -Name $NamespaceName -Force -Confirm:$false `
                -ErrorAction SilentlyContinue
        }
    }
    $local = "C:\DFSRoots\$NamespaceName"
    if (Test-Path $local) {
        Note "Remove local path: $local"
        if (-not $DryRun) {
            Remove-Item -Recurse -Force $local -ErrorAction SilentlyContinue
        }
    }

    if ($report.Count -eq 0) {
        "Reset-DfsnTestNamespace: nothing to clean ($nsPath)"
    } else {
        $mode = if ($DryRun) { 'DRY-RUN' } else { 'applied' }
        "Reset-DfsnTestNamespace ($mode) — $($report.Count) item(s):"
        $report | ForEach-Object { "  $_" }
    }
}

Invoke-Command -VMName $VMName -Credential $cred `
    -ArgumentList $NamespaceName, $Realm, ([bool]$DryRun) `
    -ScriptBlock $inside
