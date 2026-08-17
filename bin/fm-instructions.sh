#!/usr/bin/env bash
# fm-instructions.sh - deterministic progressive-disclosure interface.
#
# Usage:
#   fm-instructions.sh list
#   fm-instructions.sh <operational-home|dispatch|recovery|project-knowledge|task-lifecycle|backlog|briefing>
#   fm-instructions.sh verify
#
# A bundle command prints that tracked agent-runtime instruction file byte for
# byte. `verify` checks the preservation manifest, trigger reachability, local
# links, destination ownership, and generated prompt parity against the bound
# baseline commit.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLES='operational-home dispatch recovery project-knowledge task-lifecycle backlog briefing'

bundle_path() {
  case "$1" in
    operational-home) printf '%s\n' "$ROOT/FIRSTMATE_OPERATIONAL_HOME.md" ;;
    dispatch) printf '%s\n' "$ROOT/FIRSTMATE_DISPATCH.md" ;;
    recovery) printf '%s\n' "$ROOT/FIRSTMATE_RECOVERY.md" ;;
    project-knowledge) printf '%s\n' "$ROOT/FIRSTMATE_PROJECT_KNOWLEDGE.md" ;;
    task-lifecycle) printf '%s\n' "$ROOT/FIRSTMATE_TASK_LIFECYCLE.md" ;;
    backlog) printf '%s\n' "$ROOT/FIRSTMATE_BACKLOG.md" ;;
    briefing) printf '%s\n' "$ROOT/FIRSTMATE_BRIEFING.md" ;;
    *) return 1 ;;
  esac
}

usage() {
  sed -n '2,11{s/^# \{0,1\}//;p;}' "$0" >&2
}

list_bundles() {
  local bundle
  for bundle in $BUNDLES; do
    printf '%s\n' "$bundle"
  done
}

case "${1:-}" in
  list)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    list_bundles
    ;;
  verify)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    exec python3 "$SCRIPT_DIR/fm-instructions-verify.py" --root "$ROOT"
    ;;
  operational-home|dispatch|recovery|project-knowledge|task-lifecycle|backlog|briefing)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    cat "$(bundle_path "$1")"
    ;;
  -h|--help)
    usage
    ;;
  *)
    printf 'fm-instructions: unknown command or bundle: %s\n' "${1:-<missing>}" >&2
    usage
    exit 2
    ;;
esac
