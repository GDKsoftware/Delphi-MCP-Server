@echo off
REM Runs the MCP conformance suite against a build of this server; see
REM conformance.ps1 for the parameters, for example:
REM   conformance.bat -Platform Win32 -Config Debug -ConformancePath C:\dev\conformance
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0conformance.ps1" %*
exit /b %ERRORLEVEL%
