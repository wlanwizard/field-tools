<#
.SYNOPSIS
    Quick host snapshot - OS, uptime, interfaces, routes, DNS servers in use

.DESCRIPTION
    Windows version of 003-host-snapshot.lm.sh. Read-only and runs without
    admin rights. The DNS section lists only the servers in use: connected
    interfaces, IPv4 and IPv6, with the default-gateway interface first.

    Uses the built-in NetTCPIP / DnsClient cmdlets (Windows 8 / Server 2012
    and newer) and falls back to ipconfig and route print on older systems.
    A section that fails prints why and the rest still run.

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

    Section 'DNS SERVERS IN USE' {
        if ($Modern) {
            # Connected interfaces only. Windows puts fec0:0:0:ffff::1-3 on adapters with
            # no IPv6 DNS configured; those are placeholders, not real servers.
            $inUse = Get-NetIPConfiguration |
                Where-Object { $_.NetAdapter.Status -eq 'Up' } |
                ForEach-Object {
                    $cfg = $_
                    $servers = @($cfg.DNSServer.ServerAddresses |
                        Where-Object { $_ -notlike 'fec0:0:0:ffff::*' } | Select-Object -Unique)
                    if ($servers) {
                        [pscustomobject]@{
                            Interface      = $cfg.InterfaceAlias
                            DefaultGateway = (@($cfg.IPv4DefaultGateway.NextHop) + @($cfg.IPv6DefaultGateway.NextHop) |
                                                Where-Object { $_ } | Select-Object -Unique) -join ', '
                            DnsServers     = $servers -join ', '
                        }
                    }
                }
            if ($inUse) {
                # Normal lookups follow the default route, so that interface goes first
                $inUse | Sort-Object { -not $_.DefaultGateway }, Interface | Format-Table -AutoSize -Wrap
            } else {
                '  (no connected interface has DNS servers configured)'
            }
            'Search suffixes: ' + ((Get-DnsClientGlobalSetting).SuffixSearchList -join ', ')
        } else {
            ipconfig /all | Select-String 'DNS'
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
