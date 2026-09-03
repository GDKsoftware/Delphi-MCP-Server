<#
.SYNOPSIS
    Drives the server over stdio and checks the framing of the channel.

.DESCRIPTION
    Feeds a fixed set of JSON-RPC lines (initialize, initialized, tools/list,
    tools/call echo with non-ASCII text) to "MCPServer.exe --stdio" through
    cmd.exe redirection, exactly as a client spawning the process would, and
    checks:
      - stdout holds one JSON object per line and nothing else,
      - every request id gets exactly one response,
      - all log lines went to stderr.
    It also reports whether the non-ASCII text survived the round trip; this
    is an observation for the stdio work (Text I/O decodes stdin with the
    ANSI code page on Windows) and does not fail the run.

.PARAMETER ServerExe
    Path to the executable. Default: Win64\Release\MCPServer.exe.

.EXAMPLE
    .\scripts\run-stdio-smoke.ps1
#>
[CmdletBinding()]
param(
    [string]$ServerExe
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ServerExe) {
    $ServerExe = Join-Path $repoRoot 'Win64\Release\MCPServer.exe'
}
$ServerExe = (Resolve-Path $ServerExe).Path
$resultsDir = Join-Path $repoRoot 'tests\results\stdio'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

$inputFile = Join-Path $resultsDir 'input.jsonl'
$stdoutFile = Join-Path $resultsDir 'stdout.txt'
$stderrFile = Join-Path $resultsDir 'stderr.txt'

$probe = 'h' + [char]0x00E9 + 'llo w' + [char]0x00F6 + 'rld'
$lines = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"stdio-smoke","version":"1.0.0"}}}'
    '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    ('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"' + $probe + '"}}}')
)
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllBytes($inputFile, $utf8.GetBytes(($lines -join "`n") + "`n"))

# A batch file keeps the redirections out of PowerShell's argument quoting.
$batchFile = Join-Path $resultsDir 'run.cmd'
$command = "@`"$ServerExe`" --stdio < `"$inputFile`" > `"$stdoutFile`" 2> `"$stderrFile`""
Set-Content -Path $batchFile -Value $command -Encoding ASCII
$process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$batchFile`"") -WorkingDirectory (Split-Path -Parent $ServerExe) `
    -PassThru -NoNewWindow -Wait
if ($process.ExitCode -ne 0) {
    Write-Host "Server exited with code $($process.ExitCode)"
}

$stdout = $utf8.GetString([System.IO.File]::ReadAllBytes($stdoutFile))
$stderr = $utf8.GetString([System.IO.File]::ReadAllBytes($stderrFile))

$failures = 0
$stdoutLines = @($stdout -split "`r?`n" | Where-Object { $_ -ne '' })

Write-Host "stdout lines: $($stdoutLines.Count)"
$responses = @{}
foreach ($line in $stdoutLines) {
    try {
        $message = $line | ConvertFrom-Json
    } catch {
        Write-Host "NOT JSON on stdout: $line"
        $failures++
        continue
    }
    if ($null -eq $message.jsonrpc) {
        Write-Host "stdout line is not a JSON-RPC message: $line"
        $failures++
        continue
    }
    if ($null -ne $message.id) { $responses[[string]$message.id] = $message }
}

foreach ($id in '1', '2', '3') {
    if (-not $responses.ContainsKey($id)) {
        Write-Host "missing response for id $id"
        $failures++
    }
}
if ($stdoutLines.Count -ne 3) {
    Write-Host "expected exactly 3 responses on stdout, got $($stdoutLines.Count)"
    $failures++
}

if ($stdout -match '\[(INFO|WARN|ERROR|DEBUG)\s*\]') {
    Write-Host 'log lines found on stdout'
    $failures++
}
if ($stderr.Trim().Length -eq 0) {
    Write-Host 'expected log lines on stderr, found none'
    $failures++
}

if ($responses.ContainsKey('3')) {
    $echoText = $responses['3'].result.content[0].text
    if ($echoText -eq "Echo: $probe") {
        Write-Host "observation: non-ASCII input survived the stdio round trip"
    } else {
        Write-Host "observation: non-ASCII input was altered on the stdio round trip: $echoText"
    }
}

Write-Host "stderr: $($stderr.Length) characters (see $stderrFile)"
if ($failures -gt 0) {
    Write-Host "$failures check(s) failed"
    exit 1
}
Write-Host 'stdio smoke run passed'
exit 0
