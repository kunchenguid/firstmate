@echo off
rem Native Windows entrypoint for the tracked Codex project hooks.
rem Usage: fm-codex-hook.cmd sessionstart^|arm-pretool^|cd-pretool^|stop
setlocal
set "FM_CODEX_BASH="

if exist "%ProgramFiles%\Git\bin\bash.exe" set "FM_CODEX_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined FM_CODEX_BASH if defined LocalAppData if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "FM_CODEX_BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined FM_CODEX_BASH for /f "delims=" %%G in ('where git.exe 2^>nul') do if not defined FM_CODEX_BASH if exist "%%~dpG..\bin\bash.exe" set "FM_CODEX_BASH=%%~dpG..\bin\bash.exe"
if not defined FM_CODEX_BASH (
  echo Firstmate Codex hook requires Git for Windows with Git Bash. 1>&2
  exit /b 1
)

set "MSYS2_ARG_CONV_EXCL="
"%FM_CODEX_BASH%" --noprofile --norc "%~dp0fm-codex-hook.sh" "%~1"
exit /b %errorlevel%
