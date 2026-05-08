<#
.SYNOPSIS
    Apply a small AD-state delta to the DFS-N test namespace, used by the
    dfs-namespace scenario's convergence step.

.DESCRIPTION
    Companion to Setup-DfsnTestNamespace.ps1. Idempotently:

      - Adds folder `<NamespaceName>\AddFolder` (default 'NewFolder')
        with a single primary target.
      - Removes folder `<NamespaceName>\RemoveFolder` (default 'one')
        if present.

    The scenario then re-runs `samba-sconfig dfs-update` and verifies
    that the appliance materialized the addition and pruned the
    removal — i.e. the timer's reason for existing actually works.

.EXAMPLE
    pwsh -File D:\ISO\lab-scripts\Modify-DfsnTestNamespace.ps1
#>
[CmdletBinding()]
param(
    [string]$VMName        = 'WS2025-DC1',
    [string]$NamespaceName = 'Public',
    [string]$Realm         = 'lab.test',
    [string]$AddFolder     = 'NewFolder',
    [string]$RemoveFolder  = 'one',
    [string]$PrimaryUNC    = '\\WIN-PRIMARY\Public',
    [string]$Username      = 'LAB\Administrator',
    [string]$PasswordPlain = 'P@ssword123456!'
)

$ErrorActionPreference = 'Stop'

$cred = New-Object PSCredential(
    $Username,
    (ConvertTo-SecureString $PasswordPlain -AsPlainText -Force))

$inside = {
    param([string]$NamespaceName, [string]$Realm,
          [string]$AddFolder, [string]$RemoveFolder, [string]$PrimaryUNC)

    $ErrorActionPreference = 'Continue'
    Import-Module DFSN -ErrorAction Stop

    $nsPath  = "\\$Realm\$NamespaceName"
    $addPath = "$nsPath\$AddFolder"
    $rmPath  = "$nsPath\$RemoveFolder"

    if (-not (Get-DfsnFolder -Path $addPath -ErrorAction SilentlyContinue)) {
        Write-Host "[modify-dfsn] add folder $addPath -> $PrimaryUNC"
        try {
            New-DfsnFolder -Path $addPath -TargetPath $PrimaryUNC `
                -EnableTargetFailback $true -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "[modify-dfsn] WARN add failed: $($_.Exception.Message)"
        }
    } else {
        Write-Host "[modify-dfsn] already present: $addPath"
    }

    if (Get-DfsnFolder -Path $rmPath -ErrorAction SilentlyContinue) {
        Write-Host "[modify-dfsn] remove folder $rmPath"
        try {
            Remove-DfsnFolder -Path $rmPath -Force -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Host "[modify-dfsn] WARN remove failed: $($_.Exception.Message)"
        }
    } else {
        Write-Host "[modify-dfsn] already absent: $rmPath"
    }
}

Invoke-Command -VMName $VMName -Credential $cred `
    -ArgumentList $NamespaceName, $Realm, $AddFolder, $RemoveFolder, $PrimaryUNC `
    -ScriptBlock $inside
