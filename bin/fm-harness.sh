#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh         print own harness: claude|codex|opencode|pi|unknown
#        fm-harness.sh crew    print the effective crewmate harness
#                              (config/crew-harness; "default" resolves to own)
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  [ "${PI_CODING_AGENT:-}" = "true" ] && { echo pi; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "$(basename "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  echo unknown
}

if [ "${1:-}" = "crew" ]; then
  crew=$(cat "$FM_ROOT/config/crew-harness" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
else
  detect_own
fi
