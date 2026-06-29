#!/usr/bin/env bash
# fm-focus-lib.sh - shared, platform-agnostic helpers for the out-of-band
# notifier (bin/fm-notify.sh) and its click-to-focus handler (bin/fm-focus.sh).
#
# Two things live here so they have ONE definition instead of drifting copies:
#   1. Platform detection (wsl|windows|macos|linux|unknown), used by the notifier
#      to pick a backend and by the focus handler to pick how to raise the host
#      terminal.
#   2. The dynamic tmux pane resolution + selection that lands a click on the
#      EXACT firstmate pane. This is identical on every OS - only the terminal
#      raise differs - so all of fm-focus.sh's per-platform paths share it.
#
# Sourced, not executed. Idempotent: a double-source is a no-op.
#
# Internal/testing knobs (not the public contract):
#   FM_NOTIFY_UNAME         override `uname -s` for platform-detection tests.
#   FM_NOTIFY_PROC_VERSION  path read instead of /proc/version (WSL detection).

[ -n "${FM_FOCUS_LIB_SOURCED:-}" ] && return 0
FM_FOCUS_LIB_SOURCED=1

_uname_s() { printf '%s' "${FM_NOTIFY_UNAME:-$(uname -s 2>/dev/null)}"; }

# fm_detect_platform: echo one of wsl|windows|macos|linux|unknown. WSL must be
# decided before plain Linux because a WSL kernel still reports `uname -s`=Linux;
# the discriminator is the "microsoft" marker in /proc/version.
fm_detect_platform() {
  local u proc
  u=$(_uname_s)
  proc="${FM_NOTIFY_PROC_VERSION:-/proc/version}"
  case "$u" in
    Darwin) printf 'macos\n'; return 0 ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT|Windows) printf 'windows\n'; return 0 ;;
  esac
  if grep -qi microsoft "$proc" 2>/dev/null; then
    printf 'wsl\n'; return 0
  fi
  case "$u" in
    Linux) printf 'linux\n'; return 0 ;;
  esac
  if [ "${OS:-}" = "Windows_NT" ]; then printf 'windows\n'; return 0; fi
  printf 'unknown\n'
}

# fm_focus_resolve_pane <pane_file> <home>: echo the firstmate tmux pane id,
# resolved DYNAMICALLY with nothing hardcoded - no session name, window index, or
# pane literal - so it survives a session rename, a window move, and a restart.
# The recorded pane id is the primary signal; if that pane is gone, it falls back
# to the claude pane whose working directory is the firstmate home. Echoes empty
# when neither resolves (the caller then does nothing, never a wrong pane).
fm_focus_resolve_pane() {
  local pane_file=$1 home=$2 pane=""
  [ -r "$pane_file" ] && pane=$(cat "$pane_file" 2>/dev/null)
  if [ -z "$pane" ] || ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$pane"; then
    # Tab-delimit so a home path containing spaces still compares exactly.
    pane=$(tmux list-panes -a -F $'#{pane_id}\t#{pane_current_command}\t#{pane_current_path}' 2>/dev/null \
           | awk -F '\t' -v home="$home" '$2=="claude" && $3==home {print $1; exit}')
  fi
  printf '%s' "$pane"
}

# fm_focus_select_tmux <pane>: select the pane's CURRENT session:window and the
# pane itself, resolved now - so a renamed session or moved window still lands on
# the right place. A clean no-op when the pane could not be resolved.
fm_focus_select_tmux() {
  local pane=$1 win
  [ -n "$pane" ] || return 0
  win=$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}' 2>/dev/null)
  [ -n "$win" ] && tmux select-window -t "$win" >/dev/null 2>&1
  tmux select-pane -t "$pane" >/dev/null 2>&1
}
