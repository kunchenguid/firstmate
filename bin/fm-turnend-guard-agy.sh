#!/usr/bin/env bash
# agy Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# agy is the one verified adapter whose Stop hook can block IN PROCESS without
# any resume trick. Its documented Stop contract (agy 1.1.12's own embedded
# hooks guide) is a JSON object on stdout: `{"decision":"continue","reason":...}`
# re-enters the SAME execution loop and injects `reason` as a system message,
# and any other value lets the agent stop. Verified live: a Stop hook returning
# that object made the model perform the injected instruction and fired Stop a
# second time when the hook allowed the stop.
#
# Every exit path prints a JSON object, because agy requires one of a hook and
# treats a non-zero exit as hook failure rather than a semantic signal. Failing
# to emit is therefore the one thing this adapter must never do.
#
# PAYLOAD. agy's Stop payload carries conversationId, workspacePaths,
# transcriptPath, artifactDirectoryPath, modelName, executionNum,
# terminationReason, error, and fullyIdle. It carries NEITHER `session_id` nor
# `stop_hook_active`, so Claude's and Grok's one-block loop guard is unavailable
# and the bounded per-conversation budget below takes its place.
#
# ROOT. This script anchors on its OWN location, exactly like every sibling
# guard, rather than on a project-directory environment variable: agy sets no
# such variable for hook processes (verified - a hook's environment carries
# ANTIGRAVITY_AGENT, ANTIGRAVITY_CONVERSATION_ID and friends, but no
# ANTIGRAVITY_PROJECT_DIR), and a guard gated on one would silently never run.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BUDGET_FILE="$STATE/.turnend-agy-blocks"
BLOCK_BUDGET=${FM_AGY_TURNEND_BLOCK_BUDGET:-3}
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

# allow: let the turn end. continue: block it and inject <reason>.
allow() { printf '{}\n'; exit 0; }
continue_with() {  # <reason>
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$1" '{decision:"continue",reason:$r}' 2>/dev/null || allow
  else
    allow
  fi
  exit 0
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || allow
command -v jq >/dev/null 2>&1 || allow
printf '%s' "$PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || allow

CONVERSATION=$(printf '%s' "$PAYLOAD" | jq -r '.conversationId // ""' 2>/dev/null || true)
[ -n "$CONVERSATION" ] || allow

# Bounded block budget, keyed on this conversation. Without it a guard that
# keeps blocking would loop the agent forever, which is the failure mode
# `stop_hook_active` prevents for the adapters that publish it.
BUDGET_COUNT=0
if [ -f "$BUDGET_FILE" ]; then
  budget_conv=$(sed -n '1s/^conversation=//p' "$BUDGET_FILE" 2>/dev/null || true)
  budget_n=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$budget_n" in ''|*[!0-9]*) budget_n=0 ;; esac
  [ "$budget_conv" = "$CONVERSATION" ] && BUDGET_COUNT=$budget_n
fi
[ "$BUDGET_COUNT" -lt "$BLOCK_BUDGET" ] || allow

[ -x "$FM_ROOT/bin/fm-turnend-guard.sh" ] || allow

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-agy.XXXXXX") || allow
trap 'rm -f "$ERR"' EXIT
printf '%s' "$PAYLOAD" | "$FM_ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
if [ "$RC" -ne 2 ]; then
  # The turn may end. Retire this conversation's budget so the next genuine
  # block starts from a full allowance rather than a spent one.
  rm -f "$BUDGET_FILE" 2>/dev/null || true
  allow
fi

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'

tmp="$BUDGET_FILE.tmp.$$"
if printf 'conversation=%s\ncount=%s\n' "$CONVERSATION" "$((BUDGET_COUNT + 1))" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
else
  rm -f "$tmp" 2>/dev/null || true
fi

continue_with "TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.

$REASON"
