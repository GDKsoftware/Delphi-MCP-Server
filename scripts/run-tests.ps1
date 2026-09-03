<#
.SYNOPSIS
    Builds and runs the DUnitX test project.

.DESCRIPTION
    Compiles tests\MCPServer.Tests.dpr with build-tests.bat and runs the
    resulting executable. Results are written as NUnit XML to tests\results.

.PARAMETER Configuration
    Debug (default) or Release.

.PARAMETER Platform
    Win64 (default) or Win32.

.PARAMETER Record
    Re-record the golden files from the current code instead of comparing.
    Only do this on a commit whose behaviour you want to pin; review the diff.

.PARAMETER Filter
    Optional DUnitX run filter with fully qualified test names, comma separated,
    for example "MCPServer.Tests.Golden.Legacy.TLegacyGoldenTests.Ping".

.PARAMETER NoBuild
    Skip the compile step and run the existing executable.

.EXAMPLE
    .\scripts\run-tests.ps1
    .\scripts\run-tests.ps1 -Platform Win32
    .\scripts\run-tests.ps1 -Record
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',

    [ValidateSet('Win32', 'Win64')]
    [string]$Platform = 'Win64',

    [switch]$Record,

    [string]$Filter,

    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$testExe = Join-Path $repoRoot "tests\$Platform\$Configuration\MCPServer.Tests.exe"
$resultsDir = Join-Path $repoRoot 'tests\results'
$xmlFile = Join-Path $resultsDir "dunitx-$Platform-$Configuration.xml"

if (-not $NoBuild) {
    Write-Host "Building tests ($Configuration $Platform)..."
    & cmd.exe /c "cd /d `"$repoRoot`" && .\build-tests.bat $Configuration $Platform"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Test build failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
}

if (-not (Test-Path $testExe)) {
    Write-Error "Test executable not found: $testExe"
    exit 1
}

New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

if ($Record) {
    $env:MCP_GOLDEN_RECORD = '1'
    Write-Host 'Golden record mode: expectations will be rewritten.'
} else {
    Remove-Item Env:\MCP_GOLDEN_RECORD -ErrorAction SilentlyContinue
}

$arguments = @('-exit:continue', "-xml:$xmlFile")
if ($Filter) {
    $arguments += "-run:$Filter"
}

Write-Host "Running $testExe $($arguments -join ' ')"
& $testExe @arguments
$exitCode = $LASTEXITCODE

Remove-Item Env:\MCP_GOLDEN_RECORD -ErrorAction SilentlyContinue

Write-Host "Results: $xmlFile"
exit $exitCode
