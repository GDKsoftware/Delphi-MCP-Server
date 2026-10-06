<#
.SYNOPSIS
Runs the MCP conformance suite against a build of this server.

.DESCRIPTION
Starts MCPServer.exe from a temporary folder with its own settings.ini (tasks
enabled, a free port on localhost), runs the active server suite and the tasks
scenarios with conformance-baseline.yml as the list of expected failures, and
stops the server again. Exits with 0 when every run reports "Baseline check
passed": nothing failed unexpectedly and no baseline entry started to pass. The
script reads that line rather than the exit code, because Node on Windows can
exit with an assertion from libuv after a run that passed.

.PARAMETER Platform
Win32 or Win64; the build output that is tested. Build it first with build.bat.

.PARAMETER Config
Debug or Release.

.PARAMETER ConformancePath
A local clone of github.com/modelcontextprotocol/conformance with
"npm install" run in it (defaults to the MCP_CONFORMANCE_PATH environment
variable). Without it the published npm package runs, and the tasks scenarios
are skipped when that package does not know them yet.
#>
param(
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform = 'Win64',

    [ValidateSet('Debug', 'Release')]
    [string]$Config = 'Release',

    [string]$ConformancePath = $env:MCP_CONFORMANCE_PATH,

    [int]$StartupTimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

$Baseline = Join-Path $PSScriptRoot 'conformance-baseline.yml'
$ServerExe = Join-Path $PSScriptRoot "$Platform\$Config\MCPServer.exe"
$TaskScenarios = @(
    'tasks-capability-negotiation',
    'tasks-dispatch-and-envelope',
    'tasks-lifecycle',
    'tasks-mrtr-composition',
    'tasks-mrtr-input',
    'tasks-request-headers',
    'tasks-request-state-removal',
    'tasks-required-task-error',
    'tasks-wire-fields'
)

function Get-FreePort {
    $Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $Listener.Start()
    $Port = $Listener.LocalEndpoint.Port
    $Listener.Stop()
    return $Port
}

function Wait-ForPort([int]$Port, [int]$TimeoutSeconds) {
    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $Deadline) {
        $Client = [System.Net.Sockets.TcpClient]::new()
        try {
            $Client.Connect('127.0.0.1', $Port)
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
        finally {
            $Client.Dispose()
        }
    }
    return $false
}

function Test-ConformancePassed([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    if ($ConformancePath) {
        $Output = & node (Join-Path $ConformancePath 'dist\index.js') @Arguments 2>&1
    }
    else {
        $Output = & npx -y '@modelcontextprotocol/conformance' @Arguments 2>&1
    }
    $Output | Out-Host

    $Text = $Output | Out-String
    return $Text.Contains('Baseline check passed')
}

function Test-ScenarioKnown([string]$Scenario) {
    if ($ConformancePath) {
        return $true
    }
    $Listing = & npx -y '@modelcontextprotocol/conformance' list 2>&1 | Out-String
    return $Listing.Contains($Scenario)
}

if (-not (Test-Path $ServerExe)) {
    throw "$ServerExe not found; run build.bat $Config $Platform first"
}
if ($ConformancePath -and -not (Test-Path (Join-Path $ConformancePath 'dist\index.js'))) {
    throw "$ConformancePath\dist\index.js not found; run npm install in the conformance clone first"
}

$WorkFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("mcp-conformance-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $WorkFolder | Out-Null
Copy-Item $ServerExe $WorkFolder

$Port = Get-FreePort
$Settings = @(
    '[Server]',
    "Port=$Port",
    'Host=localhost',
    '[Tasks]',
    'Enabled=1',
    'PollIntervalMs=200'
)
Set-Content -Path (Join-Path $WorkFolder 'settings.ini') -Value $Settings -Encoding Ascii

$Server = Start-Process -FilePath (Join-Path $WorkFolder 'MCPServer.exe') -WorkingDirectory $WorkFolder `
    -WindowStyle Hidden -PassThru
$Failures = @()
try {
    if (-not (Wait-ForPort $Port $StartupTimeoutSeconds)) {
        throw "The server did not listen on port $Port within $StartupTimeoutSeconds seconds"
    }
    $Url = "http://localhost:$Port/mcp"

    Write-Host "== Active suite against $Url"
    if (-not (Test-ConformancePassed @('server', '--url', $Url, '--suite', 'active', '--expected-failures', $Baseline))) {
        $Failures += 'active suite'
    }

    if (-not (Test-ScenarioKnown $TaskScenarios[0])) {
        Write-Warning 'The published conformance package has no tasks scenarios yet; pass -ConformancePath to run them'
    }
    else {
        foreach ($Scenario in $TaskScenarios) {
            Write-Host "== $Scenario"
            if (-not (Test-ConformancePassed @('server', '--url', $Url, '--scenario', $Scenario, '--expected-failures', $Baseline))) {
                $Failures += $Scenario
            }
        }
    }
}
finally {
    if (-not $Server.HasExited) {
        Stop-Process -Id $Server.Id -Force
    }
    $Server.WaitForExit()
    Remove-Item -Recurse -Force $WorkFolder
}

if ($Failures.Count -gt 0) {
    Write-Host "Conformance failed: $($Failures -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'Conformance passed (known failures are listed in conformance-baseline.yml)' -ForegroundColor Green
exit 0
