@echo off
setlocal EnableDelayedExpansion

echo Delphi MCP Server Test Build Script (DUnitX)
echo ============================================
echo.

REM Set Delphi installation path - adjust if needed (same as build.bat)
set DELPHI_PATH=C:\Program Files (x86)\Embarcadero\Studio\37.0

if not exist "!DELPHI_PATH!\bin\dcc32.exe" (
    echo ERROR: dcc32.exe not found at !DELPHI_PATH!\bin\
    echo Please update DELPHI_PATH in this script to point to your Delphi installation
    exit /b 1
)

set DCC32="!DELPHI_PATH!\bin\dcc32.exe"
set DCC64="!DELPHI_PATH!\bin\dcc64.exe"

REM DUnitX ships with RAD Studio; the include path is needed for DUnitX.inc
set DUNITX_PATH=!DELPHI_PATH!\source\DUnitX

set CONFIG=%1
if "%CONFIG%"=="" set CONFIG=Debug

set PLATFORM=%2
if "%PLATFORM%"=="" set PLATFORM=Win32

REM TLS variant. Pass NO_TAURUS_TLS as the third argument, or set the
REM NO_TAURUS_TLS environment variable to any value, to build the suite against
REM the Indy OpenSSL handler that ships with Delphi. TaurusTLS is then neither
REM resolved nor put on any search path.
if /I "%3"=="NO_TAURUS_TLS" set NO_TAURUS_TLS=1

set OUTPUT_DIR=.\tests\%PLATFORM%\%CONFIG%
if not exist %OUTPUT_DIR% mkdir %OUTPUT_DIR%

REM Locate TaurusTLS the same way build.bat does; MCPServer.IdHTTPServer needs it
REM unless NO_TAURUS_TLS is set.
set TLS_DEFINES=
if not "!NO_TAURUS_TLS!"=="" (
    set TAURUS_PATH=
    set TLS_DEFINES=-DNO_TAURUS_TLS
    echo TaurusTLS disabled, building against the Indy OpenSSL handler.
    goto :TaurusResolved
)

for %%i in ("!DELPHI_PATH!") do set STUDIO_VER=%%~nxi
set CATALOG_DIR=%USERPROFILE%\Documents\Embarcadero\Studio\!STUDIO_VER!\CatalogRepository

if not "%TAURUS_PATH%"=="" goto :TaurusResolved

for /f "usebackq delims=" %%d in (`powershell -NoProfile -Command "$root = '!CATALOG_DIR!\TaurusTLS'; if (Test-Path $root) { Get-ChildItem $root -Directory ^| Where-Object { Test-Path (Join-Path $_.FullName 'Source') } ^| Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } ^| Select-Object -Last 1 -ExpandProperty FullName }"`) do set "TAURUS_PATH=%%d\Source"

if "!TAURUS_PATH!"=="" if exist "!CATALOG_DIR!\TaurusTLS-12\Source" set "TAURUS_PATH=!CATALOG_DIR!\TaurusTLS-12\Source"

:TaurusResolved
if not "!TAURUS_PATH!"=="" (
    set "EXTRA_UNITS=;!TAURUS_PATH!"
    set "EXTRA_INCLUDES=;!TAURUS_PATH!"
    set "EXTRA_RES=-R!TAURUS_PATH!"
) else (
    set "EXTRA_UNITS="
    set "EXTRA_INCLUDES="
    set "EXTRA_RES="
    if "!TLS_DEFINES!"=="" echo Warning: TaurusTLS not found. The HTTP server unit needs it.
)

set UNIT_PATHS=src;src\Managers;src\Server;src\Tools;src\Core;src\Protocol;src\Libraries;src\Resources;src\Prompts;src\Client;tests!EXTRA_UNITS!
set NAMESPACES=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap

echo Building MCPServer.Tests - %CONFIG% %PLATFORM%
echo.

if "%PLATFORM%"=="Win32" (
    !DCC32! -B -H -W -NS%NAMESPACES% -U"!DELPHI_PATH!\lib\Win32\debug";%UNIT_PATHS% -Isrc!EXTRA_INCLUDES!;"!DUNITX_PATH!" !EXTRA_RES! -E%OUTPUT_DIR% -N0%OUTPUT_DIR% -D%CONFIG% !TLS_DEFINES! tests\MCPServerTests.dpr
    goto :CheckBuildResult
) else if "%PLATFORM%"=="Win64" (
    !DCC64! -B -H -W -NS%NAMESPACES% -U"!DELPHI_PATH!\lib\Win64\debug";%UNIT_PATHS% -Isrc!EXTRA_INCLUDES!;"!DUNITX_PATH!" !EXTRA_RES! -E%OUTPUT_DIR% -N0%OUTPUT_DIR% -D%CONFIG% !TLS_DEFINES! tests\MCPServerTests.dpr
    goto :CheckBuildResult
) else (
    echo ERROR: Invalid platform. Use Win32 or Win64
    echo.
    echo Usage: build-tests.bat [Config] [Platform] [NO_TAURUS_TLS]
    echo   Config: Debug or Release (default: Debug)
    echo   Platform: Win32 or Win64 (default: Win32)
    echo   NO_TAURUS_TLS: build without TaurusTLS, on the Indy OpenSSL handler
    exit /b 1
)

:CheckBuildResult
if %ERRORLEVEL% neq 0 (
    echo.
    echo Test build FAILED!
    exit /b %ERRORLEVEL%
)

echo.
echo Test build completed successfully!
echo Output: %OUTPUT_DIR%\MCPServerTests.exe

endlocal
