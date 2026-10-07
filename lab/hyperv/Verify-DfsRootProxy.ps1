#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Verify a Samba DC's automatic domain DFS root proxy from Windows.

.DESCRIPTION
    Uses PowerShell Direct to run the client checks inside WS2025-DC1. It
    flushes cached DFS referrals, opens the namespace directly through the
    Samba DC, then opens the normal domain path. The direct path proves the
    Samba share-level referral exists; the domain path proves ordinary client
    access remains usable.

.PARAMETER VMName
    Windows test VM. Default WS2025-DC1.
.PARAMETER SambaServer
    Samba DC FQDN or short name.
.PARAMETER Realm
    AD DNS realm.
.PARAMETER NamespaceName
    Domain DFS namespace root name.
.PARAMETER Username, PasswordPlain
    Lab-only PowerShell Direct credentials.
#>
[CmdletBinding()]
param(
    [string]$VMName        = 'WS2025-DC1',
    [Parameter(Mandatory)][string]$SambaServer,
    [string]$Realm         = 'lab.test',
    [string]$NamespaceName = 'Public',
    [string]$Username      = 'LAB\Administrator',
    [string]$PasswordPlain = 'P@ssword123456!'
)

$ErrorActionPreference = 'Stop'
$cred = New-Object PSCredential(
    $Username,
    (ConvertTo-SecureString $PasswordPlain -AsPlainText -Force))

$invokeArgs = @{
    VMName       = $VMName
    Credential   = $cred
    ArgumentList = @($SambaServer, $Realm, $NamespaceName)
    ScriptBlock  = {
        param($SambaServer, $Realm, $NamespaceName)
        $ErrorActionPreference = 'Stop'

        & dfsutil.exe /pktflush | Out-Null
        & dfsutil.exe /spcflush | Out-Null
        Clear-DnsClientCache

        $direct = "\\$SambaServer\$NamespaceName"
        $domain = "\\$Realm\$NamespaceName"
        $directOK = Test-Path -LiteralPath $direct
        $domainOK = Test-Path -LiteralPath $domain

        [pscustomobject]@{
            DirectPath = $direct
            DirectOK   = $directOK
            DomainPath = $domain
            DomainOK   = $domainOK
            PacketInfo = (& dfsutil.exe /pktinfo | Out-String).Trim()
        }
    }
}
$result = Invoke-Command @invokeArgs

$result | Format-List DirectPath, DirectOK, DomainPath, DomainOK
$result.PacketInfo

if (-not $result.DirectOK) {
    throw "Direct DFS root proxy failed through \\$SambaServer\$NamespaceName"
}
if (-not $result.DomainOK) {
    throw "Domain DFS path failed at \\$Realm\$NamespaceName"
}

Write-Host 'PASS: Samba direct proxy and domain DFS path are both accessible.' -ForegroundColor Green
