<#
.SYNOPSIS
    Remove transient samba-* DC artifacts from the lab AD on WS2025-DC1.

.DESCRIPTION
    Runs on the Hyper-V host. Uses PSDirect to invoke a cleanup script inside
    WS2025-DC1 that narrowly removes objects matching -Pattern (default
    'samba-*'):

      1. CN=Sites\*\Servers\<Pattern>       (NTDSA + child nTDSDSA)
      2. Get-ADComputer -Filter Name-like-<Pattern>
      3. Forward-zone A records (HostName -like Pattern)
      4. SRV records whose target is <Pattern>.<DomainDns>[.]
         (checked in both the forward zone and _msdcs.<DomainDns>)
      5. Reverse-zone PTR records whose target is <Pattern>.<DomainDns>[.]
      6. repadmin /kcc on WS2025-DC1 (only when any removal happened)

    Does NOT touch:
      - WS2025-DC1 itself (pattern excludes it by design)
      - The Lab OU tree or any baseline GPO / its link
      - Any object whose name does not match -Pattern

    Safe to re-run. Prints a table of what was removed (or would be, under
    -DryRun). Exits non-zero only on hard PSRemoting / module failures; a
    clean "nothing to remove" run still exits 0.

.PARAMETER VMName
    Hyper-V VM name of the WS2025 DC to clean up. Default 'WS2025-DC1'.
.PARAMETER Pattern
    Wildcard pattern to match. Default 'samba-*'. Matched as-is against
    object Name (AD), HostName (DNS), and SRV DomainName (with/without
    trailing dot). Use -Pattern 'samba-dc1' for a single host.
.PARAMETER Username
    Domain admin credential. Default 'LAB\Administrator'.
.PARAMETER PasswordPlain
    Password for -Username. Default is the lab-only password in CLAUDE.md.
.PARAMETER DryRun
    Print findings without removing anything.

.EXAMPLE
    pwsh -File D:\ISO\lab-scripts\Reset-LabDomainState.ps1
.EXAMPLE
    pwsh -File D:\ISO\lab-scripts\Reset-LabDomainState.ps1 -DryRun
.EXAMPLE
    pwsh -File D:\ISO\lab-scripts\Reset-LabDomainState.ps1 -Pattern 'samba-dc1'
#>
[CmdletBinding()]
param(
    [string]$VMName        = 'WS2025-DC1',
    [string]$Pattern       = 'samba-*',
    [string]$Username      = 'LAB\Administrator',
    [string]$PasswordPlain = 'P@ssword123456!',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$cred = New-Object PSCredential(
    $Username,
    (ConvertTo-SecureString $PasswordPlain -AsPlainText -Force))

$inside = {
    param([string]$Pattern, [bool]$DryRun)

    $ErrorActionPreference = 'Continue'

    foreach ($m in @('ActiveDirectory','DnsServer')) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            throw "Module $m not available on $env:COMPUTERNAME. Install RSAT feature."
        }
        Import-Module $m -ErrorAction Stop | Out-Null
    }

    $report = New-Object System.Collections.Generic.List[object]
    function Note($cat, $what, $act = '-') {
        $report.Add([PSCustomObject]@{Category = $cat; Detail = $what; Action = $act})
    }

    $confRoot  = (Get-ADRootDSE).configurationNamingContext
    $domainDns = (Get-ADDomain).DNSRoot
    $targetA   = "$Pattern.$domainDns"
    $targetB   = "$targetA."

    # 1. Sites\Servers\<pattern> — remove NTDSA + server objects recursively.
    Get-ADObject -SearchBase "CN=Sites,$confRoot" -Filter 'objectClass -eq "server"' |
        Where-Object { $_.Name -like $Pattern } |
        ForEach-Object {
            Note 'Site-Server' $_.DistinguishedName 'remove'
            if (-not $DryRun) {
                try { Remove-ADObject -Identity $_ -Recursive -Confirm:$false }
                catch { Note 'Site-Server' $_.Exception.Message 'err' }
            }
        }

    # 2. Computer accounts (Domain Controllers OU or Computers container).
    Get-ADComputer -Filter "Name -like '$Pattern'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Note 'Computer' $_.DistinguishedName 'remove'
            if (-not $DryRun) {
                try { Remove-ADObject -Identity $_.DistinguishedName -Recursive -Confirm:$false }
                catch { Note 'Computer' $_.Exception.Message 'err' }
            }
        }

    # 3. Forward-zone A records matching pattern hostname.
    Get-DnsServerResourceRecord -ZoneName $domainDns -RRType A -ErrorAction SilentlyContinue |
        Where-Object { $_.HostName -like $Pattern } |
        ForEach-Object {
            Note 'DNS-A' "$($_.HostName).$domainDns -> $($_.RecordData.IPv4Address)" 'remove'
            if (-not $DryRun) {
                try {
                    Remove-DnsServerResourceRecord -ZoneName $domainDns -InputObject $_ `
                        -Force -ErrorAction Stop
                } catch {
                    Note 'DNS-A' $_.Exception.Message 'warn'
                }
            }
        }

    # 4. SRV records pointing at our pattern FQDN, in the domain zone and
    # the _msdcs.<domain> partition. The DomainName field may or may not
    # carry a trailing dot depending on how it was published, so match both.
    foreach ($zone in @($domainDns, "_msdcs.$domainDns")) {
        if (-not (Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue)) { continue }
        Get-DnsServerResourceRecord -ZoneName $zone -RRType SRV -ErrorAction SilentlyContinue |
            Where-Object {
                $t = $_.RecordData.DomainName
                ($t -like $targetA) -or ($t -like $targetB)
            } |
            ForEach-Object {
                Note 'DNS-SRV' "$($_.HostName) in $zone -> $($_.RecordData.DomainName)" 'remove'
                if (-not $DryRun) {
                    try {
                        Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $_ `
                            -Force -ErrorAction Stop
                    } catch {
                        Note 'DNS-SRV' $_.Exception.Message 'warn'
                    }
                }
            }
    }

    # 5. Reverse-zone PTRs pointing at our pattern FQDN.
    Get-DnsServerZone |
        Where-Object { $_.ZoneName -like '*.in-addr.arpa' -and -not $_.IsAutoCreated } |
        ForEach-Object {
            $zone = $_.ZoneName
            Get-DnsServerResourceRecord -ZoneName $zone -RRType PTR -ErrorAction SilentlyContinue |
                Where-Object {
                    $t = $_.RecordData.PtrDomainName
                    ($t -like $targetA) -or ($t -like $targetB)
                } |
                ForEach-Object {
                    Note 'DNS-PTR' "$($_.HostName).$zone -> $($_.RecordData.PtrDomainName)" 'remove'
                    if (-not $DryRun) {
                        try {
                            Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $_ `
                                -Force -ErrorAction Stop
                        } catch {
                            Note 'DNS-PTR' $_.Exception.Message 'warn'
                        }
                    }
                }
        }

    # 6. Trigger KCC once the topology has actually changed.
    if (-not $DryRun -and $report.Count -gt 0) {
        try {
            $null = repadmin /kcc $env:COMPUTERNAME 2>&1
            Note 'KCC' "forced on $env:COMPUTERNAME" 'done'
        } catch {
            Note 'KCC' $_.Exception.Message 'warn'
        }
    }

    if ($report.Count -eq 0) {
        "Reset-LabDomainState: nothing to clean (pattern='$Pattern')."
    } else {
        $mode = if ($DryRun) { 'DRY-RUN' } else { 'applied' }
        "Reset-LabDomainState ($mode) — $($report.Count) item(s):"
        $report | Format-Table -AutoSize | Out-String
    }
}

Invoke-Command -VMName $VMName -Credential $cred `
    -ArgumentList $Pattern, ([bool]$DryRun) -ScriptBlock $inside
