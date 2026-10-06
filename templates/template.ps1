<#
.SYNOPSIS
    One line describing what this tool does (shows in the README catalog)

.DESCRIPTION
    Longer description. Rules: read-only by default, no module installs,
    results go to .\output\.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NNN-verb-noun.w.ps1 -Out

.NOTES
    Category: net | sys | ident | sec | cloud | util
    Requires: Windows PowerShell 5.1+ (no extra modules)
#>
[CmdletBinding()]
param(
    [Alias('o')][switch]$Out,   # also save results to .\output\ (alias needed: -OutVariable/-OutBuffer make -o ambiguous)
    [switch]$Version   # print the version and exit
)

$ToolVersion = '1.0.0'   # bump on every change: MAJOR.MINOR.PATCH (see CLAUDE.md)
$ToolName    = Split-Path -Leaf $PSCommandPath
if ($Version) { "$ToolName v$ToolVersion"; return }
Write-Host "$ToolName v$ToolVersion"   # host stream, so pipeline / CSV output stays clean

$ErrorActionPreference = 'Stop'
$ToolId    = ((Split-Path -Leaf $PSCommandPath) -split '-')[0]   # e.g. 001
$OutputDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'output'

$results = @(
    [pscustomobject]@{ Item = 'replace me'; Value = '' }
)

$results | Format-Table -AutoSize

if ($Out) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $path = Join-Path $OutputDir ("{0}_{1}_{2}.csv" -f $ToolId, $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $results | Export-Csv -NoTypeInformation -Path $path
    Write-Host "[+] saved $path"
}
