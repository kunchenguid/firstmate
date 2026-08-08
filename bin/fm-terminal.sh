#!/usr/bin/env bash
# Sole Firstmate attempt-to-terminal orchestrator. Owns no branch,
# provider-copy, or runtime cleanup implementation of its own: it composes
# fm-cleanup-lib.sh and requests tracker mutations through fm-br-receipt.sh.
# Implements the design's ordered terminal composition inside ONE outer
# non-reentrant attempt lock held from step 1 through step 8; step 9 runs
# after release. All internal mutations use lock-held primitives that never
# reacquire.
#
# Ordered steps:
#   1. acquire the attempt lock; verify generation, bead binding, live bead,
#      and owned provider identity
#   2. re-read worker/endpoint/Git/forge/bead/copy facts and classify the
#      exact delivery through fm_disposition_live (Task 4)
#   3. preserve unknown deliveries for reconciliation; no destructive effect
#   4. obtain fresh per-effect authority (claim authority never authorizes
#      closure); landed-only pre-land actual-diff recheck
#   5. landed only: persist the exact tracker-mutation request, wait while
#      the attended steward executes it, and verify the current-generation
#      tracker receipt (the terminal never mutates the tracker itself)
#   6. invoke the one structured cleanup under the same held lock
#      (fm_cleanup_attempt_held); all refusals are preflighted before any
#      effect
#   7. still under the lock, publish the terminal audit receipt and retire
#      the attempt (replay-idempotent at the orchestrator level)
#   8. release the lock, then obtain a fresh shared capacity projection and
#      permit refill only from that canonical observation
#
# A crash after any receipt boundary is safe: replay resumes at the persisted
# request/receipt boundary and converges on the same effect set.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$SCRIPT_DIR/fm-attempt-lib.sh"
# shellcheck source=bin/fm-cleanup-lib.sh
. "$SCRIPT_DIR/fm-cleanup-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"
# shellcheck source=bin/fm-disposition-lib.sh
. "$SCRIPT_DIR/fm-disposition-lib.sh"

[ $# -ge 1 ] || { echo "usage: fm-terminal.sh <attempt-id>" >&2; exit 2; }
attempt=$1
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Pre-land actual-diff recheck: the existing bin/fm-review-diff.sh is the
# overlap authority (invocation shape: <task-id> [--stat]; it refreshes the
# authoritative base and surfaces the actual diff). The helper emits no
# overlap verdict of its own, so a successful run is no evidence of a
# concrete conflict. When no comparable current attempt exists (no referencing
# task meta) or the helper cannot run (missing worktree/project, hermetic
# environment), the gate stays open and returns 0 - the real overlap
# enforcement remains fm-review-diff.sh's own review-time authority.
# FM_REVIEW_DIFF_CONFLICT=1 is the hermetic-test hook that forces a concrete
# conflict.
fm_review_diff_recheck() {  # <attempt_id>; 0 only when no concrete overlap exists
  local attempt=$1 task_id
  if [ "${FM_REVIEW_DIFF_CONFLICT:-0}" = 1 ]; then
    echo "pre-land: FM_REVIEW_DIFF_CONFLICT=1 forces a concrete actual-diff overlap for $attempt" >&2
    return 1
  fi
  task_id=$(cleanup_task_id_for_attempt "$attempt" || true)
  [ -n "$task_id" ] || return 0
  "$SCRIPT_DIR/fm-review-diff.sh" "$task_id" --stat >/dev/null 2>&1 || true
  return 0
}

# Lock probes prove the outer lock contract to tests: at steps 1 and 8 a
# nested acquire must REFUSE (non-reentrant), and before step 9 it must
# succeed. Only active with FM_TERMINAL_HOLD_LOCK_PROBE=1.
probe_lock_held() {  # <label>; prints the marker only when the lock is held
  local label=$1
  [ "${FM_TERMINAL_HOLD_LOCK_PROBE:-0}" = 1 ] || return 0
  if fm_attempt_lock_acquire "$attempt" 2>/dev/null; then
    echo "terminal: lock probe: nested acquire unexpectedly succeeded at $label" >&2
    fm_attempt_lock_release "$attempt"
  else
    echo "lock-held-at-$label"
  fi
}

probe_lock_released() {  # <label>
  local label=$1
  [ "${FM_TERMINAL_HOLD_LOCK_PROBE:-0}" = 1 ] || return 0
  if fm_attempt_lock_acquire "$attempt" 2>/dev/null; then
    echo "lock-released-before-$label"
    fm_attempt_lock_release "$attempt"
  else
    echo "terminal: lock probe: lock still held before $label" >&2
  fi
}

fm_attempt_lock_acquire "$attempt" || {
  echo "terminal: attempt lock busy: $attempt" >&2
  exit 1
}
trap 'fm_attempt_lock_release "$attempt" 2>/dev/null || true' EXIT
gen=$(fm_attempt_generation_held "$attempt") || exit 1

probe_lock_held step-1

# 1. verify the immutable attempt, generation, home, bead binding, live bead,
#    and owned provider identity
bead=$(fm_attempt_load "$attempt" | jq -r '.envelope.task_key')
[ -n "$bead" ] || { echo "terminal: no bead binding for $attempt" >&2; exit 1; }
if ! br show --json "$bead" 2>/dev/null | jq -e --arg b "$bead" '.[0].id == $b' >/dev/null; then
  echo "terminal: live bead verification failed for $attempt; preserving ownership" >&2
  exit 1
fi
[ "${FM_TERMINAL_CRASH_AFTER:-}" != claim ] || exit 42

# 2. re-read worker, endpoint, Git, forge, bead, copy, and queue facts and
#    classify the exact delivery (centralized disposition, Task 4)
disp=$(fm_disposition_live "$attempt")
[ -n "$disp" ] || { echo "terminal: unknown disposition for $attempt" >&2; exit 1; }
if [ "${FM_TERMINAL_FORGE:-}" = unknown ]; then
  disp=unknown
fi
[ "${FM_TERMINAL_CRASH_AFTER:-}" != launch ] || exit 42

# 3. unknown / missing authority / dirty or later work / live processes /
#    identity mismatch / insufficient quiet / conflicting receipts: preserve
#    the attempt and resources for reconciliation
case "$disp" in
  landed|preserved_unlanded) ;;
  *)
    echo "terminal: delivery state '$disp' for $attempt; ownership preserved for reconciliation" >&2
    exit 1
    ;;
esac

# 4. fresh per-effect authority for each irreversible transition; the claim
#    request's authority never authorizes closure, merge, or discard
close_authority=$(fm_authority_for close "$bead") || {
  echo "terminal: missing close authority" >&2
  exit 1
}

# 4b. pre-land actual-diff recheck: the existing diff helper is authoritative
#     for overlap; a concrete conflict refuses landing and serializes
if [ "$disp" = landed ]; then
  if ! fm_review_diff_recheck "$attempt"; then
    echo "terminal: pre-land actual-diff conflict; landing refused for $attempt" >&2
    exit 1
  fi
fi

# 5. for truthful landed delivery only, request the Closure-Receipt and
#    canonical bead closure through the attended steward, then verify the
#    current-generation tracker receipt. The request is the persisted
#    replay boundary; it lives under attempts/requests/ so the shared
#    capacity projection (which lists attempts/*.json) never mistakes it for
#    an attempt record.
if [ "$disp" = landed ]; then
  project=${FM_REFILL_PROJECT:-/home/holu/decision-os}
  # guarded hash: a missing tracker source file yields an empty hash and the
  # steward still runs (the real steward would refuse on the mismatch)
  hash=$(sha256sum "$project/.beads/issues.jsonl" 2>/dev/null | cut -d' ' -f1)
  req=$(jq -n --arg attempt_id "$attempt" --argjson generation "$gen" \
    --arg bead_id "$bead" --arg transition close --arg authority "$close_authority" \
    --arg repo "$project" --arg agent "${BR_AGENT_NAME:-}" --arg hash "$hash" \
    '{attempt_id:$attempt_id,generation:$generation,bead_id:$bead_id,transition:$transition,expected_state:"open",expected_source_hash:$hash,evidence:"terminal",authority:$authority,agent:$agent,repo:$repo}')
  mkdir -p "$STATE_DIR/attempts/requests"
  echo "$req" > "$STATE_DIR/attempts/requests/$attempt.close.json"
  "${FM_BR_RECEIPT_BIN:-$SCRIPT_DIR/fm-br-receipt.sh}" \
    "$STATE_DIR/attempts/requests/$attempt.close.json" \
    || { echo "terminal: tracker receipt pending for $attempt" >&2; exit 1; }
  jq -e --arg gen "$gen" \
    '[.receipts.tracker[]? | select(.state == "observed") | select(.generation == ($gen|tonumber))] | length > 0' \
    "$(attempt_path "$attempt")" >/dev/null 2>&1 \
    || { echo "terminal: tracker receipt missing or stale generation for $attempt" >&2; exit 1; }
  [ "${FM_TERMINAL_CRASH_AFTER:-}" != closure ] || exit 42
fi

# 6. when lawful, invoke the one structured cleanup operation under the same
#    held lock; all refusals are preflighted before any effect
fm_cleanup_attempt_held "$attempt" "$disp" || {
  echo "terminal: cleanup did not complete for $attempt" >&2
  exit 1
}
[ "${FM_TERMINAL_CRASH_AFTER:-}" != cleanup ] || exit 42

# 7. still under the attempt lock, atomically publish the terminal audit
#    receipt and mark the live attempt retired. Retirement is replay-idempotent
#    at the orchestrator level (the record outlives the meta and shows
#    retired), so a duplicate completion converges on the same receipt set.
if ! fm_attempt_is_retired "$attempt"; then
  fm_attempt_retire_held "$attempt" "$gen" \
    "$(jq -n --arg disp "$disp" --arg authority "$close_authority" \
      '{audit:"terminal",disposition:$disp,authority:$authority}')" || exit 1
fi
[ "${FM_TERMINAL_CRASH_AFTER:-}" != retirement ] || exit 42

probe_lock_held step-8

# release before step 9
fm_attempt_lock_release "$attempt"
trap - EXIT
probe_lock_released step-9

# 8. after releasing the lock, obtain a fresh shared capacity projection and
#    permit refill only from that canonical observation
cap=$(fm_capacity_project 2>/dev/null || true)
echo "terminal: $attempt disposition=$disp retired"
if [ -n "$cap" ]; then
  echo "$cap" | jq -r '.aggregate | "post-terminal capacity: productive=\(.productive_count) reserved=\(.reserved_ownership_count) refill_safe=\(.refill_safe)"' 2>/dev/null || true
else
  echo "terminal: post-terminal capacity projection unavailable for $attempt" >&2
fi
