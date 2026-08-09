#!/usr/bin/env bash
# The one shared capacity and attempt projection (schema fm-fleet-capacity.v1).
#
# This library is the ONLY classifier of implementation rows and aggregate
# capacity. It consumes the structured fm-crew-state.v1 contract from
# bin/fm-crew-state.sh --json and combines it with the attempt envelope and
# effect receipts from bin/fm-attempt-lib.sh. It never reparses display text,
# defines no second worker state machine, and never reads legacy manifests,
# output paths, output modification times, worker text, or private shadow
# fields. A meta-only identity reserves one unknown slot until migration; its
# metadata never supplies productive liveness or a legacy worker count.
#
# Consumers: bin/fm-fleet-refill.sh (--count-json and, after Task 13, the
# human verdict), bin/fm-fleet-snapshot.sh (Task 13 embed), and
# bin/fm-refill-sentinel.sh (Task 13). All consume the exact object emitted
# here. FM_CAPACITY_OBSERVATION_FILE, when set, makes the projection emit that
# exact frozen object so parity tests and consumers share one observation.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-attempt-lib.sh
. "$SCRIPT_DIR/fm-attempt-lib.sh"

FM_CAPACITY_READ_TIMEOUT_SECS="${FM_CAPACITY_READ_TIMEOUT_SECS:-2}"
FM_CAPACITY_TOTAL_TIMEOUT_SECS="${FM_CAPACITY_TOTAL_TIMEOUT_SECS:-10}"
# Bounded parallel reads, default 4 (measured 2026-08-08: real-home
# count-json wall 3.25s sequential -> 1.5s at 4, consistently under the
# 2000ms budget; Task 2's gate proved byte-identical parallel output and the
# tmux backend smoke). The per-row timeout (FM_CAPACITY_READ_TIMEOUT_SECS)
# still bounds every single read, so slow-but-live workers keep their full
# timeout; only the collection phase is parallelized, and rows are sorted
# deterministically (sort_by attempt/task identity) so output ordering is
# unchanged. The whole collection still runs under FM_CAPACITY_TOTAL_TIMEOUT_SECS.
FM_CAPACITY_PARALLEL="${FM_CAPACITY_PARALLEL:-4}"
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
# Observation timestamp, frozen once at source time: every projection from one
# sourced library carries identical metadata, so parallel and sequential
# projections of the same state are byte-identical (the pinned contract that
# parallel reads must not change the output). Every consumer sources this
# library in a fresh process, so the frozen value still marks the observation.
FM_CAPACITY_GENERATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# shellcheck disable=SC2034
FM_CAPACITY_LIB_SOURCED=1

fm_capacity_rows_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

fm_capacity_entity_list() {  # -> one attempt row or meta-only ambiguity row per identity, sorted
  local dir
  dir="$(fm_capacity_rows_dir)"
  {
    if [ -d "$dir/attempts" ]; then
      find "$dir/attempts" -maxdepth 1 -name '*.json' ! -name '*.request.*.json' -printf 'attempt:%f\n' 2>/dev/null \
        | sed 's/\.json$//'
    fi
    if [ -d "$dir" ]; then
      while IFS= read -r meta; do
        [ -f "$meta" ] || continue
        printf 'meta:%s:%s\n' "$(basename "$meta" .meta)" \
          "$(sed -n 's/^attempt=//p' "$meta" | head -1)"
      done < <(find "$dir" -maxdepth 1 -name '*.meta' -print 2>/dev/null)
    fi
  } | sort
}

# fm_capacity_attempt_task: the task id bound to an attempt. The meta's
# `attempt=<id>` link is the binding (the meta file name is the task id); the
# envelope task_key is only a fallback once that meta has been cleaned up.
fm_capacity_attempt_task() {  # <attempt-id> -> task id, or the envelope task_key
  local attempt=$1 meta
  for meta in "$(fm_capacity_rows_dir)"/*.meta; do
    [ -f "$meta" ] || continue
    if [ "$(sed -n 's/^attempt=//p' "$meta" | head -1)" = "$attempt" ]; then
      basename "$meta" .meta
      return 0
    fi
  done
  fm_attempt_load "$attempt" 2>/dev/null | jq -r '.envelope.task_key // empty'
}

fm_capacity_crew_state() {  # <task-id> -> fm-crew-state.v1 JSON or empty
  local id=$1
  env \
    FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}" \
    FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-}" \
    FM_PROJECTS_OVERRIDE="${FM_PROJECTS_OVERRIDE:-}" \
    FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-}" \
    timeout --kill-after=1 "$FM_CAPACITY_READ_TIMEOUT_SECS" \
    "$FM_CREW_STATE_BIN" --json "$id" 2>/dev/null || true
}

fm_capacity_crew_state_valid() {  # <crew-json> <task-id>
  printf '%s' "$1" | jq -e --arg id "$2" '
    type == "object"
    and .schema == "fm-crew-state.v1"
    and .id == $id
    and (.state | type == "string" and IN("working", "parked", "done", "blocked", "paused", "failed", "unknown"))
    and (.source | type == "string" and length > 0)
    and (.detail | type == "string")
  ' >/dev/null 2>&1
}

fm_capacity_row() {  # <entity> where entity is attempt:<id> or meta:<id>:<attempt> -> row JSON
  local entity=$1 id meta kind attempt crew state source invalid_reason
  local gen missing productive reserved ambiguity reconciliation
  case "$entity" in
    attempt:*) attempt=${entity#attempt:} ;;
    meta:*)
      id=${entity#meta:}
      attempt=${id#*:}
      id=${id%%:*}
      meta="$(fm_capacity_rows_dir)/$id.meta"
      [ -n "$attempt" ] || attempt=$(sed -n 's/^attempt=//p' "$meta" | head -1)
      [ -z "$attempt" ] || { [ -f "$(attempt_path "$attempt")" ] && return 0; }
      [ "$(sed -n 's/^kind=//p' "$meta" | head -1)" = ship ] || return 0
      jq -n --arg id "$id" \
        '{attempt_id:null,task_key:$id,generation:null,kind:"ship",classification:"unknown",source:"none",productive:false,reserved:true,ambiguity_reasons:["missing_attempt_envelope"],missing_receipts:[],reconciliation_required:true}'
      return 0
      ;;
    *) return 0 ;;
  esac
  id=$(fm_capacity_attempt_task "$attempt")
  meta="$(fm_capacity_rows_dir)/$id.meta"
  [ -f "$meta" ] || meta=""
  [ -n "$meta" ] || meta="$(fm_capacity_rows_dir)/$id.meta"
  [ -f "$meta" ] || return 0
  kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
  [ "$kind" = ship ] || return 0
  if fm_attempt_is_retired "$attempt"; then
    gen=$(fm_attempt_generation "$attempt")
    jq -n --arg attempt "$attempt" --arg id "$id" --arg gen "$gen" \
      '{attempt_id:$attempt,task_key:$id,generation:($gen|tonumber),kind:"ship",classification:"retired",source:"retirement",productive:false,reserved:false,ambiguity_reasons:[],missing_receipts:[],reconciliation_required:false}'
    return 0
  fi
  crew=$(fm_capacity_crew_state "$id")
  invalid_reason=worker_read_timeout
  if [ -n "$crew" ]; then
    invalid_reason=worker_read_invalid
  fi
  if [ -z "$crew" ] || ! fm_capacity_crew_state_valid "$crew" "$id"; then
    jq -n --arg attempt "$attempt" --arg id "$id" \
      --arg reason "$invalid_reason" \
      '{attempt_id:$attempt,task_key:$id,generation:null,kind:"ship",classification:"unknown",source:"none",productive:false,reserved:true,ambiguity_reasons:[$reason],missing_receipts:[],reconciliation_required:true}'
    return 0
  fi
  state=$(echo "$crew" | jq -r '.state')
  source=$(echo "$crew" | jq -r '.source')
  if [ -n "$attempt" ] && [ -f "$(attempt_path "$attempt")" ]; then
    gen=$(fm_attempt_generation "$attempt")
    missing=$(fm_attempt_obligations "$attempt")
    productive=false
    reserved=true
    case "$state" in
      working) productive=true ;;
    esac
    # reconciliation is needed only when a non-working attempt cannot reach
    # terminal on its own: done/failed/unknown with outstanding obligations or
    # not yet retired. Missing receipts on a mid-flight (working/blocked/
    # paused) attempt are ordinary obligations, not reconciliation.
    ambiguity=[]
    reconciliation=false
    case "$state" in
      done|failed|unknown)
        reconciliation=true
        if [ -n "$missing" ]; then
          ambiguity=$(printf '%s' "$missing" | jq -R 'split(" ") | map("missing_receipt:" + .) + ["not_retired"]')
        else
          ambiguity=["not_retired"]
        fi ;;
      *)
        if [ -n "$missing" ]; then
          ambiguity=$(printf '%s' "$missing" | jq -R 'split(" ") | map("missing_receipt:" + .)')
        fi ;;
    esac
    jq -n --arg attempt "$attempt" --arg id "$id" --arg gen "$gen" --arg source "$source" \
      --argjson productive "$productive" --argjson reserved "$reserved" \
      --argjson ambiguity "$ambiguity" --argjson reconciliation "$reconciliation" \
      --arg missing "$missing" \
      '{attempt_id:$attempt,task_key:$id,generation:($gen|tonumber),kind:"ship",classification:"active",source:$source,productive:$productive,reserved:$reserved,ambiguity_reasons:$ambiguity,missing_receipts:($missing|split(" ")|map(select(.!=""))),reconciliation_required:$reconciliation}'
    return 0
  fi
}

fm_capacity_collect_rows() {  # writes rows to $1 and the listed-entity set to $2
  local out=$1 listed=$2 entity _meta_id
  : > "$listed"
  if [ "$FM_CAPACITY_PARALLEL" -gt 1 ]; then
    # shellcheck disable=SC2016  # Expansion is deliberately deferred to each child shell.
    fm_capacity_entity_list | tee "$listed" | xargs -P "$FM_CAPACITY_PARALLEL" -I{} \
      bash -c 'FM_CAPACITY_LIB_SOURCED=1; . "$0"; fm_capacity_row "$1"' \
      "$SCRIPT_DIR/fm-capacity-lib.sh" {} > "$out"
  else
    # list the whole entity set first, then read each row: the total-deadline
    # post-pass can only mark entities that were listed before the deadline
    while IFS= read -r entity; do
      [ -n "$entity" ] || continue
      printf '%s\n' "$entity" >> "$listed"
    done < <(fm_capacity_entity_list)
    while IFS= read -r entity; do
      [ -n "$entity" ] || continue
      # deterministic torn-read hook for tests: the record vanishes between
      # listing and read
      case "$entity" in
        attempt:*)
          _meta_id=$(fm_capacity_attempt_task "${entity#attempt:}" 2>/dev/null || true)
          [ "$_meta_id" = "${FM_CAPACITY_TEST_DISAPPEAR:-}" ] \
            && rm -f "$(fm_capacity_rows_dir)/$_meta_id.meta" ;;
        meta:*)
          _meta_id=${entity#meta:}; _meta_id=${_meta_id%%:*}
          [ "$_meta_id" = "${FM_CAPACITY_TEST_DISAPPEAR:-}" ] \
            && rm -f "$(fm_capacity_rows_dir)/$_meta_id.meta" ;;
      esac
      fm_capacity_row "$entity" >> "$out"
    done < "$listed"
  fi
}

fm_capacity_ambiguous_for() {  # <entity> <reason> -> ambiguous row JSON
  local entity=$1 reason=$2 attempt= id= meta
  case "$entity" in
    attempt:*)
      attempt=${entity#attempt:}
      id=$(fm_capacity_attempt_task "$attempt" 2>/dev/null || true)
      [ -n "$id" ] || id=$(fm_attempt_load "$attempt" 2>/dev/null | jq -r '.envelope.task_key // empty' 2>/dev/null || true)
      [ -n "$id" ] || id=$attempt
      ;;
    meta:*)
      id=${entity#meta:}
      attempt=${id#*:}
      id=${id%%:*}
      meta="$(fm_capacity_rows_dir)/$id.meta"
      [ -n "$attempt" ] || { [ -f "$meta" ] && attempt=$(sed -n 's/^attempt=//p' "$meta" | head -1); }
      ;;
    *) id=$entity ;;
  esac
  jq -n --arg attempt "$attempt" --arg id "$id" --arg reason "$reason" \
    '{attempt_id:($attempt | if . == "" then null else . end),task_key:$id,generation:null,kind:"ship",classification:"unknown",source:"none",productive:false,reserved:true,ambiguity_reasons:[$reason],missing_receipts:[],reconciliation_required:true}'
}

fm_capacity_project() {  # -> fm-fleet-capacity.v1 JSON on stdout
  local rows listed generated schema_ok deadline_ok key entity task meta
  if [ -n "${FM_CAPACITY_OBSERVATION_FILE:-}" ] && [ -f "${FM_CAPACITY_OBSERVATION_FILE}" ]; then
    cat "$FM_CAPACITY_OBSERVATION_FILE"
    return 0
  fi
  generated=$FM_CAPACITY_GENERATED
  schema_ok=true
  if [ "${FM_CAPACITY_FORCE_SCHEMA_MISMATCH:-0}" = 1 ]; then schema_ok=false; fi
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-capacity-rows.XXXXXX")
  listed=$(mktemp "${TMPDIR:-/tmp}/fm-capacity-listed.XXXXXX")
  # real total deadline: the whole collection phase runs under timeout; on
  # expiry every listed id without an observed row becomes deterministically
  # ambiguous. A listed id whose record disappeared mid-read is likewise
  # ambiguous (torn read), never silently absent.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  if env \
      FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}" \
      FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-}" \
      FM_PROJECTS_OVERRIDE="${FM_PROJECTS_OVERRIDE:-}" \
      FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-}" \
      FM_CAPACITY_READ_TIMEOUT_SECS="${FM_CAPACITY_READ_TIMEOUT_SECS:-}" \
      FM_CAPACITY_TOTAL_TIMEOUT_SECS="${FM_CAPACITY_TOTAL_TIMEOUT_SECS:-}" \
      FM_CAPACITY_PARALLEL="${FM_CAPACITY_PARALLEL:-}" \
      FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-}" \
      FM_CAPACITY_TEST_DISAPPEAR="${FM_CAPACITY_TEST_DISAPPEAR:-}" \
      timeout "$FM_CAPACITY_TOTAL_TIMEOUT_SECS" \
      bash -c '. "$1"; fm_capacity_collect_rows "$2" "$3"' \
      _ "$SCRIPT_DIR/fm-capacity-lib.sh" "$rows" "$listed" >/dev/null 2>&1; then
    deadline_ok=true
  else
    deadline_ok=false
  fi
  # deterministic post-pass: every listed entity without a row is ambiguous,
  # unless its absence is provably legitimate (an excluded kind, or a retired
  # attempt whose meta was already cleaned). A listed id whose record
  # disappeared mid-read is ambiguous (torn read), never silently absent.
  while IFS= read -r entity; do
    [ -n "$entity" ] || continue
    key=${entity#attempt:}
    key=${key#meta:}
    key=${key%%:*}
    if jq -se --arg key "$key" '[.[] | select(.task_key == $key or .attempt_id == $key)] | length > 0' "$rows" >/dev/null 2>&1; then
      continue
    fi
    case "$entity" in
      meta:*)
        if [ -f "$(fm_capacity_rows_dir)/$key.meta" ]; then
          [ "$(sed -n 's/^kind=//p' "$(fm_capacity_rows_dir)/$key.meta" | head -1)" = ship ] || continue
        fi
        ;;
      attempt:*)
        task=$(fm_capacity_attempt_task "$key" 2>/dev/null || true)
        meta="$(fm_capacity_rows_dir)/$task.meta"
        if [ -f "$meta" ] && [ "$(sed -n 's/^kind=//p' "$meta" | head -1)" != ship ]; then
          continue
        fi
        # a retired attempt contributes nothing even after its meta is
        # cleaned; a mid-flight attempt with no row is a torn read
        if [ -f "$(attempt_path "$key")" ] && fm_attempt_is_retired "$key"; then
          continue
        fi
        ;;
    esac
    fm_capacity_ambiguous_for "$entity" "$([ "$deadline_ok" = true ] && echo record_disappeared || echo worker_read_timeout)" >> "$rows"
  done < "$listed"
  rm -f "$listed"
  jq -s --arg generated "$generated" \
    --arg home "${FM_HOME:-local}" \
    --argjson schema_ok "$schema_ok" \
    --argjson deadline_ok "$deadline_ok" \
    '. as $rows |
     def unreliable: ([$rows[] | select(any(.ambiguity_reasons[]?; IN("worker_read_timeout", "worker_read_invalid", "record_disappeared")))] | length) > 0;
     def incomplete: (unreliable) or ($schema_ok | not) or ($deadline_ok | not);
     def reconciliation: ([$rows[] | select(.reconciliation_required == true)] | length > 0);
     def complete: ((unreliable | not) and ($deadline_ok));
     {
       schema:"fm-fleet-capacity.v1",
       generated:$generated,
       home_id:$home,
       observation_complete:complete,
       total_timeout:($deadline_ok | not),
       schema_ok:$schema_ok,
       alert_only:incomplete,
       reconciliation_required:reconciliation,
       rows:($rows | sort_by(.attempt_id // .task_key)),
       aggregate:{
         productive_count:([$rows[]|select(.productive == true)]|length),
         reserved_ownership_count:([$rows[]|select(.reserved == true)]|length),
         ambiguous_count:([$rows[]|select((.ambiguity_reasons|length) > 0)]|length),
         observation_complete:complete,
         alert_only:incomplete,
         reconciliation_required:reconciliation,
         refill_safe:(complete and (incomplete | not) and (reconciliation | not))
       }
     }' "$rows"
  rm -f "$rows"
}
