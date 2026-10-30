#!/usr/bin/env bash
# Record the worktree entered by treehouse get, then start the requested shell.
# Usage: FM_TREEHOUSE_READY_FILE=<path> FM_TREEHOUSE_REAL_SHELL=<shell> fm-treehouse-shell.sh [shell-args...]
set -eu

ready=${FM_TREEHOUSE_READY_FILE:?}
real_shell=${FM_TREEHOUSE_REAL_SHELL:?}
tmp="$ready.${BASHPID:-$$}"
trap 'rm -f -- "$tmp"' EXIT
pwd -P > "$tmp"
mv -f -- "$tmp" "$ready"
trap - EXIT
export SHELL=$real_shell
unset FM_TREEHOUSE_READY_FILE FM_TREEHOUSE_REAL_SHELL
exec "$real_shell" "$@"
