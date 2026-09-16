@echo off
setlocal EnableDelayedExpansion

echo Delphi MCP Server Build Script (Indy HTTP Server)
echo ==================================================
echo.

REM Check if MCPServer.exe is running and kill it
tasklist /FI "IMAGENAME eq MCPServer.exe" 2>NUL | findstr /I "MCPServer.exe" >NUL 2>&1
if "%ERRORLEVEL%"=="0" (
    echo MCPServer.exe is running. Terminating...
    taskkill /F /IM MCPServer.exe >NUL 2>&1
    timeout /t 1 /nobreak >NUL
)

REM Set Delphi installation path - adjust if needed. Set DELPHI_PATH yourself
REM before calling this script to build with another Delphi version, for example
REM Studio\22.0 for Delphi 11 Alexandria.
if "%DELPHI_PATH%"=="" set DELPHI_PATH=C:\Program Files (x86)\Embarcadero\Studio\37.0

REM Check if dcc32 exists
if not exist "!DELPHI_PATH!\bin\dcc32.exe" (
    echo ERROR: dcc32.exe not found at !DELPHI_PATH!\bin\
    echo Please update DELPHI_PATH in this script to point to your Delphi installation
    exit /b 1
)

REM Set compiler paths
set DCC32="!DELPHI_PATH!\bin\dcc32.exe"
set DCC64="!DELPHI_PATH!\bin\dcc64.exe"
set MSBUILD="!DELPHI_PATH!\bin\rsvars.bat"

REM Create output directories
if not exist Win32\Debug mkdir Win32\Debug
if not exist Win64\Debug mkdir Win64\Debug
if not exist Win32\Release mkdir Win32\Release
if not exist Win64\Release mkdir Win64\Release
if not exist Linux64\Debug mkdir Linux64\Debug
if not exist Linux64\Release mkdir Linux64\Release

REM Build configuration
set CONFIG=%1
if "%CONFIG%"=="" set CONFIG=Debug

REM Platform
set PLATFORM=%2
if "%PLATFORM%"=="" set PLATFORM=Win32

echo Building MCPServer - %CONFIG% %PLATFORM%
echo.

REM Locate TaurusTLS. Set TAURUS_PATH yourself to override; otherwise the
REM highest version installed in the CatalogRepository of this Studio release
REM is used, so a GetIt update is picked up without editing this script.
REM Note: OpenSSL 4.x needs TaurusTLS 1.0.5.42 or newer.
for %%i in ("!DELPHI_PATH!") do set STUDIO_VER=%%~nxi
set CATALOG_DIR=%USERPROFILE%\Documents\Embarcadero\Studio\!STUDIO_VER!\CatalogRepository

if not "%TAURUS_PATH%"=="" goto :TaurusResolved

for /f "usebackq delims=" %%d in (`powershell -NoProfile -Command "$root = '!CATALOG_DIR!\TaurusTLS'; if (Test-Path $root) { Get-ChildItem $root -Directory ^| Where-Object { Test-Path (Join-Path $_.FullName 'Source') } ^| Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } ^| Select-Object -Last 1 -ExpandProperty FullName }"`) do set "TAURUS_PATH=%%d\Source"

if "!TAURUS_PATH!"=="" if exist "!CATALOG_DIR!\TaurusTLS-12\Source" set "TAURUS_PATH=!CATALOG_DIR!\TaurusTLS-12\Source"

:TaurusResolved
if not "!TAURUS_PATH!"=="" (
    echo Using TaurusTLS: !TAURUS_PATH!
    set "EXTRA_UNITS=;!TAURUS_PATH!"
    set "EXTRA_INCLUDES=;!TAURUS_PATH!"
    set "EXTRA_RES=-R!TAURUS_PATH!"
) else (
    set "EXTRA_UNITS="
    set "EXTRA_INCLUDES="
    set "EXTRA_RES="
    echo Warning: TaurusTLS not found. SSL/TLS support may be limited.
)

if "%PLATFORM%"=="Win32" (
    !DCC32! -B -H -W -NSWinapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap -U"!DELPHI_PATH!\lib\Win32\debug";src;src\Managers;src\Server;src\Tools;src\Core;src\Protocol;src\Libraries;src\Resources;src\Prompts!EXTRA_UNITS! -Isrc!EXTRA_INCLUDES! !EXTRA_RES! -E.\%PLATFORM%\%CONFIG% -N0.\%PLATFORM%\%CONFIG% -LE.\%PLATFORM%\%CONFIG% -LN.\%PLATFORM%\%CONFIG% -D%CONFIG% src\MCPServer.dpr
    goto :CheckBuildResult
) else if "%PLATFORM%"=="Win64" (
    !DCC64! -B -H -W -NSWinapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win;System;Xml;Data;Datasnap;Web;Soap -U"!DELPHI_PATH!\lib\Win64\debug";src;src\Managers;src\Server;src\Tools;src\Core;src\Protocol;src\Libraries;src\Resources;src\Prompts!EXTRA_UNITS! -Isrc!EXTRA_INCLUDES! !EXTRA_RES! -E.\%PLATFORM%\%CONFIG% -N0.\%PLATFORM%\%CONFIG% -LE.\%PLATFORM%\%CONFIG% -LN.\%PLATFORM%\%CONFIG% -D%CONFIG% src\MCPServer.dpr
    goto :CheckBuildResult
) else if "%PLATFORM%"=="Linux64" (
    REM Use MSBuild for Linux64
    if not exist !MSBUILD! (
        echo ERROR: rsvars.bat not found at !MSBUILD!
        echo Linux64 build requires proper Delphi installation with Linux platform
        exit /b 1
    )
    echo Using MSBuild for Linux64 platform...
    REM Store values before calling rsvars.bat which might reset them
    set STORED_PLATFORM=%PLATFORM%
    set STORED_CONFIG=%CONFIG%
    call !MSBUILD!
    msbuild src\MCPServer.dproj /t:Build /p:Config=!STORED_CONFIG! /p:Platform=Linux64
    REM Restore values for final output message
    set PLATFORM=!STORED_PLATFORM!
    set CONFIG=!STORED_CONFIG!
    goto :CheckBuildResult
) else (
    echo ERROR: Invalid platform. Use Win32, Win64, or Linux64
    echo.
    echo Usage: build.bat [Config] [Platform]
    echo   Config: Debug or Release (default: Debug)
    echo   Platform: Win32, Win64, or Linux64 (default: Win32)
    echo.
    echo Examples:
    echo   build.bat                    - Build Debug Win32
    echo   build.bat Release Win64      - Build Release Win64
    echo   build.bat Debug Linux64      - Build Debug Linux64
    exit /b 1
)

:CheckBuildResult
if %ERRORLEVEL% neq 0 (
    echo.
    echo Build FAILED!
    exit /b %ERRORLEVEL%
)

echo.
echo Build completed successfully!
if "%PLATFORM%"=="Linux64" (
    echo Output: %PLATFORM%\%CONFIG%\MCPServer
) else (
    echo Output: %PLATFORM%\%CONFIG%\MCPServer.exe
)

endlocal