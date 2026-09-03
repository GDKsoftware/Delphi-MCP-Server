<#
.SYNOPSIS
    Smoke-tests the server with the MCP Inspector CLI in every protocol era.

.DESCRIPTION
    Starts the built server and calls tools/list through
    "npx @modelcontextprotocol/inspector --cli" for each entry in
    ci-servers.json: delphi-legacy, delphi-auto, delphi-modern over HTTP and
    delphi-stdio over a spawned process. The pinned Inspector version comes
    from package.json.

    Every entry is expected to list the tools. Entries named in
    -ExpectedFailures are expected to fail instead; the script exits non-zero
    when an entry does not behave as expected in either direction.

.PARAMETER Configuration
    Release (default) or Debug. The stdio entry in ci-servers.json points at
    Win64\Release\MCPServer.exe.

.PARAMETER Platform
    Win64 (default) or Win32.

.PARAMETER NoBuild
    Use the existing executable.

.PARAMETER ExpectedFailures
    Entry names that must fail (for example delphi-modern while the server
    does not implement server/discover).

.EXAMPLE
    .\scripts\run-inspector-smoke.ps1
    .\scripts\run-inspector-smoke.ps1 -ExpectedFailures delphi-modern
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('Win32', 'Win64')]
    [string]$Platform = 'Win64',

    [switch]$NoBuild,

    [string[]]$ExpectedFailures = @()
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\McpServerProcess.ps1"

$repoRoot = Get-RepoRoot
$serverExe = Join-Path $repoRoot "$Platform\$Configuration\MCPServer.exe"
$resultsDir = Join-Path $repoRoot 'tests\results\inspector'
$config = Join-Path $repoRoot 'ci-servers.json'
$port = 3000   # ci-servers.json points at this port

if (-not $NoBuild) {
    Invoke-ServerBuild -Configuration $Configuration -Platform $Platform
}
Assert-NodeTooling

New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$server = Start-McpServer -ServerExe $serverExe -Port $port -LogDir $resultsDir

$entries = @()
foreach ($name in 'delphi-legacy', 'delphi-auto', 'delphi-modern', 'delphi-stdio') {
    $entries += @{ Name = $name; ExpectSuccess = ($ExpectedFailures -notcontains $name) }
}

$rows = @()
try {
    foreach ($entry in $entries) {
        $logFile = Join-Path $resultsDir "$($entry.Name).log"
        $commandLine = "npx @modelcontextprotocol/inspector --cli --config `"$config`" --server $($entry.Name) --method tools/list --format json"
        $exitCode = Invoke-NativeToLog -CommandLine $commandLine -LogFile $logFile -WorkingDirectory $repoRoot
        $text = [System.IO.File]::ReadAllText($logFile)

        # The JSON result is one line on stdout. A stdio server's stderr log
        # lines share the log file and can interleave with it, so locate the
        # result object by its prefix and parse up to the end of that line.
        $toolCount = $null
        $resultStart = $text.LastIndexOf('{"result":')
        if ($resultStart -ge 0) {
            $resultEnd = $text.IndexOfAny([char[]]@("`r", "`n"), $resultStart)
            if ($resultEnd -lt 0) { $resultEnd = $text.Length }
            $jsonLine = $text.Substring($resultStart, $resultEnd - $resultStart)
            try {
                $json = $jsonLine | ConvertFrom-Json
                if ($json.result -and $json.result.tools) { $toolCount = @($json.result.tools).Count }
            } catch {
            }
        }

        $succeeded = ($exitCode -eq 0) -and ($null -ne $toolCount)
        $asExpected = ($succeeded -eq $entry.ExpectSuccess)
        $rows += [pscustomobject]@{
            Server     = $entry.Name
            ExitCode   = $exitCode
            Tools      = $toolCount
            Succeeded  = $succeeded
            Expected   = $entry.ExpectSuccess
            AsExpected = $asExpected
        }
    }
}
finally {
    Stop-McpServer $server
}

$rows | Format-Table -AutoSize | Out-String | Write-Host

$unexpected = @($rows | Where-Object { -not $_.AsExpected })
if ($unexpected.Count -gt 0) {
    Write-Host "$($unexpected.Count) entr(y/ies) did not behave as expected (see $resultsDir)"
    exit 1
}
Write-Host 'Inspector smoke run behaved as expected'
exit 0
