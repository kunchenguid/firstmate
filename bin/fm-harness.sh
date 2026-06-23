#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh         print own harness: claude|codex|opencode|pi|unknown
#        fm-harness.sh crew    print the effective crewmate harness
#                              (config/crew-harness; "default" resolves to own)
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-proc.sh
. "$SCRIPT_DIR/fm-proc.sh"

detect_own() {
  # Layer 1: environment markers for verified harnesses (OS-independent).
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  [ "${PI_CODING_AGENT:-}" = "true" ] && { echo pi; return; }
  # Layer 2: walk the ancestry and match the command name (or, for a bare
  # interpreter like node/python, the harness name in its argv). fm_proc_ancestry
  # walks the Windows process tree on MSYS, the OS process tree elsewhere.
  local pid comm args base
  while IFS="$(printf '\t')" read -r pid comm args; do
    [ -n "$comm" ] || continue
    base=$(basename "$comm")
    case "$base" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      pi|pi.exe) echo pi; return ;;
      node*|python*)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *" pi "*|*/pi|*\\pi|*\\pi.exe) echo pi; return ;;
        esac ;;
    esac
  done <<EOF
$(fm_proc_ancestry "$$")
EOF
  echo unknown
}

if [ "${1:-}" = "crew" ]; then
  crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
else
  detect_own
fi
