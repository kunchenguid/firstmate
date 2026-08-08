#!/usr/bin/env bash
# Public-interface tests for the one shared capacity projection
# (fm-fleet-capacity.v1). Fixtures: implementation, validation, merge wait,
# terminal states, ambiguity, per-row timeout, total deadline, disappearing
# and torn records, malformed structured output, scouts, second mates, schema
# failure, and retirement-before-projection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-capacity)
STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
mkdir -p "$STATE" "$DATA"

export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"
export FM_CAPACITY_READ_TIMEOUT_SECS=2
export FM_CAPACITY_TOTAL_TIMEOUT_SECS=10
export FM_CREW_STATE_BIN="$TMP_ROOT/fm-crew-state.sh"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$ROOT/bin/fm-capacity-lib.sh"

write_meta() {  # <id> <kind> <mode> [attempt=]
  local id=$1 kind=$2 mode=$3 extra=${4:-}
  {
    printf 'window=w-%s\n' "$id"
    printf 'kind=%s\n' "$kind"
    printf 'mode=%s\n' "$mode"
    printf 'worktree=%s/wt-%s\n' "$TMP_ROOT" "$id"
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$STATE/$id.meta"
}

fake_crew_state() {  # writes a fake fm-crew-state.sh that emits the given structured JSON
  cat > "$TMP_ROOT/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$1'
SH
  chmod +x "$TMP_ROOT/fm-crew-state.sh"
}

# Every capacity assertion is a global aggregate over the shared state dir, so
# each fixture must be self-contained: clear the state/data dirs (but keep the
# fake fm-crew-state.sh, which lives outside STATE) before building the next
# fixture. The pinned plan omitted this per-test isolation.
fresh_state() {
  rm -rf "$STATE" "$DATA"
  mkdir -p "$STATE" "$DATA"
}

test_implementation_is_productive_and_reserved() {
  fresh_state
  local aid out
  aid=$(fm_attempt_alloc pi dos-a holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-x"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w1"}' || fail "launch"
  write_meta "task-x" ship direct-PR "attempt=$aid"
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"task-x","state":"working","source":"run-step","detail":"validating x"}'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 1' >/dev/null || fail "productive != 1"
  echo "$out" | jq -e '.aggregate.reserved_ownership_count == 1' >/dev/null || fail "reserved != 1"
  echo "$out" | jq -e '.aggregate.refill_safe == true' >/dev/null || fail "not refill safe"
  pass "active implementation is productive and reserved"
}

test_merge_wait_stays_reserved() {
  fresh_state
  local aid out
  aid=$(fm_attempt_alloc pi dos-b holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-y"}' \
    '{"mode":"no-mistakes","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w2"}' || fail "launch"
  fm_attempt_effect_observe "$aid" 1 landing '{"disposition":"landed","pr":"https://github.com/kunchenguid/firstmate/pull/1"}' \
    || fail "landing"
  write_meta "task-y" ship no-mistakes "attempt=$aid"
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"task-y","state":"done","source":"status-log","detail":"done: PR checks green"}'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 0' >/dev/null || fail "merge wait counted productive"
  echo "$out" | jq -e '.aggregate.reserved_ownership_count == 1' >/dev/null || fail "merge wait not reserved"
  echo "$out" | jq -e '.aggregate.reconciliation_required == true' >/dev/null || fail "merge wait did not need reconciliation"
  pass "merge-waiting delivery stays reserved until retirement"
}

test_retired_attempt_contributes_nothing() {
  fresh_state
  local aid out
  aid=$(fm_attempt_alloc pi dos-c holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-z"}' \
    '{"mode":"local-only","base":"main","target":"local-main"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-c","status":"claimed"}' || fail "claim"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w3"}' || fail "launch"
  fm_attempt_effect_observe "$aid" 1 landing '{"disposition":"landed","local_main":"abc123"}' || fail "landing"
  fm_attempt_effect_observe "$aid" 1 tracker '{"bead":"dos-c","status":"closed"}' || fail "tracker"
  fm_attempt_effect_observe "$aid" 1 cleanup.endpoint '{"endpoint":"w3","gone":true}' || fail "endpoint"
  fm_attempt_effect_observe "$aid" 1 cleanup.branch '{"fate":"deleted"}' || fail "branch"
  fm_attempt_effect_observe "$aid" 1 cleanup.provider '{"returned":true}' || fail "provider"
  fm_attempt_effect_observe "$aid" 1 cleanup.runtime '{"records_removed":true}' || fail "runtime"
  fm_attempt_retire "$aid" 1 '{"audit":"terminal","disposition":"landed"}' || fail "retire"
  write_meta "task-z" ship local-only "attempt=$aid"
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"task-z","state":"done","source":"status-log","detail":"done: ready in branch"}'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 0 and .aggregate.reserved_ownership_count == 0' >/dev/null \
    || fail "retired attempt still counted"
  pass "only an atomically retired attempt contributes neither productive nor reserved capacity"
}

test_legacy_row_without_envelope_needs_reconciliation() {
  fresh_state
  local out
  write_meta "legacy-1" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"legacy-1","state":"working","source":"pane","detail":"busy"}'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.rows[0].ambiguity_reasons | index("missing_attempt_envelope") != null' >/dev/null \
    || fail "legacy row did not name missing envelope"
  echo "$out" | jq -e '.aggregate.reconciliation_required == true' >/dev/null || fail "no reconciliation flag"
  pass "legacy task without an envelope is ambiguous and requires reconciliation"
}

test_scout_and_secondmate_are_excluded() {
  fresh_state
  local out
  write_meta "scout-1" scout direct-PR
  write_meta "sm-1" secondmate direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"scout-1","state":"working","source":"run-step","detail":"investigating"}'
  out=$(fm_capacity_project)
  [ "$(echo "$out" | jq '.rows | length')" = 0 ] || fail "scouts/secondmates appeared in rows"
  pass "scouts and persistent second mates are excluded from implementation capacity"
}

test_per_row_timeout_yields_ambiguous_row() {
  fresh_state
  local out
  write_meta "slow-1" ship direct-PR
  cat > "$TMP_ROOT/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$TMP_ROOT/fm-crew-state.sh"
  out=$(FM_CAPACITY_READ_TIMEOUT_SECS=1 fm_capacity_project)
  echo "$out" | jq -e '.aggregate.observation_complete == false' >/dev/null || fail "timeout looked complete"
  echo "$out" | jq -e '.aggregate.alert_only == true' >/dev/null || fail "incomplete observation was not alert-only"
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null || fail "refill considered safe on timeout"
  pass "a timed-out worker read yields an ambiguous row and alert-only refill"
}

test_total_deadline_marks_unfinished_rows_ambiguous() {
  fresh_state
  local out
  write_meta "slow-a" ship direct-PR
  write_meta "slow-b" ship direct-PR
  cat > "$TMP_ROOT/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$TMP_ROOT/fm-crew-state.sh"
  out=$(FM_CAPACITY_READ_TIMEOUT_SECS=30 FM_CAPACITY_TOTAL_TIMEOUT_SECS=1 fm_capacity_project)
  echo "$out" | jq -e '.aggregate.observation_complete == false' >/dev/null || fail "total deadline ignored"
  echo "$out" | jq -e '[.rows[] | select(.ambiguity_reasons | index("worker_read_timeout") != null)] | length >= 2' >/dev/null \
    || fail "unfinished rows not deterministically ambiguous"
  pass "the total deadline marks every unfinished row ambiguous and incomplete"
}

test_disappearing_record_is_ambiguous() {
  fresh_state
  local out
  write_meta "gone-1" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"gone-1","state":"working","source":"run-step","detail":"busy"}'
  # FM_CAPACITY_TEST_DISAPPEAR simulates a torn read: the record vanishes
  # between listing and row read
  out=$(FM_CAPACITY_TEST_DISAPPEAR=gone-1 fm_capacity_project)
  echo "$out" | jq -e --arg id gone-1 \
    '[.rows[] | select(.task_key == $id) | .ambiguity_reasons | index("record_disappeared") != null] | any' >/dev/null \
    || fail "disappearing record not ambiguous"
  echo "$out" | jq -e --arg id gone-1 \
    '[.rows[] | select(.task_key == $id) | .reserved == true] | any' >/dev/null \
    || fail "disappearing record became a free slot"
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null \
    || fail "disappearing record looked refill-safe"
  pass "a disappearing record yields an ambiguous reserved row, never a free slot or zero capacity"
}

test_malformed_structured_output_is_ambiguous() {
  fresh_state
  local out
  write_meta "bad-1" ship direct-PR
  fake_crew_state 'this is not json'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.alert_only == true' >/dev/null || fail "malformed output not alert-only"
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null || fail "malformed output looked refill-safe"
  pass "malformed structured worker output yields ambiguity, never idle or zero work"
}

test_schema_failure_is_alert_only() {
  fresh_state
  local out
  write_meta "bad-2" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"bad-2","state":"working","source":"run-step","detail":"busy"}'
  out=$(FM_CAPACITY_FORCE_SCHEMA_MISMATCH=1 fm_capacity_project 2>/dev/null || true)
  echo "$out" | jq -e '.schema == "fm-fleet-capacity.v1"' >/dev/null || fail "schema changed"
  echo "$out" | jq -e '.schema_ok == false and .alert_only == true and .aggregate.refill_safe == false' >/dev/null \
    || fail "schema mismatch did not make consumers alert-only"
  pass "a schema mismatch makes both automatic consumers alert-only while preserving ownership"
}

test_aggregates_are_exactly_derivable_from_rows() {
  fresh_state
  local out derived
  write_meta "r1" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"r1","state":"blocked","source":"status-log","detail":"blocked: need credential"}'
  out=$(fm_capacity_project)
  derived=$(echo "$out" | jq '{pc:([.rows[]|select(.productive)]|length),rc:([.rows[]|select(.reserved)]|length),ac:([.rows[]|select((.ambiguity_reasons|length)>0)]|length)}')
  echo "$out" | jq -e --argjson d "$derived" \
    '.aggregate.productive_count == $d.pc and .aggregate.reserved_ownership_count == $d.rc and .aggregate.ambiguous_count == $d.ac' >/dev/null \
    || fail "aggregate not derivable from rows: $derived"
  pass "every aggregate is exactly derivable from the emitted rows"
}

test_parallel_reads_are_byte_identical() {
  fresh_state
  local a b
  write_meta "p1" ship direct-PR
  write_meta "p2" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"p1","state":"working","source":"run-step","detail":"busy"}'
  a=$(fm_capacity_project | jq -cS .)
  b=$(FM_CAPACITY_PARALLEL=4 fm_capacity_project | jq -cS .)
  [ "$a" = "$b" ] || fail "parallel projection differs from sequential"
  pass "bounded parallel reads produce byte-identical output to sequential reads"
}

test_implementation_is_productive_and_reserved
test_merge_wait_stays_reserved
test_retired_attempt_contributes_nothing
test_legacy_row_without_envelope_needs_reconciliation
test_scout_and_secondmate_are_excluded
test_per_row_timeout_yields_ambiguous_row
test_total_deadline_marks_unfinished_rows_ambiguous
test_disappearing_record_is_ambiguous
test_malformed_structured_output_is_ambiguous
test_schema_failure_is_alert_only
test_aggregates_are_exactly_derivable_from_rows
test_parallel_reads_are_byte_identical

echo "all fm-capacity tests passed"
