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

set OUTPUT_DIR=.\tests\%PLATFORM%\%CONFIG%
if not exist %OUTPUT_DIR% mkdir %OUTPUT_DIR%

set UNIT_PATHS=src;src\Managers;src\Server;src\Tools;src\Core;src\Protocol;src\Libraries;src\Resources;tests
set NAMESPACES=Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap

echo Building MCPServer.Tests - %CONFIG% %PLATFORM%
echo.

if "%PLATFORM%"=="Win32" (
    !DCC32! -B -H -W -NS%NAMESPACES% -U"!DELPHI_PATH!\lib\Win32\debug";%UNIT_PATHS% -I"!DUNITX_PATH!" -E%OUTPUT_DIR% -N0%OUTPUT_DIR% -D%CONFIG% tests\MCPServer.Tests.dpr
    goto :CheckBuildResult
) else if "%PLATFORM%"=="Win64" (
    !DCC64! -B -H -W -NS%NAMESPACES% -U"!DELPHI_PATH!\lib\Win64\debug";%UNIT_PATHS% -I"!DUNITX_PATH!" -E%OUTPUT_DIR% -N0%OUTPUT_DIR% -D%CONFIG% tests\MCPServer.Tests.dpr
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
echo Output: %OUTPUT_DIR%\MCPServer.Tests.exe

endlocal
