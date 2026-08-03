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
