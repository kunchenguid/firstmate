#!/usr/bin/env bash
# Codex notify adapter for a pool task; preserves the turn-ended marker and
# binds the callback to the exact native task/generation/receipt after API proof.
# Usage: fm-dispatch-pool-notify.sh <config> <state> <task> <receipt> <spawn-gen> <Codex JSON>
# The vendor payload travels over stdin to the state owner and is never logged.
set -euo pipefail
[ "$#" = 6 ] || { echo 'error: invalid pool notification arguments' >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s' "$6" | "$SCRIPT_DIR/fm-dispatch-pool.sh" bind "$1" "$2" "$3" "$4" "$5" >/dev/null
