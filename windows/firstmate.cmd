@echo off
setlocal
if "%~1"=="" goto launch_default
if not "%~2"=="" goto unsupported
if /i "%~1"=="--codex" goto launch_codex
if /i "%~1"=="--pi" goto launch_pi
if /i "%~1"=="--grok" goto launch_grok
if /i "%~1"=="--claude" goto launch_claude
if /i "%~1"=="--opencode" goto launch_opencode
goto unsupported

:launch_default
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0firstmate.ps1"
exit /b %ERRORLEVEL%
:launch_codex
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0firstmate.ps1" --codex
exit /b %ERRORLEVEL%
:launch_pi
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0firstmate.ps1" --pi
exit /b %ERRORLEVEL%
:launch_grok
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0firstmate.ps1" --grok
exit /b %ERRORLEVEL%
:launch_claude
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0firstmate.ps1" --claude
exit /b %ERRORLEVEL%
:launch_opencode
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0firstmate.ps1" --opencode
exit /b %ERRORLEVEL%
:unsupported
>&2 echo error: firstmate.cmd accepts only one harness selector; use firstmate.ps1 for model and effort values
exit /b 2
