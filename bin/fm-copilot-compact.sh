#!/usr/bin/env bash
# GitHub Copilot CLI compaction re-emit transport for a primary session.
#
# Registered in tracked .github/hooks/firstmate-primary.json. Copilot discards a
# preCompact hook's output and never fires sessionStart after a compaction, so a
# compacted primary loses its session-start digest and nothing re-sends it
# (docs/sessionstart-nudge.md "Copilot compaction"). This adapter carries the
# digest in two steps; bin/fm-sessionstart-run.sh stays the single owner of the
# digest itself and already routes `--source compact` to its re-emit form.
#
#   mark     preCompact: record the compacted session's id in state/.copilot-compacted.
#   deliver  userPromptSubmitted and postToolUse: when that same session has a
#            pending mark, claim it with one atomic mv and print
#            {"additionalContext":"<re-emit digest>"}, which Copilot appends to the
#            prompt or tool result. postToolUse covers an automatic compaction that
#            lands mid-turn, after userPromptSubmitted already fired.
#
# The claim is a single rename, so two hooks racing for one mark cannot both
# deliver. A mark whose compaction then failed costs one redundant re-emit, which
# the run wrapper already treats as safe to repeat. A mark belonging to another
# session id is left untouched.
#
# Scoped to a genuine primary home through bin/fm-primary-scope-lib.sh, because a
# worker's trusted worktree loads this tracked registration too. Payloads raised
# by a subagent (they carry parentAgentId) are skipped. Every path exits 0 and
# prints either nothing or one JSON object, so a failed re-emit never blocks a turn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}
MARK=$STATE/.copilot-compacted
# deliver runs on every tool call, so the cheap no-mark test comes before the scope library and jq.
[ "${1:-}" != deliver ] || [ -e "$MARK" ] || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SID=$(cat 2>/dev/null | jq -r 'select(type == "object" and (has("parentAgentId") | not)) | .sessionId // empty | strings' 2>/dev/null) || exit 0
[ -n "$SID" ] || exit 0

case "${1:-}" in
  mark)
    printf '%s\n' "$SID" > "$MARK.tmp.$$" && mv -f "$MARK.tmp.$$" "$MARK"
    ;;
  deliver)
    [ "$(cat "$MARK" 2>/dev/null)" = "$SID" ] || exit 0
    mv "$MARK" "$MARK.claimed.$$" 2>/dev/null || exit 0
    rm -f "$MARK.claimed.$$"
    DIGEST=$(FM_COPILOT_HARNESS=copilot "$SCRIPT_DIR/fm-sessionstart-run.sh" --source compact </dev/null 2>/dev/null || true)
    [ -n "$DIGEST" ] || exit 0
    jq -cn --arg c "$DIGEST" '{additionalContext:$c}' 2>/dev/null || true
    ;;
esac
exit 0
