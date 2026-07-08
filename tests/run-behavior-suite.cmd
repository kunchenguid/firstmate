@echo off
setlocal

set "GIT_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%GIT_BASH%" set "GIT_BASH=%ProgramFiles%\Git\usr\bin\bash.exe"
if not exist "%GIT_BASH%" set "GIT_BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not exist "%GIT_BASH%" set "GIT_BASH=bash"

"%GIT_BASH%" -lc "command -v tmux >/dev/null 2>&1 && tmux -V || echo 'tmux not found; tmux e2e tests will self-skip' >&2; rc=0; for t in tests/*.test.sh; do echo \"== $t ==\"; bash \"$t\" || rc=1; done; exit \"$rc\""
exit /b %ERRORLEVEL%
