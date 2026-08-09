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
FM_HOME="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
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
# overlap authority (invocation shape: <task-id> [--stat]); its nonzero
# conflict, identity, or read refusal is propagated to the terminal caller.
# FM_REVIEW_DIFF_CONFLICT=1 is the hermetic-test hook that forces a concrete
# conflict.
fm_review_diff_recheck() {  # <attempt_id>; 0 only when no concrete overlap exists
  local attempt=$1 task_id
  if [ "${FM_REVIEW_DIFF_CONFLICT:-0}" = 1 ]; then
    echo "pre-land: FM_REVIEW_DIFF_CONFLICT=1 forces a concrete actual-diff overlap for $attempt" >&2
    return 1
  fi
  task_id=$(cleanup_task_id_for_attempt "$attempt") || {
    echo "pre-land: exact task binding unavailable for $attempt" >&2
    return 1
  }
  "$SCRIPT_DIR/fm-review-diff.sh" "$task_id" --stat
}

terminal_cleanup_endpoint_receipt_proves_stop() {  # <attempt_id>
  local attempt=$1 record
  record=$(fm_attempt_load "$attempt") || return 1
  printf '%s' "$record" | jq -e '
    . as $record
    | ([.receipts["cleanup.endpoint"][]?
        | select(.state == "observed" and .generation == $record.envelope.generation)][0].evidence // null) as $endpoint
    | ([.receipts.landing[]?
        | select(.state == "observed" and .generation == $record.envelope.generation)][0].evidence // null) as $landing
    | $endpoint.confirmed_gone == true
    and ($endpoint.backend | type == "string" and length > 0)
    and ($endpoint.endpoint | type == "string" and length > 0)
    and ($endpoint.task_id | type == "string" and length > 0)
    and ($endpoint.copy | type == "string" and length > 0)
    and $landing.disposition == "landed"
    and $endpoint.backend == $record.provider.provider
    and $endpoint.copy == $record.provider.copy
    and $endpoint.backend == $landing.facts.endpoint.backend
    and $endpoint.endpoint == $landing.facts.endpoint.id
    and $endpoint.task_id == $landing.facts.endpoint.task_id
    and $endpoint.copy == $landing.facts.endpoint.copy
  ' >/dev/null 2>&1
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
bead_live=$(br show --json "$bead" 2>/dev/null) || bead_live=
if ! printf '%s' "$bead_live" | jq -e --arg b "$bead" '
    type == "array" and length == 1 and .[0].id == $b
    and (.[0].status | type == "string" and length > 0)
  ' >/dev/null 2>&1; then
  echo "terminal: live bead verification failed for $attempt; preserving ownership" >&2
  exit 1
fi
bead_fact=$(printf '%s' "$bead_live" | jq -c \
  '.[0] | {id,status,owner:(.assignee // .owner // "")}')
[ "${FM_TERMINAL_CRASH_AFTER:-}" != claim ] || exit 42

# 2. re-read worker, endpoint, Git, forge, bead, copy, and queue facts and
#    classify the exact delivery (centralized disposition, Task 4). The exact
#    evidence is persisted before cleanup can remove any of its live inputs.
landing_evidence=$(jq -c '[.receipts.landing[]? | select(.state == "observed")][0].evidence // empty' \
  "$(attempt_path "$attempt")")
landing_persisted=1
if [ -z "$landing_evidence" ]; then
  landing_persisted=0
  landing_evidence=$(fm_disposition_evidence_live "$attempt")
elif ! cleanup_effect_observed "$attempt" cleanup.endpoint; then
  live_landing_evidence=$(fm_disposition_evidence_live "$attempt")
  [ "$(printf '%s' "$live_landing_evidence" | jq -r '.disposition // "unknown"')" = \
    "$(printf '%s' "$landing_evidence" | jq -r '.disposition // "unknown"')" ] || {
      echo "terminal: persisted landing evidence no longer matches live delivery for $attempt" >&2
      exit 1
    }
fi
disp=$(printf '%s' "$landing_evidence" | jq -r '.disposition // "unknown"')
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
cleanup_complete=0
fm_cleanup_effects_present "$attempt" "$disp" && cleanup_complete=1
if [ "$landing_persisted" = 0 ] && [ "$cleanup_complete" = 1 ]; then
  echo "terminal: cleanup completed without persisted landing evidence for $attempt; preserving ownership" >&2
  exit 1
fi

# 4. fresh per-effect authority for each irreversible transition; the claim
#    request's authority never authorizes closure, merge, or discard
close_authority=
close_request="$STATE_DIR/attempts/requests/$attempt.close.json"
persisted_close_request=
if [ "$disp" = landed ]; then
  if [ -e "$close_request" ]; then
    [ -f "$close_request" ] && [ ! -L "$close_request" ] || {
      echo "terminal: invalid persisted close request for $attempt" >&2
      exit 1
    }
    persisted_close_request=$(jq -c . "$close_request" 2>/dev/null) || {
      echo "terminal: unreadable persisted close request for $attempt" >&2
      exit 1
    }
    printf '%s' "$persisted_close_request" | jq -e --arg attempt "$attempt" --argjson gen "$gen" --arg bead "$bead" '
      .attempt_id == $attempt and .generation == $gen and .bead_id == $bead
      and .transition == "close" and .expected_state == "open"
      and (.expected_source_hash | type == "string" and length == 64 and test("^[0-9a-fA-F]+$"))
      and (.authority | type == "string" and length > 0)
      and (.agent | type == "string" and length > 0)
      and (.repo | type == "string" and length > 0)
    ' >/dev/null 2>&1 || {
      echo "terminal: persisted close request conflicts with $attempt" >&2
      exit 1
    }
    close_authority=$(printf '%s' "$persisted_close_request" | jq -r '.authority')
  else
    close_authority=$(fm_authority_for close "$bead" "$attempt" "$gen") || {
      echo "terminal: missing close authority" >&2
      exit 1
    }
  fi
fi

# 4b. pre-land actual-diff recheck: the existing diff helper is authoritative
#     for overlap; a concrete conflict refuses landing and serializes
if [ "$disp" = landed ] && [ "$cleanup_complete" = 0 ] \
  && ! terminal_cleanup_endpoint_receipt_proves_stop "$attempt"; then
  if ! fm_review_diff_recheck "$attempt"; then
    echo "terminal: pre-land actual-diff gate refused landing for $attempt" >&2
    exit 1
  fi
fi
if [ "$cleanup_complete" = 0 ]; then
  fm_cleanup_preflight "$attempt" "$disp" || {
    echo "terminal: cleanup identity or safety preflight refused before tracker mutation for $attempt" >&2
    exit 1
  }
  worker_fact=$(fm_capacity_crew_state "$FM_CLEANUP_TASK_ID")
  fm_capacity_crew_state_valid "$worker_fact" "$FM_CLEANUP_TASK_ID" || {
    echo "terminal: structured worker evidence unavailable for $attempt; preserving ownership" >&2
    exit 1
  }
  endpoint_state=$(cleanup_endpoint_absence_state \
    "$FM_CLEANUP_BACKEND" "$FM_CLEANUP_TARGET" "$FM_CLEANUP_TASK_ID")
  case "$endpoint_state" in present|missing) ;; *)
    echo "terminal: exact endpoint evidence is $endpoint_state for $attempt; preserving ownership" >&2
    exit 1
  esac
  if [ "$landing_persisted" = 0 ]; then
    landing_evidence=$(printf '%s' "$landing_evidence" | jq -c \
      --argjson bead "$bead_fact" --argjson worker "$worker_fact" \
      --arg backend "$FM_CLEANUP_BACKEND" --arg endpoint "$FM_CLEANUP_TARGET" \
      --arg endpoint_state "$endpoint_state" --arg copy "$FM_CLEANUP_COPY" \
      --arg task_id "$FM_CLEANUP_TASK_ID" \
      '. + {facts:{bead:$bead,worker:$worker,endpoint:{backend:$backend,id:$endpoint,state:$endpoint_state,copy:$copy,task_id:$task_id}}}')
  fi
fi
if [ "$landing_persisted" = 0 ]; then
  fm_attempt_effect_observe_held "$attempt" "$gen" landing "$landing_evidence" || {
    echo "terminal: landing evidence conflicts for $attempt" >&2
    exit 1
  }
fi
[ "${FM_TERMINAL_CRASH_AFTER:-}" != landing ] || exit 42

# 5. for truthful landed delivery only, request the Closure-Receipt and
#    canonical bead closure through the attended steward, then verify the
#    current-generation tracker receipt. The request is the persisted
#    replay boundary; it lives under attempts/requests/ so the shared
#    capacity projection (which lists attempts/*.json) never mistakes it for
#    an attempt record.
if [ "$disp" = landed ]; then
  project=${FM_REFILL_PROJECT:-/home/holu/decision-os}
  steward_agent=${BR_AGENT_NAME:-$(jq -r '[.receipts.claim[]? | select(.state == "observed")][0].evidence.agent // empty' "$(attempt_path "$attempt")")}
  [ -n "$steward_agent" ] || {
    echo "terminal: claim receipt has no registered steward identity for $attempt" >&2
    exit 1
  }
  if [ -n "$persisted_close_request" ]; then
    req=$persisted_close_request
    printf '%s' "$req" | jq -e --arg repo "$project" --arg agent "$steward_agent" \
      '.repo == $repo and .agent == $agent' >/dev/null 2>&1 || {
      echo "terminal: persisted close request steward identity conflicts for $attempt" >&2
      exit 1
    }
  else
    hash=$(sha256sum "$project/.beads/issues.jsonl" 2>/dev/null | cut -d' ' -f1)
    [ "${#hash}" -eq 64 ] || { echo "terminal: tracker source hash unavailable for $attempt" >&2; exit 1; }
    case "$hash" in *[!0-9a-fA-F]*) echo "terminal: tracker source hash unavailable for $attempt" >&2; exit 1 ;; esac
    req=$(jq -n --arg attempt_id "$attempt" --argjson generation "$gen" \
      --arg bead_id "$bead" --arg transition close --arg authority "$close_authority" \
      --arg repo "$project" --arg agent "$steward_agent" --arg hash "$hash" \
      '{attempt_id:$attempt_id,generation:$generation,bead_id:$bead_id,transition:$transition,expected_state:"open",expected_source_hash:$hash,evidence:"terminal",authority:$authority,agent:$agent,repo:$repo}')
    mkdir -p "$STATE_DIR/attempts/requests"
    printf '%s\n' "$req" > "$close_request.tmp.$$" || exit 1
    mv -f "$close_request.tmp.$$" "$close_request" || exit 1
  fi
  # the terminal holds the attempt lock across this step, so the steward
  # persists its receipt through the lock-held mode (FM_ATTEMPT_LOCK_HELD=1)
  FM_ATTEMPT_LOCK_HELD=1 "${FM_BR_RECEIPT_BIN:-$SCRIPT_DIR/fm-br-receipt.sh}" \
    "$close_request" \
    || { echo "terminal: tracker receipt pending for $attempt" >&2; exit 1; }
  jq -e --arg gen "$gen" \
    '[.receipts.tracker[]? | select(.state == "observed") | select(.generation == ($gen|tonumber))] | length > 0' \
    "$(attempt_path "$attempt")" >/dev/null 2>&1 \
    || { echo "terminal: tracker receipt missing or stale generation for $attempt" >&2; exit 1; }
  br show --json "$bead" 2>/dev/null | jq -e --arg b "$bead" \
    '.[0].id == $b and (.[0].status == "closed" or .[0].status == "done")' >/dev/null \
    || { echo "terminal: tracker closure is not confirmed for $attempt" >&2; exit 1; }
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
    "$(jq -n --arg disp "$disp" --arg authority "$close_authority" --argjson landing "$landing_evidence" \
      '{audit:"terminal",disposition:$disp,landing:$landing} + (if $authority == "" then {} else {authority:$authority} end)')" || exit 1
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
  cap_file=$(mktemp "${TMPDIR:-/tmp}/fm-terminal-capacity.XXXXXX") || exit 1
  trap 'rm -f "$cap_file"' EXIT
  printf '%s\n' "$cap" > "$cap_file" || exit 1
  if ! FM_CAPACITY_OBSERVATION_FILE="$cap_file" FM_TERMINAL_ATTEMPT="$attempt" \
      "${FM_REFILL_BIN:-$SCRIPT_DIR/fm-fleet-refill.sh}" --refill; then
    echo "terminal: post-retirement refill unavailable or refused for $attempt; terminal outcome preserved" >&2
  fi
  rm -f "$cap_file"
  trap - EXIT
else
  echo "terminal: post-terminal capacity projection unavailable for $attempt" >&2
fi
