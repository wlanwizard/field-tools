<#
.SYNOPSIS
    TCP connect test to one or more host:port targets (firewall / ACL validation)

.DESCRIPTION
    PowerShell twin of 002-port-check.lmw.py for Windows boxes without Python.
    Faster than Test-NetConnection because it uses a short connect timeout.
    Read-only; sends no payload.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\002-port-check.w.ps1 10.0.0.1:443,dc01:389 -Out

.NOTES
    Category: net
    Requires: Windows PowerShell 5.1+ (no extra modules)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Targets,          # host:port
    [int]$TimeoutMs = 3000,
    [switch]$Out                 # also save CSV to .\output\
)

$ErrorActionPreference = 'Stop'
$ToolId    = ((Split-Path -Leaf $PSCommandPath) -split '-')[0]
$OutputDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'output'

$results = foreach ($t in $Targets) {
    $i = $t.LastIndexOf(':')
    $hostName = $t.Substring(0, $i).Trim('[', ']')
    $port = [int]$t.Substring($i + 1)
    $client = New-Object System.Net.Sockets.TcpClient
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $task = $client.ConnectAsync($hostName, $port)
        if ($task.Wait($TimeoutMs)) { $status = 'OPEN'; $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
        else                        { $status = 'TIMEOUT'; $ms = '' }
    } catch {
        $inner = $_.Exception.GetBaseException()
        $status = switch -Regex ($inner.Message) {
            'refused'                          { 'CLOSED' }
            'No such host|not known|resolve'   { 'DNS-FAIL' }
            default                            { "ERROR:$($inner.Message)" }
        }
        $ms = ''
    } finally {
        $client.Dispose()
    }
    [pscustomobject]@{ Target = $t; Result = $status; Ms = $ms }
}

$results | Format-Table -AutoSize

if ($Out) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $path = Join-Path $OutputDir ("{0}_{1}_{2}.csv" -f $ToolId, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $results | Export-Csv -NoTypeInformation -Path $path
    Write-Host "[+] saved $path"
}
