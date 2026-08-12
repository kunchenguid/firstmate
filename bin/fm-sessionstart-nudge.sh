#!/usr/bin/env bash
# Print the one-line session-start or post-compaction instruction only for a
# genuine firstmate primary. Session start stays silent once this harness owns
# the home lock; post-compaction is a bounded read-only re-anchor and never runs
# the session-start command. Its contradiction refresh prints only when the
# re-read durable records disagree with cheap endpoint or recorded-PR reality.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-record-contradictions-lib.sh
. "$SCRIPT_DIR/fm-record-contradictions-lib.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

mode=${1:-session-start}
[ "$#" -le 1 ] || exit 0
nudge=
include_contradictions=0
case "$mode" in
  session-start)
    lock_is_in_ancestry && exit 0
    fm_operational_input_encode session-start \
      "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
      nudge || exit 0
    ;;
  post-compact)
    include_contradictions=1
    fm_operational_input_encode post-compact \
      "Context was compacted. Before further action, re-read the complete contents of data/captain.md, data/captain-shared.md, data/learnings.md, and every active state/*.meta file. Do not run bin/fm-session-start.sh." \
      nudge || exit 0
    ;;
  *) exit 0 ;;
esac
printf '%s\n' "$nudge"
if [ "$include_contradictions" -eq 1 ]; then
  contradictions=$(fm_record_contradictions_render "$DATA" "$STATE" 2>/dev/null) || contradictions=
  [ -z "$contradictions" ] || printf '\n%s\n' "$contradictions"
fi
exit 0
