#!/usr/bin/env bash
# Fleet refill — shared-projection verdict (Task 13 cutover; Task 15 rollback).
#
# The human verdict is derived solely from the shared capacity projection
# (fm-fleet-capacity.v1): productive, reserved, refill_safe, alert_only, and
# reconciliation come from fm_capacity_project, never from legacy arithmetic.
# The legacy owned-manifest/output mtime battery count and the DISPATCH-NEEDED
# verdict were quarantined in Task 3 and never return; Task 15 deletes the
# last residual references. This script emits no dispatch verdict and stages
# no work. The serialization-debt safety probe and the authoritative bead-query
# diagnostic remain.
#
# Task 12 adds the --refill admission action; Task 15 flips the non-automatic
# path to alert-only rollback. Refill acts ONLY on a complete projection
# reporting productive work below the target and reserved ownership below the
# ceiling. It queries the live beads graph, applies the accepted Decision OS
# admission contract against the FROZEN provisional admission evidence in each
# current attempt's delivery record (planned_path, declared_seams,
# dependencies, written once at allocation) plus the known exclusive seams,
# and serializes a candidate ONLY when that bounded evidence identifies a
# concrete path overlap. No .beadscope, declaration registry, write-set
# enforcer, or claim inferred from planned paths is introduced, and admission
# never lands or merges: the actual diff stays the authoritative pre-land
# overlap check in bin/fm-review-diff.sh (Task 11). Automatic launching
# requires config/refill-auto in the home or FM_REFILL_AUTO=1; otherwise
# --refill is alert-only: it prints the admission verdict and `fleet-ok:
# alert-only` and never dispatches, claims, or launches, so every attempt,
# bead, branch, ref, copy, and receipt is preserved and forward recovery
# resumes from the persisted effect receipts when the gate is re-enabled.
# Automatic refill stays disabled: nothing in this repo creates
# config/refill-auto.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECT="${FM_REFILL_PROJECT:-/home/holu/decision-os}"

# Shadow-only parallel run (Task 3): --count-json emits the shared capacity
# object (fm-fleet-capacity.v1); FM_REFILL_SHADOW records that same object.
# Consumers switched to the shared object at the Task 13 cutover after parity
# proof; no legacy verdict exists here anymore.
if [ "${1:-}" = "--count-json" ]; then
  # shellcheck source=bin/fm-capacity-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
  fm_capacity_project
  exit 0
fi

# --- Task 12: --refill admission action ----------------------------------
#
# Config and defaults for the admission action. FM_REFILL_CANDIDATES_FILE
# and FM_REFILL_CURRENT_PATHS are TEST-ONLY overrides (see their comments);
# every other knob is a real runtime default.

FM_REFILL_HARNESS="${FM_REFILL_HARNESS:-pi}"
FM_REFILL_MODE="${FM_REFILL_MODE:-direct-PR}"
FM_BR_RECEIPT_BIN="${FM_BR_RECEIPT_BIN:-$FM_HOME/bin/fm-br-receipt.sh}"
FM_REFILL_SPAWN_BIN="${FM_REFILL_SPAWN_BIN:-$FM_HOME/bin/fm-spawn.sh}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# fm_refill_automatic: the automatic-refill gate. Automatic action requires
# config/refill-auto in the home (gitignored; nothing in this repo creates
# it) or FM_REFILL_AUTO=1; otherwise --refill is alert-only rollback (Task
# 15). It must never fire in production through any path other than those two.
# shellcheck source=bin/fm-wake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"

fm_refill_automatic() {  # 0 when automatic refill is authorized by the gate
  [ "${FM_REFILL_AUTO:-0}" = 1 ] && return 0
  [ -f "$CONFIG_DIR/refill-auto" ] && return 0
  return 1
}

# fm_refill_paths_overlap <path-a> <path-b>: 0 when the two paths concretely
# overlap at a path-component boundary (equal, or one is a directory prefix
# of the other). This is the bounded admission-overlap test: it runs only on
# FROZEN provisional evidence and never inspects live diffs.
fm_refill_paths_overlap() {
  local a=$1 b=$2
  a=${a%/}
  b=${b%/}
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  case "$a/" in
    "$b/"*) return 0 ;;
  esac
  case "$b/" in
    "$a/"*) return 0 ;;
  esac
  return 1
}

# fm_refill_current_evidence: the FROZEN provisional admission evidence from
# every current (allocated, not retired) attempt's delivery record
# (planned_path, declared_seams, dependencies) plus the known exclusive
# seams. FM_REFILL_CURRENT_PATHS is a TEST-ONLY override that replaces this
# read with a literal newline-separated path list so hermetic admission
# tests do not need a live attempt record.
fm_refill_current_evidence() {  # -> newline-separated path evidence lines
  local dir f aid
  if [ -n "${FM_REFILL_CURRENT_PATHS:-}" ]; then
    printf '%s\n' "$FM_REFILL_CURRENT_PATHS"
    return 0
  fi
  dir="$STATE/attempts"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    aid=$(basename "$f" .json)
    if fm_attempt_is_retired "$aid" 2>/dev/null; then
      continue
    fi
    # shellcheck disable=SC2016  # jq filters are single-quoted by design.
    jq -r '.delivery as $d |
      ($d.planned_path?, $d.declared_seams?, $d.dependencies?) |
      if type == "array" then .[] elif type == "string" and length > 0 then . else empty end' \
      "$f" 2>/dev/null || true
  done
}

# fm_refill_candidate_conflicts <planned_path> <evidence-lines>: 0 when the
# candidate's planned path concretely overlaps any frozen evidence line.
fm_refill_candidate_conflicts() {
  local path=$1 evidence=$2 line
  [ -n "$path" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if fm_refill_paths_overlap "$path" "$line"; then
      return 0
    fi
  done <<< "$evidence"
  return 1
}

# fm_refill_query_candidates: the live beads-graph query. Runs in the
# registered decision-os main clone: `br ready --json` (array shape), then
# `br show --json <id>` per candidate to re-verify open/ready/unclaimed
# while creating the claim request, extracting the provisional planned_path.
# FM_REFILL_CANDIDATES_FILE is a TEST-ONLY override supplying the candidate
# array ({id, planned_path, mode}) directly so admission is hermetic.
# FM_REFILL_CANDIDATES_QUERIED_MARKER is a TEST-ONLY hook: the moment this
# query actually runs, it touches the marker path so tests can prove an
# unsafe projection never queries candidates.
fm_refill_query_candidates() {  # -> JSON array of {id, planned_path, mode}
  local ready cand show id entry cands=()
  [ -z "${FM_REFILL_CANDIDATES_QUERIED_MARKER:-}" ] || : > "$FM_REFILL_CANDIDATES_QUERIED_MARKER"
  if [ -n "${FM_REFILL_CANDIDATES_FILE:-}" ]; then
    if [ -f "$FM_REFILL_CANDIDATES_FILE" ] \
      && jq -e 'type == "array"' "$FM_REFILL_CANDIDATES_FILE" >/dev/null 2>&1; then
      cat "$FM_REFILL_CANDIDATES_FILE"
    else
      echo "refill: candidate evidence unavailable (FM_REFILL_CANDIDATES_FILE)" >&2
      return 1
    fi
    return 0
  fi
  ready=$(cd "$PROJECT" 2>/dev/null && br ready --json 2>/dev/null) || ready=''
  if [ -z "$ready" ] || ! printf '%s' "$ready" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "refill: candidate evidence unavailable (br ready)" >&2
    return 1
  fi
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    id=$(printf '%s' "$cand" | jq -r '.id // empty' 2>/dev/null || true)
    [ -n "$id" ] || continue
    show=$(cd "$PROJECT" 2>/dev/null && br show --json "$id" 2>/dev/null) || show=''
    [ -n "$show" ] || continue
    # re-verify open/ready/unclaimed while creating the claim request
    printf '%s' "$show" | jq -e \
      '.status == "open" and ((.claimed_by // "") | tostring | length == 0)' >/dev/null 2>&1 || continue
    entry=$(printf '%s' "$show" | jq -c --arg id "$id" \
      '{id:$id,planned_path:(.planned_path // ""),mode:(.mode // "")}' 2>/dev/null || true)
    [ -n "$entry" ] || continue
    cands+=("$entry")
  done <<< "$(printf '%s' "$ready" | jq -c '.[]' 2>/dev/null || true)"
  if [ "${#cands[@]}" -gt 0 ]; then
    printf '%s\n' "${cands[@]}" | jq -s -c '.'
  else
    echo '[]'
  fi
}

# fm_refill_bead_available <id>: live ownership re-read after winning the
# home lock. A candidate whose bead was claimed or closed by another wave
# between the query and the lock is skipped, so concurrent refill
# invocations never double-dispatch.
fm_refill_bead_available() {
  local id=$1 show
  show=$(cd "$PROJECT" 2>/dev/null && br show --json "$id" 2>/dev/null) || return 1
  [ -n "$show" ] || return 1
  printf '%s' "$show" | jq -e \
    '.status == "open" and ((.claimed_by // "") | tostring | length == 0)' >/dev/null 2>&1
}

# fm_refill_lock_release: release the home claim lock won by the admission
# wave. Safe to fire at EXIT when the lock was never won.
fm_refill_lock_release() {
  if [ "${FM_REFILL_LOCK_HELD:-0}" = 1 ]; then
    fm_lock_release "$STATE/.lock.acquire" 2>/dev/null || true
    FM_REFILL_LOCK_HELD=0
  fi
}

# fm_refill_claim_and_launch <id>: the Task 6 split handshake (allocate the
# immutable attempt, persist the exact claim request, invoke the attended
# decision-os main-steward adapter synchronously) followed by the spawn
# resume path. A refused or unobserved claim leaves the attempt pending and
# never launches. Only the automatic gate reaches this; without the gate
# --refill is alert-only (Task 15) and never claims or launches.
fm_refill_claim_and_launch() {
  local id=$1 aid gen req source_hash
  aid=$(fm_attempt_alloc pi "$id" "$FM_HOME") || {
    echo "refill: attempt allocation failed for $id; refusing to launch without the claim" >&2
    return 1
  }
  gen=$(fm_attempt_generation "$aid") || {
    echo "refill: cannot resolve generation for $aid" >&2
    return 1
  }
  source_hash=$(cd "$PROJECT" 2>/dev/null && sha256sum .beads/issues.jsonl 2>/dev/null | cut -d' ' -f1) || source_hash=''
  [ -n "$source_hash" ] || {
    echo "refill: cannot resolve the Decision OS source hash at $PROJECT/.beads/issues.jsonl; refusing to launch without the claim" >&2
    return 1
  }
  req="$STATE/attempts/$aid.request.claim.json"
  jq -n \
    --arg attempt_id "$aid" \
    --argjson generation "$gen" \
    --arg bead_id "$id" \
    --arg transition claim \
    --arg expected_state open \
    --arg expected_source_hash "$source_hash" \
    --arg evidence intake \
    --arg authority "${FM_REFILL_AUTHORITY:-captain:dispatch}" \
    --arg agent "$FM_REFILL_HARNESS" \
    --arg repo "$PROJECT" \
    '{attempt_id:$attempt_id,generation:$generation,bead_id:$bead_id,transition:$transition,expected_state:$expected_state,expected_source_hash:$expected_source_hash,evidence:$evidence,authority:$authority,agent:$agent,repo:$repo}' \
    > "$req.tmp.$$" || {
    echo "refill: cannot write the claim request for $aid" >&2
    return 1
  }
  mv -f "$req.tmp.$$" "$req" || {
    echo "refill: cannot publish the claim request for $aid" >&2
    return 1
  }
  if ! "$FM_BR_RECEIPT_BIN" "$req"; then
    fm_attempt_effect_pending "$aid" "$gen" tracker \
      "$(jq -n --arg reason 'refill claim steward refused or unavailable' \
            --arg transition claim --arg authority "${FM_REFILL_AUTHORITY:-captain:dispatch}" \
            '{status:"pending",reason:$reason,transition:$transition,authority:$authority}')" \
      >/dev/null 2>&1 || true
    echo "refill: claim_pending $id (reconcile before allocation)" >&2
    return 1
  fi
  [ -z "${FM_REFILL_DISPATCH_LOG:-}" ] || printf 'launch %s\n' "$id" >> "$FM_REFILL_DISPATCH_LOG"
  # spawn resume path: the claim request file plus the observed tracker
  # receipt let fm-spawn.sh resume this exact attempt (FM_TRACKER_CLAIM=1)
  env FM_TRACKER_CLAIM=1 \
    FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-}" \
    FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-}" \
    FM_HOME="$FM_HOME" \
    FM_BR_RECEIPT_BIN="$FM_BR_RECEIPT_BIN" \
    FM_REFILL_PROJECT="$PROJECT" \
    "$FM_REFILL_SPAWN_BIN" "$id" "$PROJECT" "$FM_REFILL_HARNESS" \
    --mode "$FM_REFILL_MODE" --yolo off || {
    echo "refill: launch failed for $id" >&2
    return 1
  }
  return 0
}

# fm_refill_admit_and_dispatch <capacity-json>: query candidates, apply the
# frozen-evidence admission contract (admit vs serialize), then either win the
# home lock (state/.lock.acquire, the same claim lock bin/fm-lock.sh uses)
# plus the attempt allocation lock (fm_attempt_alloc owns
# state/attempts/.alloc.lock per candidate), re-read live bead ownership, and
# run the split handshake and launch (automatic), or stop alert-only without
# the lock when the automatic gate is off (Task 15 rollback). Never lands,
# merges, or decrements capacity.
fm_refill_admit_and_dispatch() {
  local cap=$1 candidates evid id cpath prod reserved
  local admitted=() serialized=() available=() cand
  candidates=$(fm_refill_query_candidates) || return $?
  evid=$(fm_refill_current_evidence)
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    id=$(printf '%s' "$cand" | jq -r '.id // empty' 2>/dev/null || true)
    [ -n "$id" ] || continue
    cpath=$(printf '%s' "$cand" | jq -r '.planned_path // ""' 2>/dev/null || true)
    if fm_refill_candidate_conflicts "$cpath" "$evid"; then
      serialized+=("$id")
      echo "refill: serialize $id (planned path overlaps frozen admission evidence)"
    else
      admitted+=("$id")
      echo "refill: admit $id"
    fi
  done <<< "$(printf '%s\n' "$candidates" | jq -c '.[]' 2>/dev/null || true)"
  prod=$(printf '%s' "$cap" | jq -r '.aggregate.productive_count // 0' 2>/dev/null || echo 0)
  reserved=$(printf '%s' "$cap" | jq -r '.aggregate.reserved_ownership_count // 0' 2>/dev/null || echo 0)
  echo "refill: admission productive=$prod reserved=$reserved candidates=$(( ${#admitted[@]} + ${#serialized[@]} )) admitted=${#admitted[@]} serialized=${#serialized[@]}"
  # Task 15 rollback flip: without the automatic gate, --refill is alert-only.
  # The admission verdict lines above are the summary; no home lock is won, no
  # bead is re-read, no claim is created, no launch command prints, and no
  # allocation happens. Every attempt, bead, branch, ref, copy, and receipt is
  # preserved; re-enabling the gate resumes from the persisted effect receipts
  # through the same idempotent claim-replay, obligation-retry, and
  # terminal-reconciliation paths.
  if ! fm_refill_automatic; then
    echo "fleet-ok: alert-only"
    return 0
  fi
  # automatic path: win the home lock, then re-read live bead ownership: the
  # loser of a concurrent wave sees the winner's claims and dispatches nothing
  FM_REFILL_LOCK_HELD=0
  trap fm_refill_lock_release EXIT
  fm_lock_acquire_wait "$STATE/.lock.acquire"
  FM_REFILL_LOCK_HELD=1
  available=()
  if [ "${#admitted[@]}" -gt 0 ]; then
    for id in "${admitted[@]}"; do
      if fm_refill_bead_available "$id"; then
        available+=("$id")
      else
        echo "refill: skip $id (no longer open/ready/unclaimed after the lock)" >&2
      fi
    done
  fi
  if [ "${#available[@]}" -gt 0 ]; then
    for id in "${available[@]}"; do
      fm_refill_claim_and_launch "$id"
    done
  fi
  fm_refill_lock_release
  return 0
}

if [ "${1:-}" = "--refill" ]; then
  # shellcheck source=bin/fm-capacity-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
  cap=$(fm_capacity_project)
  echo "$cap" | jq -e '.aggregate.refill_safe == true' >/dev/null || {
    echo "REFILL-UNSAFE: no attended or automatic refill on an unsafe projection" >&2
    exit 1
  }
  echo "$cap" | jq -e --argjson t "${FM_REFILL_TARGET_PRODUCTIVE:-6}" \
    --argjson c "${FM_REFILL_RESERVED_CEILING:-10}" \
    '.aggregate.productive_count < $t and .aggregate.reserved_ownership_count < $c' >/dev/null || {
    echo "fleet-ok: no refill needed"
    exit 0
  }
  fm_refill_admit_and_dispatch "$cap"
  exit $?
fi
if [ -n "${FM_REFILL_SHADOW:-}" ]; then
  # shellcheck source=bin/fm-capacity-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
  fm_capacity_project > "$FM_REFILL_SHADOW"
fi

SERIALIZATION_DEBT_PROBE="${FM_SERIALIZATION_DEBT_PROBE:-$FM_HOME/bin/fm-serialization-debt.sh}"

serialization_debt=0
"$SERIALIZATION_DEBT_PROBE" --project "$PROJECT" || serialization_debt=1

open_count="$(cd "$PROJECT" && br list --status open --json 2>/dev/null \
  | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("total", 0))
except Exception:
    print(-1)' 2>/dev/null || echo -1)"

# Task 13 cutover: the human verdict is derived solely from the shared
# fm-fleet-capacity.v1 object. No legacy capacity arithmetic remains here;
# the serialization-debt probe is a safety gate, not capacity arithmetic.
# shellcheck source=bin/fm-capacity-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
cap=$(fm_capacity_project)
productive=$(echo "$cap" | jq -r '.aggregate.productive_count // 0')
reserved=$(echo "$cap" | jq -r '.aggregate.reserved_ownership_count // 0')
refill_safe=$(echo "$cap" | jq -r '.aggregate.refill_safe // false')
alert_only=$(echo "$cap" | jq -r '.aggregate.alert_only // false')
reconciliation=$(echo "$cap" | jq -r '.aggregate.reconciliation_required // false')

echo "fleet-refill: productive=$productive reserved=$reserved refill_safe=$refill_safe alert_only=$alert_only reconciliation=$reconciliation; open_beads=$open_count; serialization_debt=$serialization_debt"
if [ "$serialization_debt" -ne 0 ]; then
  exit 1
fi
echo "fleet-ok: capacity derived from the shared projection; refill is alert-only until the automatic gate is enabled (config/refill-auto or FM_REFILL_AUTO=1)"
exit 0
