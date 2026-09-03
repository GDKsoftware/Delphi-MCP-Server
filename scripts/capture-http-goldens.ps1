<#
.SYNOPSIS
    Records or verifies the HTTP transport golden files with curl.

.DESCRIPTION
    Starts the built server executable on a dedicated port, sends a fixed set
    of requests with curl and stores status line, headers and body of each
    response under tests\golden\http. In verify mode the stored files are
    compared with a fresh capture.

    Volatile parts are normalised before storing: the Date and Server
    headers are dropped, GUIDs become <guid>, SSE "id:" lines become
    "id: <n>", and line endings are LF.

.PARAMETER Record
    Overwrite the stored golden files with the current responses.

.PARAMETER ServerExe
    Path to the server executable. Default: Win64\Debug\MCPServer.exe.

.PARAMETER Port
    TCP port the server is started on. Default: 3939.

.EXAMPLE
    .\scripts\capture-http-goldens.ps1 -Record
    .\scripts\capture-http-goldens.ps1
#>
[CmdletBinding()]
param(
    [switch]$Record,
    [string]$ServerExe,
    [int]$Port = 3939
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ServerExe) {
    $ServerExe = Join-Path $repoRoot 'Win64\Debug\MCPServer.exe'
}
$ServerExe = (Resolve-Path $ServerExe).Path
$goldenDir = Join-Path $repoRoot 'tests\golden\http'
$resultsDir = Join-Path $repoRoot 'tests\results\http-golden'
$endpoint = "http://127.0.0.1:$Port/mcp"

New-Item -ItemType Directory -Force -Path $goldenDir, $resultsDir | Out-Null

$curl = Get-Command curl.exe -ErrorAction Stop

# ---------------------------------------------------------------------------
# Server lifecycle: the server reads settings.ini next to its executable, so a
# temporary one with the test port is written and the original restored.
# ---------------------------------------------------------------------------
$exeDir = Split-Path -Parent $ServerExe
$settingsFile = Join-Path $exeDir 'settings.ini'
$settingsBackup = $null
if (Test-Path $settingsFile) {
    $settingsBackup = Get-Content -Raw $settingsFile
}

$settingsContent = @"
[Server]
Port=$Port
Host=localhost
Name=delphi-mcp-server
Version=1.0.0
Endpoint=/mcp
EndpointInfoPath=/info

[CORS]
Enabled=1
AllowedOrigins=http://localhost,http://127.0.0.1,https://localhost,https://127.0.0.1

[SSL]
Enabled=0
"@
Set-Content -Path $settingsFile -Value $settingsContent -Encoding ASCII

function Wait-ForPort([int]$PortNumber, [int]$TimeoutSeconds = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $PortNumber)
            if ($client.Connected) { return $true }
        } catch {
        } finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

$serverLog = Join-Path $resultsDir 'server.log'
$serverErr = Join-Path $resultsDir 'server.err.log'
$server = Start-Process -FilePath $ServerExe -WorkingDirectory $exeDir -PassThru -NoNewWindow `
    -RedirectStandardOutput $serverLog -RedirectStandardError $serverErr

try {
    if (-not (Wait-ForPort $Port)) {
        throw "Server did not open port $Port within the timeout (see $serverLog)"
    }

    # Observation for the PR description: which address does Indy bind to?
    $listen = (netstat -ano | Select-String ":$Port\s" | Select-String 'LISTENING' | ForEach-Object { $_.Line.Trim() }) -join "`n"
    Set-Content -Path (Join-Path $resultsDir 'listen.txt') -Value $listen -Encoding ASCII
    Write-Host "Listening sockets:`n$listen"

    # -----------------------------------------------------------------------
    # Cases
    # -----------------------------------------------------------------------
    $jsonAccept = 'Accept: application/json'
    $sseAccept = 'Accept: application/json, text/event-stream'
    $jsonType = 'Content-Type: application/json'
    $initialize = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"golden-client","version":"1.0.0"}}}'
    $modernHeader = 'MCP-Protocol-Version: 2026-07-28'
    $modernMeta = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"golden-client","version":"1.0.0"}}'

    $cases = @(
        @{ Name = 'modern-discover';               Method = 'POST';    Headers = @($jsonType, $jsonAccept, $modernHeader, 'Mcp-Method: server/discover'); Body = '{"jsonrpc":"2.0","id":"d1","method":"server/discover","params":{' + $modernMeta + '}}' }
        @{ Name = 'modern-tools-list';             Method = 'POST';    Headers = @($jsonType, $jsonAccept, $modernHeader, 'Mcp-Method: tools/list'); Body = '{"jsonrpc":"2.0","id":20,"method":"tools/list","params":{' + $modernMeta + '}}' }
        @{ Name = 'modern-tools-call-name-base64';  Method = 'POST';    Headers = @($jsonType, $jsonAccept, $modernHeader, 'Mcp-Method: tools/call', 'Mcp-Name: =?base64?ZWNobw==?='); Body = '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello modern"},' + $modernMeta + '}}' }
        @{ Name = 'modern-unknown-method';         Method = 'POST';    Headers = @($jsonType, $jsonAccept, $modernHeader, 'Mcp-Method: totally/bogus/method'); Body = '{"jsonrpc":"2.0","id":21,"method":"totally/bogus/method","params":{' + $modernMeta + '}}' }
        @{ Name = 'modern-missing-version-header'; Method = 'POST';    Headers = @($jsonType, $jsonAccept, 'Mcp-Method: tools/list'); Body = '{"jsonrpc":"2.0","id":22,"method":"tools/list","params":{' + $modernMeta + '}}' }
        @{ Name = 'modern-missing-method-header';  Method = 'POST';    Headers = @($jsonType, $jsonAccept, $modernHeader); Body = '{"jsonrpc":"2.0","id":26,"method":"tools/list","params":{' + $modernMeta + '}}' }
        @{ Name = 'modern-method-header-mismatch'; Method = 'POST';    Headers = @($jsonType, $jsonAccept, $modernHeader, 'Mcp-Method: tools/call'); Body = '{"jsonrpc":"2.0","id":27,"method":"tools/list","params":{' + $modernMeta + '}}' }
        @{ Name = 'modern-unsupported-version';    Method = 'POST';    Headers = @($jsonType, $jsonAccept, 'MCP-Protocol-Version: 1900-01-01', 'Mcp-Method: tools/list'); Body = '{"jsonrpc":"2.0","id":23,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}' }
        @{ Name = 'modern-missing-client-capabilities'; Method = 'POST'; Headers = @($jsonType, $jsonAccept, $modernHeader, 'Mcp-Method: tools/list'); Body = '{"jsonrpc":"2.0","id":24,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' }
        @{ Name = 'modern-notification';           Method = 'POST';    Headers = @($jsonType, $jsonAccept, $modernHeader); Body = '{"jsonrpc":"2.0","method":"notifications/initialized"}' }
        @{ Name = 'get-info-path';                 Method = 'GET';     Headers = @($jsonAccept); Path = '/info' }
        @{ Name = 'post-initialize';               Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = $initialize }
        @{ Name = 'post-initialize-sse';           Method = 'POST';    Headers = @($jsonType, $sseAccept);  Body = $initialize }
        @{ Name = 'post-tools-list';               Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' }
        @{ Name = 'post-tools-list-sse';           Method = 'POST';    Headers = @($jsonType, $sseAccept);  Body = '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' }
        @{ Name = 'post-tools-call-echo';          Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello golden"}}}' }
        @{ Name = 'post-resources-list';           Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","id":4,"method":"resources/list"}' }
        @{ Name = 'post-resources-read-project-info'; Method = 'POST'; Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"project://info"}}' }
        @{ Name = 'post-notification-initialized'; Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","method":"notifications/initialized"}' }
        @{ Name = 'post-client-response';          Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","id":1,"result":{}}' }
        @{ Name = 'post-batch-notifications';      Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '[{"jsonrpc":"2.0","method":"notifications/initialized"}]' }
        @{ Name = 'post-batch-requests';           Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '[{"jsonrpc":"2.0","id":6,"method":"ping"}]' }
        @{ Name = 'post-unknown-method';           Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","id":7,"method":"totally/bogus/method"}' }
        @{ Name = 'post-parse-error';              Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","id":8,"method":' }
        @{ Name = 'post-empty-body';               Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '' }
        @{ Name = 'post-no-accept-header';         Method = 'POST';    Headers = @($jsonType);              Body = '{"jsonrpc":"2.0","id":9,"method":"ping"}' }
        @{ Name = 'post-session-echo';             Method = 'POST';    Headers = @($jsonType, $jsonAccept, 'Mcp-Session-Id: golden-session-1'); Body = '{"jsonrpc":"2.0","id":10,"method":"ping"}' }
        @{ Name = 'post-session-echo-lowercase';   Method = 'POST';    Headers = @($jsonType, $jsonAccept, 'mcp-session-id: golden-session-2'); Body = '{"jsonrpc":"2.0","id":11,"method":"ping"}' }
        @{ Name = 'post-protocol-version-header';  Method = 'POST';    Headers = @($jsonType, $jsonAccept, 'MCP-Protocol-Version: 2025-06-18'); Body = '{"jsonrpc":"2.0","id":12,"method":"ping"}' }
        @{ Name = 'post-origin-allowed';           Method = 'POST';    Headers = @($jsonType, $jsonAccept, 'Origin: http://localhost'); Body = '{"jsonrpc":"2.0","id":13,"method":"ping"}' }
        @{ Name = 'post-origin-forbidden';         Method = 'POST';    Headers = @($jsonType, $jsonAccept, 'Origin: http://evil.example'); Body = '{"jsonrpc":"2.0","id":14,"method":"ping"}' }
        @{ Name = 'post-wrong-path';               Method = 'POST';    Headers = @($jsonType, $jsonAccept); Body = '{"jsonrpc":"2.0","id":15,"method":"ping"}'; Path = '/other' }
        @{ Name = 'get-endpoint-info';             Method = 'GET';     Headers = @($jsonAccept) }
        @{ Name = 'get-sse-stream';                Method = 'GET';     Headers = @('Accept: text/event-stream') }
        @{ Name = 'options-preflight';             Method = 'OPTIONS'; Headers = @('Origin: http://localhost', 'Access-Control-Request-Method: POST', 'Access-Control-Request-Headers: Content-Type') }
        @{ Name = 'delete-endpoint';               Method = 'DELETE';  Headers = @($jsonAccept) }
        @{ Name = 'put-endpoint';                  Method = 'PUT';     Headers = @($jsonType, $jsonAccept); Body = '{}' }
    )

    function Normalize-Response([string]$Text) {
        $lines = ($Text -replace "`r`n", "`n").Split("`n")
        $kept = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            if ($line -match '^(Date|Server):\s') { continue }
            $normalized = $line
            $normalized = [regex]::Replace($normalized, '\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?', '<guid>')
            $normalized = [regex]::Replace($normalized, '^id: \d+$', 'id: <n>')
            $kept.Add($normalized)
        }
        return ($kept -join "`n")
    }

    $failures = 0
    $bodyFile = Join-Path $resultsDir 'request-body.tmp'
    $responseFile = Join-Path $resultsDir 'response.tmp'

    foreach ($case in $cases) {
        $path = if ($case.Path) { $case.Path } else { '/mcp' }
        $url = "http://127.0.0.1:$Port$path"
        $arguments = @('-s', '-i', '--http1.1', '-X', $case.Method, '-o', $responseFile)
        foreach ($header in $case.Headers) {
            $arguments += @('-H', $header)
        }
        if ($case.ContainsKey('Body')) {
            [System.IO.File]::WriteAllBytes($bodyFile, [System.Text.Encoding]::UTF8.GetBytes([string]$case.Body))
            $arguments += @('--data-binary', "@$bodyFile")
        }
        $arguments += $url

        & $curl.Source @arguments
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[$($case.Name)] curl failed with exit code $LASTEXITCODE"
            $failures++
            continue
        }

        $raw = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($responseFile))
        $actual = (Normalize-Response $raw).TrimEnd("`n")
        $goldenFile = Join-Path $goldenDir "$($case.Name).txt"

        if ($Record) {
            [System.IO.File]::WriteAllText($goldenFile, $actual + "`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "[$($case.Name)] recorded"
            continue
        }

        if (-not (Test-Path $goldenFile)) {
            Write-Host "[$($case.Name)] MISSING golden file (run with -Record)"
            $failures++
            continue
        }

        $expected = ([System.IO.File]::ReadAllText($goldenFile) -replace "`r`n", "`n").TrimEnd("`n")
        if ($expected -eq $actual) {
            Write-Host "[$($case.Name)] ok"
        } else {
            Write-Host "[$($case.Name)] MISMATCH"
            Write-Host '--- expected ---'
            Write-Host $expected
            Write-Host '--- actual ---'
            Write-Host $actual
            Write-Host '---'
            $failures++
        }
    }

    Remove-Item $bodyFile, $responseFile -ErrorAction SilentlyContinue

    if ($failures -gt 0) {
        Write-Host "$failures case(s) failed"
        exit 1
    }
    Write-Host 'All HTTP golden cases passed'
}
finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
        $server.WaitForExit(5000) | Out-Null
    }
    if ($null -ne $settingsBackup) {
        Set-Content -Path $settingsFile -Value $settingsBackup -NoNewline
    } else {
        Remove-Item $settingsFile -ErrorAction SilentlyContinue
    }
}
