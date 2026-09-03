<#
.SYNOPSIS
    Runs the official MCP conformance suite against the built server.

.DESCRIPTION
    Builds the server, starts it, and runs
    "npx @modelcontextprotocol/conformance server" once per requirement set
    (2026-07-28 and 2025-11-25 by default) against the same endpoint. Known
    failures are read from conformance-baseline.yml; the run fails on new
    failures and on stale baseline entries. Reports land in
    tests\results\conformance\<revision>.

    The pinned tool version comes from package.json (the --requirements flag
    needs the 0.2.0 line of the conformance package).

.PARAMETER Configuration
    Release (default) or Debug.

.PARAMETER Platform
    Win64 (default) or Win32.

.PARAMETER Port
    Port to start the server on. Default: 3000.

.PARAMETER Requirements
    Requirement sets to run. Default: 2026-07-28 and 2025-11-25.

.PARAMETER NoBuild
    Use the existing executable.

.PARAMETER NoBaseline
    Run without the expected-failures file (to see the raw result).

.EXAMPLE
    .\scripts\run-conformance.ps1
    .\scripts\run-conformance.ps1 -NoBuild -Requirements 2025-11-25
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('Win32', 'Win64')]
    [string]$Platform = 'Win64',

    [int]$Port = 3000,

    [string[]]$Requirements = @('2026-07-28', '2025-11-25'),

    [switch]$NoBuild,

    [switch]$NoBaseline
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\McpServerProcess.ps1"

$repoRoot = Get-RepoRoot
$serverExe = Join-Path $repoRoot "$Platform\$Configuration\MCPServer.exe"
$resultsRoot = Join-Path $repoRoot 'tests\results\conformance'
$baseline = Join-Path $repoRoot 'conformance-baseline.yml'

if (-not $NoBuild) {
    Invoke-ServerBuild -Configuration $Configuration -Platform $Platform
}
Assert-NodeTooling

New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null
$server = Start-McpServer -ServerExe $serverExe -Port $Port -LogDir $resultsRoot

$summary = @()
try {
    foreach ($revision in $Requirements) {
        $outputDir = Join-Path $resultsRoot $revision
        $logFile = Join-Path $resultsRoot "$revision.log"
        $commandLine = "npx @modelcontextprotocol/conformance server --url $($server.Url) --requirements $revision -o `"$outputDir`""
        # One baseline per requirement set: a scenario can pass on one wire
        # and fail on the other, and a listed scenario that passes counts as a
        # stale entry.
        $baseline = Join-Path $repoRoot "conformance-baseline-$revision.yml"
        if (-not $NoBaseline -and (Test-Path $baseline)) {
            $commandLine += " --expected-failures `"$baseline`""
        }

        Write-Host ''
        Write-Host "=== conformance --requirements $revision ==="
        $exitCode = Invoke-NativeToLog -CommandLine $commandLine -LogFile $logFile -WorkingDirectory $repoRoot

        # The per-scenario progress is in the log file; show the summary only.
        $logText = [System.IO.File]::ReadAllText($logFile)
        $summaryStart = $logText.LastIndexOf('=== SUMMARY ===')
        if ($summaryStart -ge 0) { Write-Host $logText.Substring($summaryStart) } else { Write-Host $logText }
        $summary += [pscustomobject]@{ Revision = $revision; ExitCode = $exitCode; Log = $logFile }
    }
}
finally {
    Stop-McpServer $server
}

Write-Host ''
Write-Host 'Summary:'
$summary | Format-Table -AutoSize | Out-String | Write-Host

$failed = @($summary | Where-Object { $_.ExitCode -ne 0 })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) requirement set(s) did not match the baseline"
    exit 1
}
Write-Host 'All requirement sets match the baseline'
exit 0
