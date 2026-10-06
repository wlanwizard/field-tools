<#
.SYNOPSIS
    Quick host snapshot - current IP, Ethernet/Wi-Fi MAC with adapter model and driver, OS, uptime, interfaces, DNS servers in use, optional routes

.DESCRIPTION
    Windows version of 003-host-snapshot.lm.sh. Read-only and runs without
    admin rights. Starts with the current IP address and the Ethernet and
    Wi-Fi MAC addresses, each with the adapter model (e.g. Intel Wi-Fi 6E
    AX211, Intel I219-LM) and driver version and date. The DNS section lists
    only the servers in use: connected interfaces, IPv4 and IPv6, with the
    default-gateway interface first. The routing table is only shown with -Routes.

    Uses the built-in NetTCPIP / DnsClient cmdlets (Windows 8 / Server 2012
    and newer) and falls back to ipconfig and route print on older systems.
    A section that fails prints why and the rest still run.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\003-host-snapshot.w.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\003-host-snapshot.w.ps1 -Out

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\003-host-snapshot.w.ps1 -Routes

.NOTES
    Category: sys
    Requires: Windows PowerShell 5.1+ (no extra modules)
#>
[CmdletBinding()]
param(
    [Alias('o')][switch]$Out,   # also save the snapshot to .\output\ (alias needed: -OutVariable/-OutBuffer make -o ambiguous)
    [switch]$Routes,   # include the IPv4 routing table (long, so off by default)
    [switch]$Version   # print the version and exit
)

$ToolVersion = '1.0.0'   # bump on every change: MAJOR.MINOR.PATCH (see CLAUDE.md)
$ToolName    = Split-Path -Leaf $PSCommandPath
if ($Version) { "$ToolName v$ToolVersion"; return }
Write-Host "$ToolName v$ToolVersion"   # host stream, so pipeline output stays clean

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
    Section 'IP AND MAC' {
        function Row([string]$Label, $Values) {
            $Values = @($Values | Where-Object { $_ })
            if (-not $Values) { $Values = @('(none found)') }
            '{0,-13}: {1}' -f $Label, $Values[0]
            $Values | Select-Object -Skip 1 | ForEach-Object { '{0,-13}  {1}' -f '', $_ }
        }
        if ($Modern) {
            # Connected IPv4 addresses; the interface with a default gateway is the one in use
            $ips = Get-NetIPConfiguration |
                Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address } |
                Sort-Object { -not $_.IPv4DefaultGateway }, InterfaceAlias |
                ForEach-Object {
                    $cfg = $_
                    $gw = @($cfg.IPv4DefaultGateway.NextHop) | Where-Object { $_ } | Select-Object -First 1
                    foreach ($a in $cfg.IPv4Address) {
                        '{0}/{1} on {2}{3}' -f $a.IPAddress, $a.PrefixLength, $cfg.InterfaceAlias,
                            $(if ($gw) { " (gateway $gw)" } else { '' })
                    }
                }
            # Physical adapters only, so VPN / Hyper-V / virtual NICs don't show up. Wi-Fi shows
            # the MAC in use, which is a random one if "random hardware addresses" is on.
            # InterfaceDescription is the driver's model name, e.g. "Intel(R) Wi-Fi 6E AX211 160MHz".
            # Driver version/date come first in most Wi-Fi troubleshooting, so show them too.
            $nics = Get-NetAdapter -Physical | Sort-Object Name
            $mac  = { param($n)
                '{0}  {1} ({2})' -f $n.MacAddress, $n.Name, $n.Status
                '  {0}  driver {1}{2}' -f $n.InterfaceDescription, $n.DriverVersion,
                    $(if ($n.DriverDate) { " ($($n.DriverDate))" } else { '' })
            }
            Row 'Current IP'   $ips
            Row 'Ethernet MAC' ($nics | Where-Object { $_.PhysicalMediaType -eq '802.3' } | ForEach-Object { & $mac $_ })
            Row 'Wi-Fi MAC'    ($nics | Where-Object { $_.PhysicalMediaType -eq 'Native 802.11' } | ForEach-Object { & $mac $_ })
        } else {
            Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' | ForEach-Object {
                Row $_.Description @("IP  $($_.IPAddress -join ', ')", "MAC $($_.MACAddress)")
            }
        }
    }

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

    if ($Routes) {
        Section 'ROUTES' {
            if ($Modern) {
                Get-NetRoute -AddressFamily IPv4 | Sort-Object DestinationPrefix |
                    Format-Table DestinationPrefix, NextHop, RouteMetric, InterfaceAlias -AutoSize
            } else {
                route print -4
            }
        }
    } else {
        "`n(routing table hidden - add -Routes to show it)"
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
    @("$ToolName v$ToolVersion") + $report | Set-Content -Path $path -Encoding UTF8
    Write-Host "[+] saved $path"
}
