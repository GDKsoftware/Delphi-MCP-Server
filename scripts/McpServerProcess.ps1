# Helper functions for scripts that need a running server executable.
# Dot-source this file: . "$PSScriptRoot\McpServerProcess.ps1"

function Get-RepoRoot {
    return Split-Path -Parent $PSScriptRoot
}

function Invoke-ServerBuild {
    param(
        [Parameter(Mandatory)] [string]$Configuration,
        [Parameter(Mandatory)] [string]$Platform
    )
    $repoRoot = Get-RepoRoot
    Write-Host "Building server ($Configuration $Platform)..."
    & cmd.exe /c "cd /d `"$repoRoot`" && .\build.bat $Configuration $Platform"
    if ($LASTEXITCODE -ne 0) {
        throw "Server build failed with exit code $LASTEXITCODE"
    }
}

function Wait-McpPort {
    param(
        [Parameter(Mandatory)] [int]$Port,
        [int]$TimeoutSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $Port)
            if ($client.Connected) { return $true }
        } catch {
        } finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

<#
.SYNOPSIS
    Starts the server executable on the given port and waits for it.

.DESCRIPTION
    The server reads settings.ini next to its executable, so a temporary one
    with the requested port is written. Stop-McpServer restores the original.
    Returns a handle object for Stop-McpServer.
#>
function Start-McpServer {
    param(
        [Parameter(Mandatory)] [string]$ServerExe,
        [Parameter(Mandatory)] [int]$Port,
        [Parameter(Mandatory)] [string]$LogDir
    )

    $ServerExe = (Resolve-Path $ServerExe).Path
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

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $process = Start-Process -FilePath $ServerExe -WorkingDirectory $exeDir -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $LogDir 'server.log') `
        -RedirectStandardError (Join-Path $LogDir 'server.err.log')

    $handle = [pscustomobject]@{
        Process        = $process
        SettingsFile   = $settingsFile
        SettingsBackup = $settingsBackup
        Port           = $Port
        Url            = "http://127.0.0.1:$Port/mcp"
    }

    if (-not (Wait-McpPort -Port $Port)) {
        Stop-McpServer $handle
        throw "Server did not open port $Port within the timeout (see $LogDir\server.log)"
    }
    return $handle
}

function Stop-McpServer {
    param([Parameter(Mandatory)] $Handle)

    if ($Handle.Process -and -not $Handle.Process.HasExited) {
        Stop-Process -Id $Handle.Process.Id -Force
        $Handle.Process.WaitForExit(5000) | Out-Null
    }
    if ($null -ne $Handle.SettingsBackup) {
        Set-Content -Path $Handle.SettingsFile -Value $Handle.SettingsBackup -NoNewline
    } else {
        Remove-Item $Handle.SettingsFile -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Runs a native command line through cmd.exe with both streams in a log file.

.DESCRIPTION
    Windows PowerShell 5.1 turns stderr lines of native commands into error
    records, which aborts scripts that run with ErrorActionPreference Stop.
    Writing the command line to a batch file and redirecting inside cmd.exe
    keeps the output intact. Returns the exit code.
#>
function Invoke-NativeToLog {
    param(
        [Parameter(Mandatory)] [string]$CommandLine,
        [Parameter(Mandatory)] [string]$LogFile,
        [Parameter(Mandatory)] [string]$WorkingDirectory
    )
    $batchFile = [System.IO.Path]::ChangeExtension($LogFile, '.cmd')
    $content = @(
        '@echo off'
        "cd /d `"$WorkingDirectory`""
        "$CommandLine > `"$LogFile`" 2>&1"
        'exit /b %ERRORLEVEL%'
    )
    Set-Content -Path $batchFile -Value $content -Encoding ASCII
    $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$batchFile`"") -PassThru -NoNewWindow -Wait
    return $process.ExitCode
}

function Assert-NodeTooling {
    $repoRoot = Get-RepoRoot
    if (-not (Test-Path (Join-Path $repoRoot 'node_modules\@modelcontextprotocol'))) {
        Write-Host 'Installing pinned Node tooling (npm install)...'
        Push-Location $repoRoot
        try {
            & npm.cmd install --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
        } finally {
            Pop-Location
        }
    }
}
