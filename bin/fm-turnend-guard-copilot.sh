#!/usr/bin/env bash
# GitHub Copilot CLI agentStop adapter for the primary turn-end guard.
#
# Registered in tracked .github/hooks/firstmate-primary.json. bin/fm-turnend-guard.sh
# stays the single owner of the block decision and its banner; this adapter only
# translates its exit status 2 into Copilot's own decision object:
#   {"decision":"block","reason":"..."}
# Exit status 2 from an agentStop hook only prints a warning line and does not
# continue the turn (verified, copilot 1.0.105).
#
# The block is bounded to once per turn: Copilot sets stop_hook_active on the stop
# that follows a block, and the shared guard allows that stop. This adapter never
# parks or waits, because a parked Copilot pane ignores typing, Escape, Ctrl-C and
# /exit until the hook returns (docs/verification/copilot.md "Parked hooks").
#
# The guard reads a synthesized payload that deliberately carries no `timestamp`,
# so bin/fm-hook-host-lib.sh does not take it for the Claude-shaped duplicate that
# Copilot delivers from .claude/settings.json and stand the guard down; the guard
# also runs with COPILOT_HOOK_DEPTH removed, which Copilot sets in every hook and
# which the same predicate would otherwise read as that duplicate.
#
# The typed wake process (bin/fm-copilot-wake.sh) is what rings an idle pane, and a
# healthy watcher alone does not prove it runs: an orphaned watcher outlives a killed
# wake process. So when work needs supervision and the wake lock's pid is dead, the
# stop is blocked once with a `bin/fm-copilot-wake.sh start` reason even though the
# shared guard allowed it. Away mode, whose daemon owns supervision, is exempt.
#
# Scoped to a genuine primary home through bin/fm-primary-scope-lib.sh, because a
# worker's trusted worktree loads this tracked registration too. Payloads raised
# by a subagent (they carry parentAgentId) are skipped. Malformed or empty input,
# a missing jq, and a failed guard all allow the stop: this adapter prints nothing
# and exits 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
SYNTH=$(printf '%s' "$PAYLOAD" | jq -ce '
  select(type == "object" and (has("parentAgentId") | not))
  | {stop_hook_active: (.stop_hook_active // false)}
' 2>/dev/null) || exit 0

REASON=$(printf '%s' "$SYNTH" | env -u COPILOT_HOOK_DEPTH "$SCRIPT_DIR/fm-turnend-guard.sh" 2>&1 >/dev/null)
GUARD_STATUS=$?
if [ "$GUARD_STATUS" -ne 2 ]; then
  if [ "$(printf '%s' "$SYNTH" | jq -r '.stop_hook_active')" = false ] && [ ! -e "$STATE/.afk" ] \
    && ! kill -0 "$(cat "$(fm_copilot_wake_lock_dir "$STATE")/pid" 2>/dev/null)" 2>/dev/null; then
    # shellcheck source=bin/fm-supervision-lib.sh
    . "$SCRIPT_DIR/fm-supervision-lib.sh"
    if fm_supervision_needed "$STATE" "${FM_GUARD_GRACE:-300}"; then
      REASON='tasks in flight, but the typed wake process is not running, so no wake would reach this pane - run bin/fm-copilot-wake.sh start before ending the turn'
      GUARD_STATUS=2
    fi
  fi
fi
if [ "$GUARD_STATUS" -ne 2 ]; then
  printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-copilot-wake.sh" turn idle agent-stop
  exit 0
fi
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
fm_operational_input_encode turn-end-guard "$REASON" REASON || exit 0
jq -cn --arg r "$REASON" '{decision:"block",reason:$r}' 2>/dev/null || true
exit 0
