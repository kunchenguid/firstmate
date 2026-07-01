#!/usr/bin/env bash
# fm-focus.sh - raise the host terminal and select the firstmate tmux window+pane.
#
# Invoked when the captain CLICKS a notification's "Go to firstmate" action:
#   - Windows/WSL -> the registered "firstmate:" URL protocol -> a hidden VBS
#     launcher -> here (in the firstmate distro).
#   - macOS       -> terminal-notifier's -execute runs this directly.
#   - Linux       -> notify-send's --action handler runs this directly.
# Click-to-focus, by the captain's choice: nothing here runs unless the captain
# clicks - the toast never steals the foreground on its own.
#
# Everything tmux-side is resolved at click time; NOTHING is hardcoded - not the
# session name, the window index, nor the pane id - so it survives a session
# rename, a window move, and a firstmate restart. The pane id firstmate records
# live is the primary signal; if that pane is gone, it falls back to the claude
# pane whose working directory is the firstmate home. That dynamic resolution is
# shared with the notifier via bin/fm-focus-lib.sh (fm_focus_resolve_pane /
# fm_focus_select_tmux), so the Windows, macOS, and Linux paths cannot drift -
# only the terminal-raise step below differs per platform.
#
# Optional overrides (best-effort terminal raise; the tmux select always runs):
#   FM_FOCUS_MACOS_TERM    macOS terminal app to activate (default: detect
#                          iTerm2/Terminal among running processes).
#   FM_FOCUS_LINUX_WINDOW  Linux window title/name to raise via wmctrl/xdotool.
set -u

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-focus-lib.sh
. "$_self_dir/fm-focus-lib.sh"

# Resolve the firstmate home (and the pane-id file the notifier records under it)
# from the launcher arg or environment, else from this script's own install
# location (bin/fm-focus.sh -> repo root), matching bin/fm-notify.sh. A
# protocol/-execute click invokes this in a fresh shell, so the self-derived
# default is what makes it work with no FM_HOME in the environment; for a home
# that is not the repo root the notifier supplies it (see below). Never an
# absolute literal.
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_self_dir/.." && pwd)}"
# The WSL launcher passes the home as $1 (an argument survives WScript.Shell.Run;
# an `env FM_HOME=...` wrapper does not). macOS/Linux backends still pass it via the
# FM_HOME env. Precedence: launcher arg, then env, then self-derived repo root.
FM_HOME="${1:-${FM_HOME:-$FM_ROOT}}"
pane_file="${FM_TMUX_PANE_FILE:-$FM_HOME/state/.fm-tmux-pane}"

# 1) Raise the host terminal window. Hidden/best-effort and NEVER fatal on every
#    platform - if the raise tool is missing, the tmux select below still lands on
#    the right pane so the captain finds it active when they switch to the term.
_fm_focus_raise_macos() {
  command -v osascript >/dev/null 2>&1 || return 0
  if [ -n "${FM_FOCUS_MACOS_TERM:-}" ]; then
    osascript -e "tell application \"$FM_FOCUS_MACOS_TERM\" to activate" >/dev/null 2>&1
    return 0
  fi
  # Activate whichever supported terminal is actually running (never launch one).
  osascript \
    -e 'tell application "System Events" to set running_apps to name of every process' \
    -e 'if running_apps contains "iTerm2" then' \
    -e '  tell application "iTerm" to activate' \
    -e 'else if running_apps contains "Terminal" then' \
    -e '  tell application "Terminal" to activate' \
    -e 'end if' >/dev/null 2>&1
}

_fm_focus_raise_linux() {
  local target="${FM_FOCUS_LINUX_WINDOW:-}" wid cls
  if [ -n "$target" ] && command -v wmctrl >/dev/null 2>&1; then
    wmctrl -a "$target" >/dev/null 2>&1 && return 0
  fi
  if command -v xdotool >/dev/null 2>&1; then
    if [ -n "$target" ]; then
      xdotool search --name "$target" windowactivate >/dev/null 2>&1 && return 0
    fi
    # Best-effort: activate a known terminal-emulator window by class.
    for cls in gnome-terminal konsole Alacritty kitty org.wezfurlong.wezterm \
               xfce4-terminal xterm; do
      wid=$(xdotool search --class "$cls" 2>/dev/null | head -n1)
      [ -n "$wid" ] && { xdotool windowactivate "$wid" >/dev/null 2>&1; return 0; }
    done
  fi
  return 0
}

case "$(fm_detect_platform)" in
  wsl|windows)
    # Raise Windows Terminal via hidden PowerShell so no console flashes. The
    # single-quoted body is PowerShell, not shell - the $-expressions are
    # evaluated by PowerShell.
    # shellcheck disable=SC2016
    powershell.exe -NoProfile -WindowStyle Hidden -Command '$p=(Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -First 1).Id; if($p){$null=(New-Object -ComObject WScript.Shell).AppActivate($p)}' >/dev/null 2>&1
    ;;
  macos) _fm_focus_raise_macos ;;
  linux) _fm_focus_raise_linux ;;
esac

# 2) + 3) Resolve the firstmate tmux pane dynamically, then select its CURRENT
#    session:window and the pane itself - shared with the notifier so every
#    platform behaves identically here.
pane=$(fm_focus_resolve_pane "$pane_file" "$FM_HOME")
fm_focus_select_tmux "$pane"
exit 0
