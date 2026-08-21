#!/usr/bin/env bash
# Claude Stop hook for automatic primary-session context refresh.
#
# Claude supplies the transcript path on stdin at every turn boundary. This hook
# streams the latest assistant usage, compares current context tokens with the
# validated config/context-restart-budget value, and emits exactly one typed
# context-refresh directive for each below-to-at-or-above threshold crossing.
# It publishes the crossing before its exit-2 directive, so interruption leaves
# a durable handoff record and later Stop firings cannot create a nag loop.
#
# Scope and identity match the existing Claude Stop stack: genuine primary homes
# only, current lock-owning session only, no Cursor/Grok compatibility duplicate,
# and no child task worktrees. Under threshold, malformed transcript or config,
# missing jq, uncertain identity, and lock contention all exit 0 without output.
# The session-start bootstrap reports malformed config separately.
#
# The hook never starts, stops, or waits on a watcher. It is synchronous only for
# its bounded transcript read and exit-2 directive, so the turn-end guard and the
# asyncRewake watcher auto-arm keep their existing independent ownership.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/.context-restart-crossing"
CLAIM="$STATE/.context-restart.lock"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-context-restart-lib.sh
. "$SCRIPT_DIR/fm-context-restart-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -er '
  if type == "object"
     and (.session_id | type) == "string"
     and (.transcript_path | type) == "string"
  then .session_id
  else error("payload")
  end
' 2>/dev/null) || exit 0
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -er '.transcript_path' 2>/dev/null) || exit 0
fm_context_restart_safe_atom "$SESSION_ID" || exit 0
BUDGET=$(fm_context_restart_budget_read "$CONFIG" 2>/dev/null) || exit 0
TOKENS=$(fm_context_restart_transcript_tokens "$TRANSCRIPT" 2>/dev/null) || exit 0

fm_lock_try_acquire "$CLAIM" || exit 0
trap 'fm_lock_release "$CLAIM"' EXIT

if ! fm_context_restart_decimal_ge "$TOKENS" "$BUDGET"; then
  if fm_context_restart_record_read "$RECORD" >/dev/null 2>&1 \
    && [ "$FM_CONTEXT_RESTART_RECORD_SESSION" = "$SESSION_ID" ] \
    && [ "$FM_CONTEXT_RESTART_RECORD_PHASE" = detected ]; then
    rm -f "$RECORD" 2>/dev/null || true
  fi
  exit 0
fi

if fm_context_restart_record_read "$RECORD" >/dev/null 2>&1 \
  && [ "$FM_CONTEXT_RESTART_RECORD_SESSION" = "$SESSION_ID" ]; then
  exit 0
fi

DETECTED_AT=$(date +%s)
fm_context_restart_record_publish \
  "$STATE" "$SESSION_ID" "$TOKENS" "$BUDGET" "$DETECTED_AT" detected || exit 0

BODY="Context is ${TOKENS} tokens at this turn boundary, meeting the ${BUDGET}-token restart budget. Perform the deliberate handoff now: invoke /stow and complete its full pass, including open-record persistence and the secondmate cascade. Continue only when its receipt says the session is reset-safe. Then run bin/fm-context-restart.sh handoff --session ${SESSION_ID} --reset-safe. Do not accept new work or send a captain-facing progress reply before that command. This crossing is durable and this directive will not repeat."
fm_operational_input_encode context-refresh "$BODY" DIRECTIVE || exit 0
printf '%s\n' "$DIRECTIVE" >&2
exit 2
