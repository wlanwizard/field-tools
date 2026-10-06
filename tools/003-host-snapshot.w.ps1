<#
.SYNOPSIS
    Quick host snapshot - OS, uptime, interfaces, routes, DNS, listening ports

.DESCRIPTION
    Windows twin of 003-host-snapshot.lm.sh, with the same sections. Read-only
    and runs without admin rights (without admin, some listening ports may
    show no process name).

    Uses the built-in NetTCPIP / DnsClient cmdlets (Windows 8 / Server 2012
    and newer) and falls back to ipconfig, route print and netstat on older
    systems. A section that fails prints why and the rest still run.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\003-host-snapshot.w.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\003-host-snapshot.w.ps1 -Out

.NOTES
    Category: sys
    Requires: Windows PowerShell 5.1+ (no extra modules)
#>
[CmdletBinding()]
param(
    [switch]$Out   # also save the snapshot to .\output\
)

$ErrorActionPreference = 'Stop'
$ToolId    = ((Split-Path -Leaf $PSCommandPath) -split '-')[0]
$OutputDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'output'
# NetTCPIP / DnsClient cmdlets are missing on Windows 7 / Server 2008 R2
$Modern    = [bool](Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)

function Section([string]$Title, [scriptblock]$Body) {
    "`n===== $Title ====="
    try {
        (& $Body | Out-String -Width 200).TrimEnd()
    } catch {
        "  (could not collect: $($_.Exception.Message))"
    }
}

$report = @(
    Section 'HOST' {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $up = (Get-Date) - $os.LastBootUpTime
        [pscustomobject]@{
            Hostname = $env:COMPUTERNAME
            Domain   = $(if ($cs.PartOfDomain) { $cs.Domain } else { "(workgroup: $($cs.Workgroup))" })
            Date     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
            LastBoot = $os.LastBootUpTime
            Uptime   = '{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes
        } | Format-List
    }

    Section 'OS' {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        [pscustomobject]@{
            OS           = $os.Caption
            Release      = $(if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId })
            Build        = '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR
            Architecture = $os.OSArchitecture
            InstallDate  = $os.InstallDate
            PowerShell   = $PSVersionTable.PSVersion.ToString()
        } | Format-List
    }

    Section 'INTERFACES' {
        if ($Modern) {
            Get-NetAdapter | Sort-Object ifIndex |
                Format-Table Name, InterfaceDescription, Status, LinkSpeed, MacAddress -AutoSize
            Get-NetIPAddress | Where-Object { $_.AddressState -ne 'Invalid' } |
                Sort-Object InterfaceIndex, AddressFamily |
                Format-Table InterfaceAlias, AddressFamily, IPAddress, PrefixLength, PrefixOrigin -AutoSize
        } else {
            ipconfig /all
        }
    }

    Section 'ROUTES' {
        if ($Modern) {
            Get-NetRoute -AddressFamily IPv4 | Sort-Object DestinationPrefix |
                Format-Table DestinationPrefix, NextHop, RouteMetric, InterfaceAlias -AutoSize
        } else {
            route print -4
        }
    }

    Section 'DNS' {
        if ($Modern) {
            Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } |
                Format-Table InterfaceAlias, @{ n = 'DnsServers'; e = { $_.ServerAddresses -join ', ' } } -AutoSize
            'Search suffixes: ' + ((Get-DnsClientGlobalSetting).SuffixSearchList -join ', ')
        } else {
            ipconfig /all | Select-String 'DNS'
        }
    }

    Section 'LISTENING TCP' {
        if ($Modern) {
            $procs = @{}
            Get-Process | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
            Get-NetTCPConnection -State Listen | Sort-Object LocalPort, LocalAddress |
                Format-Table LocalAddress, LocalPort, OwningProcess,
                    @{ n = 'Process'; e = { $procs[[int]$_.OwningProcess] } } -AutoSize
        } else {
            netstat -ano | Select-String 'LISTENING'
        }
    }
)

$report

if ($Out) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $path = Join-Path $OutputDir ("{0}_{1}_{2}.txt" -f $ToolId, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $report | Set-Content -Path $path -Encoding UTF8
    Write-Host "[+] saved $path"
}
