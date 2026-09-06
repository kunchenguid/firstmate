@echo off
rem Firstmate native core shim (Windows). Executes the compiled TS CLI.
setlocal
set "FM_BIN_DIR=%~dp0"
node "%FM_BIN_DIR%fm.mjs" %*
exit /b %ERRORLEVEL%
