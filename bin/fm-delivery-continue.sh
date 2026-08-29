#!/usr/bin/env bash
# fm-delivery-continue.sh - own the committed-ready -> validation instruction.
#
# Usage: fm-delivery-continue.sh <task-id>
#
# This is intentionally a narrow transition owner, not a scheduler. It sends
# exactly one durable acknowledged inbox instruction only for a recorded
# ship/no-mistakes task whose latest receipt establishes a committed head,
# whose generated brief grants that validation handoff, and whose current
# durable state leaves no decision, safety stop, or attributed pipeline run.
#
# Output is one factual record: result=sent|already-delivered|already-active|refused.
# The task lease serializes main and Pi-branch replays. Every exit releases a
# successful claim; a live opposite owner is refused and never bypassed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEASE_BIN="${FM_DELIVERY_LEASE_BIN:-$SCRIPT_DIR/fm-lease.sh}"
SEND_BIN="${FM_DELIVERY_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
CREW_STATE_BIN="${FM_DELIVERY_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

usage() { echo "usage: fm-delivery-continue.sh <task-id>" >&2; exit 2; }
TASK=${1:-}
[ "$#" -eq 1 ] || usage
case "$TASK" in ''|*[!A-Za-z0-9._-]*) usage ;; esac

CLAIMED=0
cleanup() {
  [ "$CLAIMED" = 1 ] || return 0
  "$LEASE_BIN" release "$TASK" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

result() { printf 'result=%s task=%s%s\n' "$1" "$TASK" "${2:+ reason=$2}"; }
refuse() { result refused "$1"; exit 0; }

claim_out=$("$LEASE_BIN" claim "$TASK" 2>&1) || {
  claim_rc=$?
  if [ "$claim_rc" -eq 6 ]; then refuse other-supervision-owner; fi
  printf '%s\n' "$claim_out" >&2
  refuse lease-unavailable
}
CLAIMED=1

META="$STATE/$TASK.meta"
[ -f "$META" ] && [ ! -L "$META" ] || refuse missing-task-metadata
meta_get() { sed -n "s/^$1=//p" "$META" | tail -1; }
[ "$(meta_get kind)" = ship ] || refuse non-ship-task
[ "$(meta_get mode)" = no-mistakes ] || refuse unsupported-delivery-mode
SPAWN_GEN=$(meta_get spawn_gen)
case "$SPAWN_GEN" in ''|*[!A-Za-z0-9._-]*) refuse missing-task-incarnation ;; esac

STATUS="$STATE/$TASK.status"
[ -f "$STATUS" ] && [ ! -L "$STATUS" ] || refuse missing-committed-receipt
LAST=$(grep -v '^[[:space:]]*$' "$STATUS" | tail -1)
HEAD_SHORT=$(printf '%s\n' "$LAST" | sed -n 's/^done:[[:space:]]*committed[[:space:]]\([0-9A-Fa-f][0-9A-Fa-f]*\)\([[:space:]].*\)\{0,1\}$/\1/p')

WORKTREE=$(meta_get worktree)
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || refuse missing-worktree
CURRENT=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null) || refuse unreadable-worktree-head
WORKTREE_STATUS=$(git -C "$WORKTREE" status --porcelain 2>/dev/null) || refuse unreadable-worktree-status
[ -z "$WORKTREE_STATUS" ] || refuse uncommitted-worktree
if [ -n "$HEAD_SHORT" ]; then
  case "$HEAD_SHORT" in ???????*) ;; *) refuse invalid-committed-head ;; esac
  HEAD=$(git -C "$WORKTREE" rev-parse --verify "${HEAD_SHORT}^{commit}" 2>/dev/null) || refuse invalid-committed-head
  [ "$HEAD" = "$CURRENT" ] || refuse committed-head-mismatch
else
  case "$LAST" in 'done: '*) ;; *) refuse missing-committed-receipt ;; esac
  HEAD=$CURRENT
fi

BRIEF="$DATA/$TASK/brief.md"
[ -f "$BRIEF" ] && [ ! -L "$BRIEF" ] || refuse missing-generated-delivery-contract
grep -Fqx 'Delivery contract: mode=no-mistakes' "$BRIEF" || refuse delivery-contract-mismatch
grep -Fqx 'Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.' "$BRIEF" \
  || refuse validation-not-authorized
if grep -Eq 'DRAFT_FOR_FIRSTMATE_REVIEW|Execution-Authorized:[[:space:]]*false|RESEARCH_ONLY|NO_ORDER|NO_PROMOTION' "$BRIEF"; then
  refuse prohibited-research-or-promotion-scope
fi

# The status fold is the single owner of live keyed decisions and blockers.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
[ -z "$(status_open_decisions "$STATUS")" ] || refuse open-decision-or-blocker

# A run-step is authoritative for pipeline custody. An unknown busy source is
# deliberately not enough to hide this durable continuation obligation.
CREW_STATE=$("$CREW_STATE_BIN" "$TASK" 2>/dev/null || true)
case "$CREW_STATE" in
  'state: working · source: run-step ·'*) result already-active; exit 0 ;;
  'state: parked · source: run-step ·'*) refuse attributable-validation-parked ;;
  'state: done · source: run-step ·'*|'state: failed · source: run-step ·'*) refuse attributable-validation-terminal ;;
esac

# shellcheck source=bin/fm-task-inbox-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-delivery-continuation-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-delivery-continuation-lib.sh"
DELIVERY=$(fm_delivery_continuation_id "$TASK" "$HEAD" "$SPAWN_GEN")
MESSAGE=$(fm_delivery_continuation_message "$TASK" "$HEAD" "$SPAWN_GEN" "$DELIVERY")
if fm_delivery_continuation_state "$STATE" "$TASK" "$SPAWN_GEN" >/dev/null; then
  result already-delivered
  exit 0
fi

FM_SEND_IDEMPOTENT=1 FM_SEND_EXPECTED_SPAWN_GEN="$SPAWN_GEN" \
  "$SEND_BIN" "$TASK" "$MESSAGE" >/dev/null || refuse inbox-delivery-failed
result sent
