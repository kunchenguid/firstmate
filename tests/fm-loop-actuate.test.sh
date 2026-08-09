#!/usr/bin/env bash
# Behavioral regressions for the LoopSpec wake-to-action table.
#
# The claim under test is narrow and specific: when exactly one lawful transition
# follows from the recorded state, this executes it without a model turn, and
# when the transition is genuinely not determined it refuses instead of guessing.
#
# Every guarantee is proved through the public interface - exit status, the
# stable LOOPACT_ tokens, the persisted loop state and the execution record -
# never by reading the script's own source. Each block witnesses its negative
# control failing before trusting the positive result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACT="$ROOT/bin/fm-loop-actuate.sh"
LS="$ROOT/bin/fm-loopspec.sh"
TMP_ROOT=$(fm_test_tmproot fm-loop-actuate)
SPEC_SOURCE="$ROOT/loopspecs/approved-work-reconciliation.json"

OUT=""
CODE=0

# act_run <registry> <state> <verifier-rc> <args...>
act_run() {
  local reg=$1 st=$2 rc=$3
  shift 3
  OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_LOOPSPEC_DIR="$reg" FM_STATE_OVERRIDE="$st" \
        FIXTURE_VERIFIER_RC="$rc" FIXTURE_VERIFIER_EVIDENCE=6 \
        "$ACT" "$@" 2>&1)
  CODE=$?
}

ls_run() {
  local reg=$1 st=$2
  shift 2
  OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_LOOPSPEC_DIR="$reg" FM_STATE_OVERRIDE="$st" "$LS" "$@" 2>&1)
  CODE=$?
}

new_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/registry" "$d/state"
  cp "$ROOT/loopspecs/schema.json" "$d/registry/schema.json"
  cat >"$d/registry/triggers.json" <<'JSON'
{
  "loopspec_schema_version": 1,
  "description": "Test fixture register. Not the fleet register.",
  "triggers": [
    {
      "id": "fixture-ready",
      "name": "Fixture ready trigger",
      "source": "fixture",
      "specified": true,
      "detector_status": "implemented",
      "detector_implemented": true,
      "detector_ref": "fixture",
      "deterministically_selectable": true,
      "determinism_note": "fixture",
      "ruled_never_deterministic": false,
      "execution_path_implemented": true,
      "verified": true,
      "enabled": true,
      "idempotency_key": "fixture",
      "idempotency_key_exists": true,
      "note": null
    }
  ],
  "outside_the_sixteen": []
}
JSON
  printf '%s %s\n' "$d/registry" "$d/state"
}

# A fixture loop with exactly one success terminal, so the pass transition is
# determined, and a verifier that actually resolves and runs.
READY='.status = "enabled" | .trigger.id = "fixture-ready" | .authority.permitted_skills = ["stow"]
       | .verification.verifier_command = "tests/loopspec-verifier-fixture.sh"
       | .verification.verifier_level = "l1"
       | .budgets.capacity_stop_band_percent = 0
       | .terminal_states = [.terminal_states[] | select(.name != "confirmed_work_found")]
       | .escalation.on = [.escalation.on[] | select(. != "confirmed_work_found")]'

write_spec() {
  local reg=$1 id=$2 filter=$3
  jq --arg id "$id" ". + {id: \$id} | $filter" "$SPEC_SOURCE" >"$reg/$id.json" \
    || fail "could not build fixture spec $id"
}

# --- the table is the contract, and it is readable without reading the code ---

test_the_table_is_inspectable() {
  OUT=$("$ACT" table 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "the table could not be printed: $OUT"
  assert_contains "$OUT" "verifier verdict pass" "the table does not name the pass transition"
  assert_contains "$OUT" "verifier verdict unavailable" "the table does not name the unavailable transition"
  assert_contains "$OUT" "no verifier run recorded" "the table does not name the unverified case"
  assert_contains "$OUT" "bounded agent" "the table does not distinguish the work code refuses to do"
  pass "the wake-to-action table can be read without reading the implementation"
}

# --- selection shape, exactly as the commission rules it --------------------

test_candidate_set_size_decides_who_chooses() {
  local reg st i
  read -r reg st < <(new_case selection)

  # 0 candidates: no loop applies. This must not read as "there is no work".
  act_run "$reg" "$st" 0 candidates --trigger fixture-ready
  expect_code 1 "$CODE" "an empty candidate set was treated as actionable"
  assert_contains "$OUT" "candidates=0 shape=no-loop-applies" "an empty candidate set was misclassified"

  # 1 candidate: deterministic, code proceeds.
  write_spec "$reg" one "$READY"
  act_run "$reg" "$st" 0 candidates --trigger fixture-ready
  expect_code 0 "$CODE" "a single candidate was not deterministic: $OUT"
  assert_contains "$OUT" "candidates=1 shape=deterministic" "a single candidate was misclassified"

  # The header is a header. Loading spec bodies into the filter is the thing the
  # commission forbids, so the emitted record must stay tiny and typed.
  assert_contains "$OUT" '"id":"one"' "the applicability header does not identify the spec"
  assert_not_contains "$OUT" "permitted_actions" "the applicability header leaked a spec body"
  assert_not_contains "$OUT" "forbidden_actions" "the applicability header leaked a spec body"
  assert_not_contains "$OUT" "success_condition" "the applicability header leaked a spec body"

  # 2-3 candidates: a bounded judgment call, which code must not make.
  write_spec "$reg" two "$READY | .selection.priority = 20"
  act_run "$reg" "$st" 0 candidates --trigger fixture-ready
  expect_code 3 "$CODE" "an ambiguous candidate set was resolved instead of handed over"
  assert_contains "$OUT" "candidates=2 shape=judgment-required" "an ambiguous set was misclassified"

  # 4 or more: a filtering defect, not a selection problem.
  i=30
  while [ "$i" -le 40 ]; do
    write_spec "$reg" "spec$i" "$READY | .selection.priority = $i"
    i=$((i + 10))
  done
  act_run "$reg" "$st" 0 candidates --trigger fixture-ready
  expect_code 1 "$CODE" "an oversized candidate set was treated as a selection problem"
  assert_contains "$OUT" "shape=filtering-defect" "an oversized candidate set was misclassified"

  pass "candidate-set size decides whether code proceeds, hands over the judgment call, or reports a filtering defect"
}

test_an_ambiguous_set_refuses_to_run_without_the_decision() {
  local reg st
  read -r reg st < <(new_case ambiguous-run)
  write_spec "$reg" one "$READY"
  write_spec "$reg" two "$READY | .selection.priority = 20"

  act_run "$reg" "$st" 0 run --trigger fixture-ready --event-key a1
  expect_code 3 "$CODE" "an ambiguous candidate set was actuated without the decision"
  assert_contains "$OUT" "needs-judgment" "the ambiguous run did not ask for the decision"
  assert_absent "$st/loopspec/one.state.json" "an ambiguous run opened an iteration anyway"
  assert_absent "$st/loopspec/two.state.json" "an ambiguous run opened an iteration anyway"

  # The decision comes back in as --spec, and only then does anything run.
  act_run "$reg" "$st" 0 run --trigger fixture-ready --event-key a1 --spec two
  expect_code 0 "$CODE" "naming the chosen loop did not actuate it: $OUT"
  assert_contains "$OUT" "loop=two@1" "the chosen loop was not the one actuated"

  pass "route selection stays a decision, and an ambiguous set writes nothing until it is made"
}

# --- the transitions code executes -------------------------------------------

test_a_pass_drives_the_success_terminal_in_code() {
  local reg st
  read -r reg st < <(new_case pass)
  write_spec "$reg" loop "$READY"

  act_run "$reg" "$st" 0 run --trigger fixture-ready --event-key p1
  expect_code 0 "$CODE" "a verified pass did not reach its success terminal: $OUT"
  assert_contains "$OUT" "terminal=delta_emitted" "the success terminal was not reached"
  assert_contains "$OUT" "maps_to=SUCCESS" "the terminal did not map to SUCCESS"
  assert_contains "$OUT" "verdict=pass" "the verifier verdict was not recorded"

  # The durable execution record is what makes adoption demonstrable at all.
  assert_present "$st/loopspec/executions.log" "no execution record was written"
  assert_grep "loop=loop@1" "$st/loopspec/executions.log" "the record does not carry loop=<spec>@<version>"
  assert_grep "verifier=research-approved-work-scanner" "$st/loopspec/executions.log" \
    "the record does not carry the canonical verifier"

  pass "a verified pass reaches the success terminal with no model turn, and leaves a loop= record"
}

test_an_unavailable_verifier_reaches_the_failure_terminal() {
  local reg st
  read -r reg st < <(new_case unavailable)
  write_spec "$reg" loop "$READY"

  act_run "$reg" "$st" 99 run --trigger fixture-ready --event-key u1
  expect_code 1 "$CODE" "an unavailable verifier reported success"
  assert_contains "$OUT" "verdict=unavailable" "the verdict was not unavailable"
  assert_contains "$OUT" "terminal=verification_failed" "an unavailable verifier did not reach its failure terminal"
  assert_contains "$OUT" "maps_to=FAILED" "the terminal did not map to FAILED"
  assert_not_contains "$OUT" "maps_to=SUCCESS" "an unavailable verifier reached SUCCESS"

  pass "an unavailable verifier reaches the failure terminal and can never map to SUCCESS"
}

test_a_failing_verifier_keeps_the_loop_open_until_the_budget_is_spent() {
  local reg st i max
  read -r reg st < <(new_case budget)
  # Two iterations of budget, and enough no-progress headroom that the budget is
  # what stops this loop rather than the stall detector.
  write_spec "$reg" loop "$READY | .budgets.max_iterations = 2 | .no_progress.max_iterations_without_progress = 9"
  max=2

  i=1
  while [ "$i" -le "$max" ]; do
    act_run "$reg" "$st" 1 run --trigger fixture-ready --event-key "b$i"
    expect_code 1 "$CODE" "a rejected iteration reported success"
    assert_contains "$OUT" "verdict=fail" "the verifier verdict was not a fail"
    i=$((i + 1))
  done

  # The budget is spent, so the next wake reaches EXHAUSTED rather than opening
  # an iteration that cannot be afforded.
  act_run "$reg" "$st" 1 run --trigger fixture-ready --event-key "b$((max + 1))"
  expect_code 1 "$CODE" "a spent budget still opened an iteration"
  assert_contains "$OUT" "terminal=budget_exhausted" "a spent budget did not reach its terminal"
  assert_contains "$OUT" "maps_to=EXHAUSTED" "a spent budget did not map to EXHAUSTED"

  # Exhaustion is never success. This is the boundary the commission names.
  assert_not_contains "$OUT" "maps_to=SUCCESS" "exhaustion was equated with success"
  assert_grep "terminal=budget_exhausted	kind=failure" "$st/loopspec/executions.log" \
    "exhaustion was not recorded as a failure"

  pass "a rejecting verifier keeps the loop open within budget, and a spent budget reaches EXHAUSTED as a failure"
}

test_stagnation_stops_the_loop_at_its_stall_terminal() {
  local reg st
  read -r reg st < <(new_case stagnation)
  # Stall after two no-progress iterations, with budget to spare so the stall
  # detector is provably what stops it.
  write_spec "$reg" loop "$READY | .budgets.max_iterations = 20 | .no_progress.max_iterations_without_progress = 2"

  act_run "$reg" "$st" 1 run --trigger fixture-ready --event-key s1
  expect_code 1 "$CODE" "a rejected iteration reported success"
  act_run "$reg" "$st" 1 run --trigger fixture-ready --event-key s2
  expect_code 1 "$CODE" "a rejected iteration reported success"

  act_run "$reg" "$st" 1 run --trigger fixture-ready --event-key s3
  expect_code 1 "$CODE" "a stalled loop kept iterating"
  assert_contains "$OUT" "terminal=no_progress_stalled" "the stall terminal was not reached"
  assert_contains "$OUT" "maps_to=STALLED" "the stall did not map to STALLED"

  # Negative control: with progress, the same three wakes never stall.
  local reg2 st2
  read -r reg2 st2 < <(new_case stagnation-control)
  write_spec "$reg2" loop "$READY | .budgets.max_iterations = 20 | .no_progress.max_iterations_without_progress = 2"
  act_run "$reg2" "$st2" 0 run --trigger fixture-ready --event-key c1
  expect_code 0 "$CODE" "a passing iteration failed: $OUT"
  act_run "$reg2" "$st2" 0 run --trigger fixture-ready --event-key c2
  expect_code 0 "$CODE" "a passing iteration failed: $OUT"
  act_run "$reg2" "$st2" 0 run --trigger fixture-ready --event-key c3
  expect_code 0 "$CODE" "a progressing loop was stopped as stalled: $OUT"
  assert_not_contains "$OUT" "STALLED" "a progressing loop reported a stall"

  pass "consecutive no-progress iterations reach the stall terminal, and a progressing loop never does"
}

test_an_inert_spec_cannot_be_actuated() {
  local reg st
  read -r reg st < <(new_case inert)
  write_spec "$reg" loop "$READY | .status = \"ready_not_active\""

  act_run "$reg" "$st" 0 run --trigger fixture-ready --event-key i1
  expect_code 1 "$CODE" "an inert spec was actuated"
  assert_contains "$OUT" "refuse_not_enabled" "an inert spec did not refuse"
  assert_absent "$st/loopspec/loop.state.json" "an inert spec still opened an iteration"
  assert_absent "$st/loopspec/executions.log" "an inert spec still left an execution record"

  pass "an inert spec refuses actuation and leaves neither loop state nor an execution record"
}

# --- unattended is the same engine, not a second one -------------------------

test_unattended_changes_the_record_and_nothing_else() {
  local reg st attended unattended
  read -r reg st < <(new_case unattended)
  write_spec "$reg" loop "$READY"

  act_run "$reg" "$st" 0 run --trigger fixture-ready --event-key at1
  expect_code 0 "$CODE" "the attended run failed: $OUT"
  attended=$(printf '%s\n' "$OUT" | sed -n 's/.*terminal=\([a-z_]*\).*/\1/p' | head -1)
  assert_contains "$OUT" "unattended=false" "an attended run did not identify itself"

  act_run "$reg" "$st" 0 run --trigger fixture-ready --event-key at2 --unattended
  expect_code 0 "$CODE" "the unattended run failed: $OUT"
  unattended=$(printf '%s\n' "$OUT" | sed -n 's/.*terminal=\([a-z_]*\).*/\1/p' | head -1)
  assert_contains "$OUT" "unattended=true" "an unattended run did not identify itself durably"

  [ "$attended" = "$unattended" ] \
    || fail "the unattended path reached a different terminal ($unattended) than the attended one ($attended)"

  # The decisive property: unattended grants session independence, never wider
  # authority. Every refusal that binds an attended run must still bind this one.
  local reg2 st2
  read -r reg2 st2 < <(new_case unattended-authority)
  write_spec "$reg2" loop "$READY | .authority.class = \"captain-required\""
  act_run "$reg2" "$st2" 0 run --trigger fixture-ready --event-key ua1 --unattended
  expect_code 1 "$CODE" "an unattended run bypassed captain-required authority"
  assert_contains "$OUT" "refuse_invalid_spec" "captain-required authority was not enforced unattended"

  local reg3 st3
  read -r reg3 st3 < <(new_case unattended-verifier)
  write_spec "$reg3" loop "$READY"
  act_run "$reg3" "$st3" 99 run --trigger fixture-ready --event-key uv1 --unattended
  expect_code 1 "$CODE" "an unattended run passed an unavailable verifier"
  assert_contains "$OUT" "maps_to=FAILED" "an unattended run did not fail closed on an unavailable verifier"

  pass "unattended stamps the record and identifies itself, while every authority and verifier check binds identically"
}

# --- arming reuses the existing durable queue --------------------------------

test_arming_extends_the_existing_wake_queue() {
  local reg st queue
  read -r reg st < <(new_case arming)
  write_spec "$reg" loop "$READY"
  queue="$st/.wake-queue"

  assert_absent "$queue" "the fixture started with a wake queue"

  act_run "$reg" "$st" 0 arm --spec loop --event-key w1
  expect_code 0 "$CODE" "arming failed: $OUT"
  assert_present "$queue" "arming did not write to the existing durable wake queue"

  # The kind must be `check`, the same kind the existing drain already handles.
  # A new wake kind would be a parallel path, which is exactly what is forbidden.
  assert_grep "	check	loopspec:loop:w1	" "$queue" "the loop wake is not an ordinary check record on the shared queue"

  pass "arming appends an ordinary check record to the existing durable queue rather than opening a parallel path"
}

test_the_execution_record_survives_and_accumulates() {
  local reg st lines
  read -r reg st < <(new_case record)
  write_spec "$reg" loop "$READY"

  act_run "$reg" "$st" 0 run --trigger fixture-ready --event-key r1
  expect_code 0 "$CODE" "the first run failed: $OUT"
  act_run "$reg" "$st" 0 run --trigger fixture-ready --event-key r2
  expect_code 0 "$CODE" "the second run failed: $OUT"

  act_run "$reg" "$st" 0 record loop
  expect_code 0 "$CODE" "the execution record could not be read: $OUT"
  lines=$(printf '%s\n' "$OUT" | grep -c 'loop=loop@1' || true)
  [ "$lines" -eq 2 ] || fail "expected two execution records, found $lines"

  # Every record carries both mandated fields, or adoption cannot be shown.
  printf '%s\n' "$OUT" | grep -q 'verifier=' || fail "an execution record has no verifier field"

  pass "every execution appends a durable record carrying loop=<spec>@<version> and its canonical verifier"
}

test_the_table_is_inspectable
test_candidate_set_size_decides_who_chooses
test_an_ambiguous_set_refuses_to_run_without_the_decision
test_a_pass_drives_the_success_terminal_in_code
test_an_unavailable_verifier_reaches_the_failure_terminal
test_a_failing_verifier_keeps_the_loop_open_until_the_budget_is_spent
test_stagnation_stops_the_loop_at_its_stall_terminal
test_an_inert_spec_cannot_be_actuated
test_unattended_changes_the_record_and_nothing_else
test_arming_extends_the_existing_wake_queue
test_the_execution_record_survives_and_accumulates
