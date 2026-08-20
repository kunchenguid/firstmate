#!/usr/bin/env bash
# fm-lite-install.sh - install the standalone First Mate Lite CLI.
#
# Usage:
#   fm-lite-install.sh [<destination-directory>]
#
# The default destination is $HOME/.local/bin.
# The installer copies only bin/fm-lite, so the installed command has no
# runtime dependency on a Firstmate clone, FM_HOME, or Firstmate services.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -gt 1 ]; then
  printf 'usage: fm-lite-install.sh [<destination-directory>]\n' >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  destination=$1
else
  [ -n "${HOME:-}" ] || {
    printf 'fm-lite-install.sh: HOME is required for the default destination\n' >&2
    exit 1
  }
  destination="$HOME/.local/bin"
fi

mkdir -p "$destination"
install -m 0755 "$SCRIPT_DIR/fm-lite" "$destination/fm-lite"
printf 'Installed fm-lite to %s/fm-lite\n' "$destination"
