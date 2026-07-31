#!/usr/bin/env bash
# bin/backends/psmux.sh - the psmux session-provider adapter (EXPERIMENTAL, Windows).
#
# psmux (https://github.com/psmux/psmux, winget marlocarlo.psmux) is a native
# Windows tmux-compatible multiplexer built on ConPTY - no WSL, no MSYS
# multiplexer, no admin rights. It implements the tmux subcommands firstmate's
# reference adapter drives (new-session, new-window, send-keys, capture-pane -p,
# has-session, kill-window, display-message, set-option, list-windows), so this
# backend REUSES bin/backends/tmux.sh and bin/fm-tmux-lib.sh unchanged by sourcing
# the adapter with FM_TMUX_CMD pointed at the resolved psmux binary. Only two
# Windows-specific concerns live here: resolving the binary (winget installs it
# into a hashed package dir that is off the Git Bash PATH until the shell
# restarts) and forcing the session shell to bash (psmux defaults new sessions to
# PowerShell, which cannot run firstmate's bash-syntax sends). Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# docs/psmux-backend.md owns setup, limits, and the verification contract.

# fm_backend_psmux_bin: the psmux executable. PATH first, then the winget package
# directory (its name carries a version hash, so glob for it), so a psmux
# installed in the current session works before the shell that installed it is
# restarted. Prints the path and returns 0, or returns 1 when none is found.
fm_backend_psmux_bin() {
  local candidate
  if candidate=$(command -v psmux 2>/dev/null); then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in \
    "$HOME"/AppData/Local/Microsoft/WinGet/Packages/marlocarlo.psmux_*/psmux.exe; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

if ! FM_TMUX_CMD=$(fm_backend_psmux_bin); then
  echo "error: psmux backend selected but no psmux binary found" \
       "(install: winget install marlocarlo.psmux)" >&2
  return 1
fi
# Not exported: tmux.sh runs in this same sourced shell, and command-substitution
# subshells inherit it regardless. Keeping it unexported avoids leaking the psmux
# path into launched child processes.

# Reuse the reference tmux adapter's logic against the resolved psmux binary.
# shellcheck source=bin/backends/tmux.sh
. "$FM_BACKEND_LIB_DIR/backends/tmux.sh"

# fm_backend_psmux_bash_win: bash.exe as a Windows-style path psmux can launch,
# or empty when it cannot be resolved.
fm_backend_psmux_bash_win() {
  local bash_bin
  bash_bin=$(command -v bash) || return 1
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$bash_bin" 2>/dev/null
  else
    printf '%s\n' "$bash_bin"
  fi
}

# fm_backend_psmux_create_task: psmux differs from tmux here in two ways, both
# verified against the real binary. (1) Its new-window does not print the created
# window id (tmux's `-P -F` is ignored), so the id is resolved afterwards via
# list-windows (ids are @N). (2) psmux resolves the shell against the Windows
# PATH, which lacks bash, and otherwise defaults new windows to PowerShell, which
# cannot run firstmate's bash-syntax sends - so the window is launched with the
# full path to bash.exe via `-- <bash> -li`. Mirrors the tmux create_task
# contract otherwise: refuse a duplicate name, pin the name against auto-rename,
# and print the stable window id. The spawn path calls this for the psmux backend.
fm_backend_psmux_create_task() {  # <session> <window-name> <proj-abs> -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 wid bash_win
  if "$FM_TMUX_CMD" list-windows -t "$ses" -F '#{window_name}' 2>/dev/null | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  bash_win=$(fm_backend_psmux_bash_win) || {
    echo "error: psmux backend could not resolve bash.exe for the task window" >&2
    return 1
  }
  "$FM_TMUX_CMD" new-window -d -t "$ses" -n "$wname" -c "$proj_abs" -- "$bash_win" -li \
    >/dev/null 2>&1 || return 1
  wid=$("$FM_TMUX_CMD" list-windows -t "$ses" -F '#{window_id}|#{window_name}' 2>/dev/null \
    | awk -F'|' -v n="$wname" '$2 == n { print $1; exit }')
  [ -n "$wid" ] || return 1
  "$FM_TMUX_CMD" set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  "$FM_TMUX_CMD" set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_psmux_current_path: psmux reports #{pane_current_path} as a Windows
# path (C:\...), but firstmate compares worktree paths in MSYS form (fm-spawn's
# PROJ_ABS_REAL is a `pwd -P` /c/... path). Normalize with `cygpath -u` so the
# worktree-detection poll in fm-spawn can match. Empty (like the tmux one) on any
# read failure.
fm_backend_psmux_current_path() {  # <target>
  local win
  win=$(fm_backend_tmux_current_path "$1") || return 0
  [ -n "$win" ] || return 0
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$win" 2>/dev/null || printf '%s\n' "$win"
  else
    printf '%s\n' "$win"
  fi
}
