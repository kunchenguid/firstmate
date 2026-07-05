#!/usr/bin/env bash
# fm-dash.sh - live, strictly read-only terminal dashboard of in-flight tasks.
#
# Usage: fm-dash.sh [--once]
#   --once   print one snapshot and exit (for scripting and tests)
#
# One numbered block per state/<id>.meta in the active home (FM_HOME /
# FM_STATE_OVERRIDE resolution, same as fm-peek.sh): task id, project, kind,
# the current-state line from fm-crew-state.sh, the recorded PR URL when
# pr= is present, the worktree path (home= for kind=secondmate), and - when
# the pane is cheap to read through fm-peek.sh - its "Usage ...% | Weekly ...%"
# gauge line. Every per-row helper call is bounded by FM_DASH_STATE_TIMEOUT,
# so a slow or failing helper degrades that row to a placeholder instead of
# wedging the render loop.
#
# The worktree path renders as an OSC 8 hyperlink to an editor URL
# (<FM_DASH_EDITOR_SCHEME>://file/<path>, default vscode) when stdout is a
# terminal, and in live mode pressing a row's number (1-9) opens that
# worktree via FM_DASH_OPEN_CMD. Live mode re-renders every FM_DASH_INTERVAL
# seconds (default 5); `q` quits and restores the terminal (alternate
# screen, cursor, echo).
#
# Strictly READ-ONLY on the fleet: captures panes, never sends keys, never
# writes under state/, never touches worktrees. Like fm-crew-state.sh it
# skips fm-guard.sh so guard banners never mix into a rendered frame.
#
# Environment:
#   FM_DASH_INTERVAL       live refresh seconds (positive integer), default 5
#   FM_DASH_EDITOR_SCHEME  hyperlink URL scheme name, default vscode
#   FM_DASH_OPEN_CMD       number-key open command, run with the worktree path
#                          appended as one quoted argument; default `code`
#                          when on PATH, else `open -a "Visual Studio Code"`
#                          when that app resolves on macOS, else plain `open`
#   FM_DASH_STATE_TIMEOUT  per-row helper budget in seconds, default 6
#   FM_DASH_HYPERLINK      force OSC 8 hyperlinks on (1) or off (0); default
#                          on only when stdout is a terminal
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ONCE=0
case "${1:-}" in
  --once) ONCE=1 ;;
  '') : ;;
  *) echo 'usage: fm-dash.sh [--once]' >&2; exit 2 ;;
esac

INTERVAL=${FM_DASH_INTERVAL:-5}
case "$INTERVAL" in
  ''|*[!0-9]*|0)
    echo "error: FM_DASH_INTERVAL must be a positive integer of seconds (got '$INTERVAL')" >&2
    exit 2
    ;;
esac
STATE_TIMEOUT=${FM_DASH_STATE_TIMEOUT:-6}
case "$STATE_TIMEOUT" in ''|*[!0-9]*|0) STATE_TIMEOUT=6 ;; esac
SCHEME=${FM_DASH_EDITOR_SCHEME:-vscode}
case "${FM_DASH_HYPERLINK:-}" in
  1|true|yes|on) LINKS=1 ;;
  0|false|no|off) LINKS=0 ;;
  *) if [ -t 1 ]; then LINKS=1; else LINKS=0; fi ;;
esac

# Bounded helper runner: one slow or hung helper (a stuck no-mistakes call
# inside fm-crew-state.sh, a wedged backend capture inside fm-peek.sh) must
# cost at most STATE_TIMEOUT seconds and degrade, never wedge the render.
# Same timeout-tool ladder as fm-crew-state.sh's nm_run.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
run_bounded() {  # <cmd> [args...]
  case "$HAVE_TIMEOUT" in
    timeout)  timeout "$STATE_TIMEOUT" "$@" 2>/dev/null || true ;;
    gtimeout) gtimeout "$STATE_TIMEOUT" "$@" 2>/dev/null || true ;;
    perl)     perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$STATE_TIMEOUT" "$@" 2>/dev/null || true ;;
    *)        "$@" 2>/dev/null || true ;;
  esac
}

default_open_cmd() {
  if command -v code >/dev/null 2>&1; then
    printf 'code'
  elif [ "$(uname -s)" = Darwin ] && open -Ra 'Visual Studio Code' 2>/dev/null; then
    printf 'open -a "Visual Studio Code"'
  else
    printf 'open'
  fi
}
OPEN_CMD=${FM_DASH_OPEN_CMD:-$(default_open_cmd)}

open_path() {  # <path> - fire-and-forget so a slow opener never blocks the loop
  [ -n "$1" ] || return 0
  sh -c "$OPEN_CMD \"\$1\"" fm-dash-open "$1" >/dev/null 2>&1 &
}

url_encode_path() {  # minimal path encoding for the OSC 8 editor URL
  local s=$1
  s=${s//%/%25}
  s=${s// /%20}
  printf '%s' "$s"
}

OSC8_OPEN=$'\033]8;;'
OSC8_ST=$'\033\\'
hyperlink() {  # <url> <display-text>
  if [ "$LINKS" = 1 ]; then
    printf '%s%s%s%s%s%s' "$OSC8_OPEN" "$1" "$OSC8_ST" "$2" "$OSC8_OPEN" "$OSC8_ST"
  else
    printf '%s' "$2"
  fi
}

# render_frame: build one full frame into FRAME and map row numbers 1-9 to
# their worktree paths in ROW_PATHS for the live-mode number keys.
ROW_PATHS=()
FRAME=''
render_frame() {
  local body='' n=0 meta id kind project_path project path pr state_line gauge disp
  ROW_PATHS=()
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    project_path=$(fm_meta_get "$meta" project)
    project=${project_path:+$(basename "$project_path")}
    if [ "$kind" = secondmate ]; then
      path=$(fm_meta_get "$meta" home)
    else
      path=$(fm_meta_get "$meta" worktree)
    fi
    pr=$(fm_meta_get "$meta" pr)
    state_line=$(run_bounded "$SCRIPT_DIR/fm-crew-state.sh" "$id")
    [ -n "$state_line" ] || state_line='state: ? · source: none · state read slow or failed'
    state_line=${state_line#state: }
    gauge=$(run_bounded "$SCRIPT_DIR/fm-peek.sh" "fm-$id" 40 \
      | grep -oE 'Usage [^|]*% *\| *Weekly [^%]*%' | tail -1)
    n=$((n + 1))
    [ "$n" -le 9 ] && ROW_PATHS[n]=$path
    body+=$(printf ' %2d  %-20s %-16s %-11s %s' "$n" "$id" "${project:--}" "$kind" "$state_line")$'\n'
    if [ -n "$path" ]; then
      disp=$path
      case "$disp" in "$HOME"/*) disp="~${disp#"$HOME"}" ;; esac
      body+="     $(hyperlink "$SCHEME://file/$(url_encode_path "$path")" "$disp")"$'\n'
    fi
    [ -n "$pr" ] && body+="     pr: $pr"$'\n'
    [ -n "$gauge" ] && body+="     $gauge"$'\n'
    body+=$'\n'
  done

  FRAME="firstmate dash · $n in flight · $(date +%H:%M:%S)"
  if [ "$ONCE" != 1 ]; then
    FRAME+=" · refresh ${INTERVAL}s · q quit · 1-9 open worktree"
  fi
  FRAME+=$'\n\n'
  if [ "$n" -eq 0 ]; then
    FRAME+='No tasks in flight - the deck is clear.'$'\n'
  else
    FRAME+="$body"
  fi
}

if [ "$ONCE" = 1 ]; then
  render_frame
  printf '%s' "$FRAME"
  exit 0
fi

# --- live mode ---------------------------------------------------------------

# FM_DASH_FORCE_TTY=1 lets the behavior tests drive the live loop through
# pipes; real interactive use requires a terminal on stdin and stdout.
if [ "${FM_DASH_FORCE_TTY:-0}" != 1 ] && ! { [ -t 0 ] && [ -t 1 ]; }; then
  echo 'error: live mode needs a terminal; use --once for a scriptable snapshot' >&2
  exit 2
fi

SAVED_STTY=$(stty -g 2>/dev/null || true)
cleanup() {
  # Restore cursor, leave the alternate screen, and restore terminal modes.
  printf '\033[?25h\033[?1049l'
  [ -n "$SAVED_STTY" ] && stty "$SAVED_STTY" 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '\033[?1049h\033[?25l'

while :; do
  render_frame
  printf '\033[H\033[2J%s' "$FRAME"
  key=''
  if read -rs -n 1 -t "$INTERVAL" key; then
    case "$key" in
      q|Q) exit 0 ;;
      [1-9]) open_path "${ROW_PATHS[$key]:-}" ;;
    esac
  else
    # >128 is the read timeout (normal refresh); anything else is a closed
    # stdin, so exit instead of spinning on instant EOFs.
    rc=$?
    [ "$rc" -gt 128 ] || exit 0
  fi
done
