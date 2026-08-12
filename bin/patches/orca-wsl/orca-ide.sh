#!/usr/bin/env bash
# firstmate-orca-wsl-bridge-patch-v1
# Orca managed WSL CLI launcher (template installed by bin/fm-orca-wsl-cli.sh).
# Prefers PowerShell 7 when present; falls back to Windows PowerShell 5.1.
# Placeholders replaced at apply time:
#   @ORCA_WIN_LAUNCHER@  Windows path to orca.exe
#   @ORCA_BRIDGE_PS1@    absolute Linux path to orca-wsl-bridge.ps1
set -euo pipefail
# Orca managed WSL CLI launcher
ORCA_WIN_LAUNCHER='@ORCA_WIN_LAUNCHER@'
ORCA_BRIDGE_PS1='@ORCA_BRIDGE_PS1@'
if command -v pwsh.exe >/dev/null 2>&1; then
  ORCA_POWERSHELL=pwsh.exe
elif [ -x '/mnt/c/Program Files/PowerShell/7/pwsh.exe' ]; then
  ORCA_POWERSHELL='/mnt/c/Program Files/PowerShell/7/pwsh.exe'
elif command -v powershell.exe >/dev/null 2>&1; then
  ORCA_POWERSHELL=powershell.exe
elif [ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
  ORCA_POWERSHELL=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
else
  echo "Orca WSL CLI requires Windows interop and could not find powershell.exe." >&2
  exit 1
fi
# Why: a shell can outlive a deleted worktree; keep explicit CLI selectors and
# help usable, and repair cwd before any WSL interop tool tries to resolve it.
ORCA_WSL_CWD=$(pwd -P 2>/dev/null) || {
  ORCA_WSL_CWD=/
  cd /
}
ORCA_BRIDGE_PS1_WIN=$(wslpath -w "$ORCA_BRIDGE_PS1")
ORCA_WSL_CWD_WIN=$(wslpath -w "$ORCA_WSL_CWD")
exec "$ORCA_POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "$ORCA_BRIDGE_PS1_WIN" "$ORCA_WIN_LAUNCHER" -WslCwd "$ORCA_WSL_CWD_WIN" "$@"
