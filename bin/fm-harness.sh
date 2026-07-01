#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh             print own harness: claude|codex|opencode|pi|grok|unknown
#        fm-harness.sh crew        print the effective CREWMATE harness
#                                  (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate  print the harness the PRIMARY uses to launch
#                                  SECONDMATE agents: config/secondmate-harness ->
#                                  config/crew-harness -> own. "default" or absent
#                                  defers to the crew resolution, so an unset
#                                  secondmate-harness behaves exactly as the crew
#                                  harness did before this knob existed.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  [ "${PI_CODING_AGENT:-}" = "true" ] && { echo pi; return; }
  # grok sets GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so this marker
  # is unambiguous when firstmate runs natively on grok.
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ found
  for _ in 1 2 3 4 5 6 7 8; do
    found=$(harness_for_pid "$pid") && { echo "$found"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  # Layer 3: tmux may keep the stable pane shell as #{pane_pid} while the
  # harness runs below it. Find a verified harness among that pane's descendants.
  if pane_pid=$(current_tmux_pane_pid); then
    found=$(find_harness_descendant "$pane_pid") && { echo "$found"; return; }
  fi
  echo unknown
}

current_tmux_pane_pid() {
  if [ -n "${TMUX_PANE:-}" ]; then
    tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null && return 0
  fi
  tmux display-message -p '#{pane_pid}' 2>/dev/null
}

harness_for_pid() {
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  case "$(basename "$comm")" in
    *claude*) echo claude; return 0 ;;
    *codex*) echo codex; return 0 ;;
    *opencode*) echo opencode; return 0 ;;
    *grok*) echo grok; return 0 ;;
    pi) echo pi; return 0 ;;
    node*|python*)
      # Bare interpreter: match the harness name in its script path.
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      case "$args" in
        *claude*) echo claude; return 0 ;;
        *codex*) echo codex; return 0 ;;
        *opencode*) echo opencode; return 0 ;;
        *grok*) echo grok; return 0 ;;
        *" pi "*|*/pi) echo pi; return 0 ;;
      esac ;;
  esac
  return 1
}

find_harness_descendant() {
  local root=$1 child found
  for child in $(ps -A -o pid=,ppid= | awk -v p="$root" '$2 == p { print $1 }'); do
    found=$(harness_for_pid "$child") && { echo "$found"; return 0; }
    found=$(find_harness_descendant "$child") && { echo "$found"; return 0; }
  done
  return 1
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" config/secondmate-harness defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm=
  [ -f "$CONFIG/secondmate-harness" ] && sm=$(tr -d '[:space:]' < "$CONFIG/secondmate-harness" || true)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  *) detect_own ;;
esac
