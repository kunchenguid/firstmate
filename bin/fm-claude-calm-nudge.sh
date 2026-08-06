#!/usr/bin/env bash
# fm-claude-calm-nudge.sh - print Claude's effective Calm presentation state
# for a genuine Firstmate primary.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

if [ "$("$SCRIPT_DIR/fm-calm.sh" status)" = on ]; then
  printf '%s\n' 'Firstmate Calm presentation is active for this home. Keep captain-facing updates outcome-first, concise, and free of incidental progress narration while preserving every operational instruction, safety boundary, and technical fact that matters.'
else
  printf '%s\n' 'Firstmate Calm presentation is inactive for this home. This supersedes any earlier Calm-active instruction in the transcript; use ordinary captain-facing presentation.'
fi
