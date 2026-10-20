@echo off
setlocal EnableDelayedExpansion

echo Delphi MCP Server Test Build Script (DUnitX)
echo ============================================
echo.

REM Set Delphi installation path - adjust if needed (same as build.bat). Set
REM DELPHI_PATH yourself before calling this script to build with another Delphi
REM version, for example Studio\22.0 for Delphi 11 Alexandria.
if "%DELPHI_PATH%"=="" set DELPHI_PATH=C:\Program Files (x86)\Embarcadero\Studio\37.0

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

set OUTPUT_DIR=.\tests\%PLATFORM%\%CONFIG%
if not exist %OUTPUT_DIR% mkdir %OUTPUT_DIR%

REM Locate TaurusTLS the same way build.bat does; MCPServer.IdHTTPServer needs it.
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
    echo Warning: TaurusTLS not found. The HTTP server unit needs it.
)

set UNIT_PATHS=src;src\Managers;src\Server;src\Tools;src\Core;src\Protocol;src\Libraries;src\Resources;src\Prompts;tests!EXTRA_UNITS!
set NAMESPACES=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap

echo Building MCPServer.Tests - %CONFIG% %PLATFORM%
echo.

if "%PLATFORM%"=="Win32" (
    !DCC32! -B -H -W -NS%NAMESPACES% -U"!DELPHI_PATH!\lib\Win32\debug";%UNIT_PATHS% -Isrc!EXTRA_INCLUDES!;"!DUNITX_PATH!" !EXTRA_RES! -E%OUTPUT_DIR% -N0%OUTPUT_DIR% -D%CONFIG% tests\MCPServerTests.dpr
    goto :CheckBuildResult
) else if "%PLATFORM%"=="Win64" (
    !DCC64! -B -H -W -NS%NAMESPACES% -U"!DELPHI_PATH!\lib\Win64\debug";%UNIT_PATHS% -Isrc!EXTRA_INCLUDES!;"!DUNITX_PATH!" !EXTRA_RES! -E%OUTPUT_DIR% -N0%OUTPUT_DIR% -D%CONFIG% tests\MCPServerTests.dpr
    goto :CheckBuildResult
) else (
    echo ERROR: Invalid platform. Use Win32 or Win64
    echo.
    echo Usage: build-tests.bat [Config] [Platform]
    echo   Config: Debug or Release (default: Debug)
    echo   Platform: Win32 or Win64 (default: Win32)
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

call :StdioOnlyCheck
if errorlevel 1 exit /b 1

endlocal
exit /b 0

REM A program that serves stdio only must build without TaurusTLS, link no
REM Indy unit and answer over stdio. tests\StdioOnly\StdioOnlyHost.dpr is built
REM with no TaurusTLS on the search path, its detailed map file must name no
REM Indy or TaurusTLS unit, and the program must answer an echo call.
:StdioOnlyCheck
set STDIO_ONLY_DIR=%OUTPUT_DIR%\StdioOnly
if not exist %STDIO_ONLY_DIR% mkdir %STDIO_ONLY_DIR%
set STDIO_ONLY_UNITS=src;src\Managers;src\Server;src\Tools;src\Core;src\Protocol;src\Resources;src\Prompts
set STDIO_ONLY_DCC=!DCC32!
if "%PLATFORM%"=="Win64" set STDIO_ONLY_DCC=!DCC64!

echo.
echo Building the stdio-only host check without TaurusTLS
!STDIO_ONLY_DCC! -B -H -W -GD -NS%NAMESPACES% -U"!DELPHI_PATH!\lib\%PLATFORM%\debug";%STDIO_ONLY_UNITS% -Isrc -E%STDIO_ONLY_DIR% -N0%STDIO_ONLY_DIR% -D%CONFIG% tests\StdioOnly\StdioOnlyHost.dpr
if errorlevel 1 (
    echo Stdio-only host check FAILED: a stdio-only program needs more than MCPServer.StdioHost
    exit /b 1
)

findstr /C:"M=Id" /C:"M=TaurusTLS" %STDIO_ONLY_DIR%\StdioOnlyHost.map >nul
if not errorlevel 1 (
    echo Stdio-only host check FAILED: an Indy or TaurusTLS unit is linked
    exit /b 1
)

echo Stdio-only host check: no Indy and no TaurusTLS unit linked

%STDIO_ONLY_DIR%\StdioOnlyHost.exe
if errorlevel 1 (
    echo Stdio-only host check FAILED: the stdio-only host did not answer
    exit /b 1
)

exit /b 0
