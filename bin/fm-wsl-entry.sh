#!/usr/bin/env bash
# fm-wsl-entry.sh - deterministic WSL-side entry for repository-root
# firstmate.bat.
#
# Usage:
#   bin/fm-wsl-entry.sh [fm-launch.sh arguments...]
#
# firstmate.bat starts /bin/bash directly with the repository as WSL's working
# directory.  This script then resolves the repository from its own location,
# changes there, and replaces itself with bin/fm-launch.sh.  It neither depends
# on the Windows launch directory nor starts a second WSL process.  Every
# argument and the launcher's exit status pass through unchanged.
#
# Because that launch deliberately bypasses the login shell, this script owns the
# one piece of environment the launcher cannot do without: a PATH that resolves
# the harnesses the captain actually installed.  WSL hands a --exec session only
# the system directories plus Windows interop, so the menu would otherwise probe
# a PATH no interactive session ever has and report every user-installed harness
# as missing.  The fix stays a filesystem fact rather than a profile evaluation:
# ~/bin and ~/.local/bin are exactly what the distribution's stock ~/.profile
# prepends, and every harness installer Firstmate supports targets ~/.local/bin,
# so reproducing those two directories restores interactive parity without
# inheriting a login profile's arbitrary side effects, ordering, or failure
# modes in a non-interactive launch.  Only existing directories are added, only
# once, ahead of the system tail exactly as a login shell orders them, and
# nothing already on the inherited PATH is removed or reordered.
set -u

fm_wsl_entry_error() {
  printf 'fm-wsl-entry: %s\n' "$1" >&2
}

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || {
  fm_wsl_entry_error "cannot resolve the Firstmate bin directory."
  fm_wsl_entry_error "Move the repository to a path WSL can read, then retry firstmate.bat."
  exit 1
}
FM_ROOT=$(CDPATH='' cd "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || {
  fm_wsl_entry_error "cannot resolve the Firstmate repository root."
  fm_wsl_entry_error "Move the repository to a path WSL can read, then retry firstmate.bat."
  exit 1
}
LAUNCHER="$FM_ROOT/bin/fm-launch.sh"

# fm_wsl_entry_prepend_bin <directory>: put an existing directory at the head of
# PATH unless it is already there.
fm_wsl_entry_prepend_bin() {
  local directory=$1
  [ -d "$directory" ] || return 0
  case ":${PATH-}:" in
    *":$directory:"*) return 0 ;;
  esac
  PATH="$directory${PATH:+:$PATH}"
}

if [ -n "${HOME-}" ]; then
  fm_wsl_entry_prepend_bin "$HOME/bin"
  fm_wsl_entry_prepend_bin "$HOME/.local/bin"
  export PATH
fi

if [ ! -r "$LAUNCHER" ]; then
  fm_wsl_entry_error "cannot read $LAUNCHER."
  fm_wsl_entry_error "Update this Firstmate copy so bin/fm-launch.sh is present, then retry firstmate.bat."
  exit 1
fi

if ! cd "$FM_ROOT"; then
  fm_wsl_entry_error "cannot enter the Firstmate repository at $FM_ROOT."
  fm_wsl_entry_error "Move the repository to a path WSL can read, then retry firstmate.bat."
  exit 1
fi

exec /bin/bash "$LAUNCHER" "$@"
