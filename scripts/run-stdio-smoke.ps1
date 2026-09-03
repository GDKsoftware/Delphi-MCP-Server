<#
.SYNOPSIS
    Drives the server over stdio and checks the framing of the channel.

.DESCRIPTION
    Feeds a fixed set of JSON-RPC lines (initialize, initialized, tools/list,
    tools/call echo with non-ASCII text, a tools/call with a progressToken, a
    slow tools/call followed by notifications/cancelled, and ping) to
    "MCPServer.exe --stdio" through cmd.exe redirection, exactly as a client
    spawning the process would, and checks:
      - stdout holds one JSON object per line and nothing else,
      - every request id gets exactly one response, except the cancelled one,
      - the non-ASCII text comes back unchanged,
      - the progress notifications precede their response and increase,
      - the server exits promptly once stdin is closed,
      - all log lines went to stderr.

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
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test_tool_with_progress","arguments":{"steps":3,"stepMs":80},"_meta":{"progressToken":"smoke-progress"}}}'
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"test_tool_with_progress","arguments":{"steps":50,"stepMs":100}}}'
    '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"smoke test"}}'
    '{"jsonrpc":"2.0","id":6,"method":"ping"}'
)
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllBytes($inputFile, $utf8.GetBytes(($lines -join "`n") + "`n"))

# A batch file keeps the redirections out of PowerShell's argument quoting.
$batchFile = Join-Path $resultsDir 'run.cmd'
$command = "@`"$ServerExe`" --stdio < `"$inputFile`" > `"$stdoutFile`" 2> `"$stderrFile`""
Set-Content -Path $batchFile -Value $command -Encoding ASCII
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$batchFile`"") -WorkingDirectory (Split-Path -Parent $ServerExe) `
    -PassThru -NoNewWindow -Wait
$stopwatch.Stop()
if ($process.ExitCode -ne 0) {
    Write-Host "Server exited with code $($process.ExitCode)"
}
Write-Host "server run time: $($stopwatch.ElapsedMilliseconds) ms"

$stdout = $utf8.GetString([System.IO.File]::ReadAllBytes($stdoutFile))
$stderr = $utf8.GetString([System.IO.File]::ReadAllBytes($stderrFile))

$failures = 0
$stdoutLines = @($stdout -split "`n" | Where-Object { $_ -ne '' })
if ($stdout.Contains("`r")) {
    Write-Host 'carriage return found on stdout; the framing is a bare LF'
    $failures++
}
if ($stdout.Length -gt 0 -and [int][char]$stdout[0] -eq 0xFEFF) {
    Write-Host 'byte-order mark found on stdout'
    $failures++
}

Write-Host "stdout lines: $($stdoutLines.Count)"
$responses = @{}
$progress = @()
$lineIndex = 0
$responseIndexes = @{}
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
    if ($null -ne $message.id) {
        $responses[[string]$message.id] = $message
        $responseIndexes[[string]$message.id] = $lineIndex
    } elseif ($message.method -eq 'notifications/progress') {
        $progress += [pscustomobject]@{ Index = $lineIndex; Params = $message.params }
    } else {
        Write-Host "unexpected message on stdout: $line"
        $failures++
    }
    $lineIndex++
}

foreach ($id in '1', '2', '3', '4', '6') {
    if (-not $responses.ContainsKey($id)) {
        Write-Host "missing response for id $id"
        $failures++
    }
}
if ($responses.ContainsKey('5')) {
    Write-Host 'the cancelled request (id 5) got a response'
    $failures++
}

$smokeProgress = @($progress | Where-Object { $_.Params.progressToken -eq 'smoke-progress' })
if ($smokeProgress.Count -lt 3) {
    Write-Host "expected at least 3 progress notifications for id 4, got $($smokeProgress.Count)"
    $failures++
} else {
    $previous = -1
    foreach ($item in $smokeProgress) {
        if ($item.Params.progress -le $previous) {
            Write-Host "progress did not increase: $($item.Params.progress) after $previous"
            $failures++
        }
        $previous = $item.Params.progress
        if ($responseIndexes.ContainsKey('4') -and $item.Index -gt $responseIndexes['4']) {
            Write-Host 'a progress notification arrived after its response'
            $failures++
        }
    }
}
if (@($progress | Where-Object { $_.Params.progressToken -ne 'smoke-progress' }).Count -gt 0) {
    Write-Host 'progress notification with an unknown token'
    $failures++
}

if ($stopwatch.ElapsedMilliseconds -gt 4000) {
    Write-Host "the server took $($stopwatch.ElapsedMilliseconds) ms to exit; the cancelled tool should not hold it"
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
    if ($echoText -ne "Echo: $probe") {
        Write-Host "non-ASCII input was altered on the stdio round trip: $echoText"
        $failures++
    }
}

Write-Host "stderr: $($stderr.Length) characters (see $stderrFile)"
if ($failures -gt 0) {
    Write-Host "$failures check(s) failed"
    exit 1
}
Write-Host 'stdio smoke run passed'
exit 0
