<#
.SYNOPSIS
    Ping one host continuously and log timestamped UP/DOWN changes with outage durations

.DESCRIPTION
    Sends one ICMP echo per interval (default 1 s) to a single host and prints a
    timestamped line every time it goes DOWN or comes back UP, with how long it
    was down. A live status line shows the current state, packet loss and the
    last round-trip time. Press Ctrl+C to stop; a summary of loss and outages is
    printed on the way out.

    The host is marked DOWN after -FailCount missed replies in a row (default 2),
    timestamped at the first missed reply, so a single dropped packet isn't
    counted as an outage. It is UP again on the first reply.

    Read-only, no admin rights needed. Uses the .NET Ping class, so it behaves
    the same in Windows PowerShell 5.1 and PowerShell 7, over IPv4 or IPv6.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\004-ping-monitor.w.ps1 192.0.2.1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\004-ping-monitor.w.ps1 host01.example.com -IntervalSec 5 -FailCount 3 -Out

.NOTES
    Category: net
    Requires: Windows PowerShell 5.1+ (no extra modules)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target,                                 # host name or IP to ping
    [ValidateRange(0.2, 3600.0)][double]$IntervalSec = 1,
    [ValidateRange(100, 60000)][int]$TimeoutMs = 1000,
    [ValidateRange(1, 1000)][int]$FailCount = 2,     # missed replies in a row before DOWN
    [Alias('o')][switch]$Out,   # also log events to .\output\ as CSV (alias needed: -OutVariable/-OutBuffer make -o ambiguous)
    [switch]$Version            # print the version and exit
)

$ToolVersion = '1.0.0'   # bump on every change: MAJOR.MINOR.PATCH (see CLAUDE.md)
$ToolName    = Split-Path -Leaf $PSCommandPath
if ($Version) { "$ToolName v$ToolVersion"; return }
Write-Host "$ToolName v$ToolVersion"   # host stream, so pipeline / CSV output stays clean

if (-not $Target) {
    Write-Host "Usage: .\$ToolName <host or IP> [-IntervalSec 1] [-TimeoutMs 1000] [-FailCount 2] [-Out]"
    Write-Host "       Get-Help .\$ToolName -Detailed   for more"
    exit 2
}

$ErrorActionPreference = 'Stop'
$ToolId    = ($ToolName -split '-')[0]
$OutputDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'output'

$csv = $null
if ($Out) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $csv = Join-Path $OutputDir ("{0}_{1}_{2}.csv" -f $ToolId, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Format-Duration([TimeSpan]$T) {
    '{0:00}:{1:00}:{2:00}' -f [Math]::Floor($T.TotalHours), $T.Minutes, $T.Seconds
}

$statusLen = 0   # length of the live status line, so events can blank it out first

function Write-Event([datetime]$When, [string]$State, [string]$Detail) {
    $color = @{ UP = 'Green'; DOWN = 'Red' }[$State]
    if (-not $color) { $color = 'Gray' }
    $stamp = $When.ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host ("`r" + (' ' * $statusLen) + "`r") -NoNewline
    Write-Host ('{0}  {1,-5}  {2}  {3}' -f $stamp, $State, $Target, $Detail) -ForegroundColor $color
    if ($csv) {
        # Appended per event, so the log survives Ctrl+C or a closed window
        [pscustomobject]@{ Time = $stamp; Target = $Target; State = $State; Detail = $Detail } |
            Export-Csv -Path $csv -Append -NoTypeInformation
    }
}

try {
    $resolved = ([System.Net.Dns]::GetHostAddresses($Target) | ForEach-Object { $_.IPAddressToString }) -join ', '
} catch {
    $resolved = 'does not resolve yet, will keep trying'
}

$ping       = New-Object System.Net.NetworkInformation.Ping
$state      = 'START'   # becomes UP or DOWN after the first check(s)
$stateSince = Get-Date
$started    = $stateSince
$missed = 0; $firstMiss = $null; $lastFail = ''
$sent = 0; $lost = 0; $outages = 0
$downTotal = [TimeSpan]::Zero; $longest = [TimeSpan]::Zero

Write-Event $started 'START' ("[{0}] every {1}s, timeout {2} ms, DOWN after {3} missed - Ctrl+C to stop" -f
    $resolved, $IntervalSec, $TimeoutMs, $FailCount)

try {
    while ($true) {
        $t0 = Get-Date
        $sent++
        $ok = $false; $rtt = $null
        try {
            $reply = $ping.Send($Target, $TimeoutMs)
            if ($reply.Status -eq 'Success') { $ok = $true; $rtt = $reply.RoundtripTime }
            else { $lastFail = [string]$reply.Status }
        } catch {
            # DNS failure, no network, etc. - count it as a missed reply and keep going
            $lastFail = $_.Exception.GetBaseException().Message
        }

        if ($ok) {
            if ($state -eq 'DOWN') {
                $dur = $t0 - $stateSince
                $downTotal += $dur
                if ($dur -gt $longest) { $longest = $dur }
                Write-Event $t0 'UP' ("reply {0} ms, was down {1}" -f $rtt, (Format-Duration $dur))
            } elseif ($state -eq 'START') {
                Write-Event $t0 'UP' "reply $rtt ms"
            }
            if ($state -ne 'UP') { $state = 'UP'; $stateSince = $t0 }
            $missed = 0
        } else {
            $lost++
            if ($missed -eq 0) { $firstMiss = $t0 }
            $missed++
            if ($state -ne 'DOWN' -and $missed -ge $FailCount) {
                $outages++
                $detail = "$missed missed in a row ($lastFail)"
                if ($state -eq 'UP') { $detail += ", was up " + (Format-Duration ($firstMiss - $stateSince)) }
                # Timestamp the outage at the first missed reply, not when it was confirmed
                Write-Event $firstMiss 'DOWN' $detail
                $state = 'DOWN'; $stateSince = $firstMiss
            }
        }

        $loss   = 100.0 * $lost / $sent
        $last   = $(if ($ok) { "$rtt ms" } else { $lastFail })
        $status = '  {0} for {1} | sent {2}, lost {3} ({4:0.0}%) | last: {5}' -f
            $state, (Format-Duration ((Get-Date) - $stateSince)), $sent, $lost, $loss, $last
        Write-Host ("`r" + $status.PadRight($statusLen)) -NoNewline
        $statusLen = $status.Length

        $wait = $IntervalSec * 1000 - ((Get-Date) - $t0).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    }
} finally {
    # Runs on Ctrl+C too
    $end = Get-Date
    if ($state -eq 'DOWN') {
        $dur = $end - $stateSince
        $downTotal += $dur
        if ($dur -gt $longest) { $longest = $dur }
    }
    $loss = $(if ($sent) { 100.0 * $lost / $sent } else { 0 })
    Write-Event $end 'STOP' ("ran {0}, sent {1}, lost {2} ({3:0.0}%), outages {4}, total down {5}, longest {6}, ended {7}" -f
        (Format-Duration ($end - $started)), $sent, $lost, $loss, $outages,
        (Format-Duration $downTotal), (Format-Duration $longest), $state)
    if ($csv) { Write-Host "[+] saved $csv" }
    $ping.Dispose()
}
