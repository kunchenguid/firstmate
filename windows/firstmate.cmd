@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0firstmate.ps1" %*
exit /b %ERRORLEVEL%
