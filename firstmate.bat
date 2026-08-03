@echo off
rem firstmate.bat - Windows front door for the Firstmate launcher in WSL.
rem
rem Double-click this file, or run:
rem   firstmate.bat [fm-launch.sh arguments...]
rem
rem The repository path is passed to wsl.exe through --cd.  Appending "." keeps
rem the quoted Windows path from ending in a backslash, including when the path
rem contains spaces.  --exec selects /bin/bash directly instead of depending on
rem the WSL distribution's login shell or profile.
setlocal EnableExtensions DisableDelayedExpansion

if defined FIRSTMATE_WSL_EXE (
  set "FIRSTMATE_WSL_COMMAND=%FIRSTMATE_WSL_EXE%"
) else (
  set "FIRSTMATE_WSL_COMMAND=%SystemRoot%\System32\wsl.exe"
)

if not exist "%FIRSTMATE_WSL_COMMAND%" (
  >&2 echo Firstmate could not find WSL at "%FIRSTMATE_WSL_COMMAND%".
  >&2 echo Install it with "wsl --install", restart Windows if prompted, then retry.
  if not defined FIRSTMATE_NO_PAUSE pause
  endlocal & exit /b 127
)

if defined FIRSTMATE_WSL_EXE (
  rem Test seam: a batch-command fake needs CALL so control returns here.
  call "%FIRSTMATE_WSL_COMMAND%" --cd "%~dp0." --exec /bin/bash ./bin/fm-wsl-entry.sh %*
) else (
  "%FIRSTMATE_WSL_COMMAND%" --cd "%~dp0." --exec /bin/bash ./bin/fm-wsl-entry.sh %*
)
set "FIRSTMATE_EXIT=%ERRORLEVEL%"

if not "%FIRSTMATE_EXIT%"=="0" (
  >&2 echo.
  >&2 echo Firstmate could not start through WSL. Exit status: %FIRSTMATE_EXIT%
  >&2 echo Review the error above. If WSL itself did not start, run "wsl --install" and retry.
  if not defined FIRSTMATE_NO_PAUSE pause
)

endlocal & exit /b %FIRSTMATE_EXIT%
