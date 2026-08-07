#!/usr/bin/env bash
# Behavioral regressions for the canonical LoopSpec representation: schema
# validation, deterministic selection, and persistent loop state.
#
# Every guarantee here is proved through bin/fm-loopspec.sh's public interface -
# its exit status, its stable refusal tokens, and the state it persists - never
# by reading the script's own source.
#
# Each block witnesses its negative control failing before trusting the positive
# result, because a validator that cannot fail proves nothing by passing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LS="$ROOT/bin/fm-loopspec.sh"
TMP_ROOT=$(fm_test_tmproot fm-loopspec)
SPEC_SOURCE="$ROOT/loopspecs/approved-work-reconciliation.json"

OUT=""
CODE=0

# ls_run <registry-dir> <state-dir> <args...> - capture combined output and code.
ls_run() {
  local reg=$1 st=$2
  shift 2
  OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_LOOPSPEC_DIR="$reg" FM_STATE_OVERRIDE="$st" \
        "$LS" "$@" 2>&1)
  CODE=$?
}

# new_case <name> - a fresh registry + state pair; echoes "<registry> <state>".
# The fixture register declares one fully implemented trigger and one that is
# specified only, so the enabled path can be exercised without ever claiming
# that a real trigger is implemented.
new_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/registry" "$d/state"
  cp "$ROOT/loopspecs/schema.json" "$d/registry/schema.json"
  cp "$ROOT/loopspecs/terminal-states.json" "$d/registry/terminal-states.json"
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
    },
    {
      "id": "fixture-unready",
      "name": "Fixture specified-only trigger",
      "source": "fixture",
      "specified": true,
      "detector_status": "none",
      "detector_implemented": false,
      "detector_ref": null,
      "deterministically_selectable": false,
      "determinism_note": "fixture",
      "ruled_never_deterministic": false,
      "execution_path_implemented": false,
      "verified": false,
      "enabled": false,
      "idempotency_key": "fixture",
      "idempotency_key_exists": false,
      "note": null
    }
  ],
  "outside_the_sixteen": []
}
JSON
  printf '%s %s\n' "$d/registry" "$d/state"
}

# write_spec <registry> <id> <jq-filter> - derive a fixture spec from the real
# shipped instance, so a fixture can never drift away from the live contract.
write_spec() {
  local reg=$1 id=$2 filter=$3
  jq --arg id "$id" ". + {id: \$id} | $filter" "$SPEC_SOURCE" >"$reg/$id.json" \
    || fail "could not build fixture spec $id"
}

# An enabled spec needs an installed skill; stow ships in this repo.
READY='.status = "enabled" | .trigger.id = "fixture-ready" | .authority.permitted_skills = ["stow"]'

# --- the validator can fail, then the shipped registry passes ----------------

test_validator_is_not_vacuous() {
  local reg st
  read -r reg st < <(new_case validator-not-vacuous)

  write_spec "$reg" broken-missing "del(.goal)"
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a spec missing a required field was accepted"
  assert_contains "$OUT" "refuse_invalid_spec" "missing required field was not refused"
  assert_contains "$OUT" "missing required field: goal" "the missing field was not named"
  rm -f "$reg/broken-missing.json"

  write_spec "$reg" broken-unknown '. + {bogus_field: "x"}'
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "an unknown field was accepted"
  assert_contains "$OUT" "unknown field: bogus_field" "the unknown field was not named"
  rm -f "$reg/broken-unknown.json"

  write_spec "$reg" broken-enum '.status = "somewhat-enabled"'
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "an unknown status was accepted"
  assert_contains "$OUT" "wrong type for status" "the bad enum was not reported"
  rm -f "$reg/broken-enum.json"

  write_spec "$reg" broken-terminals 'del(.terminal_states[] | select(.name == "needs_ruling"))'
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a spec missing a required terminal state was accepted"
  assert_contains "$OUT" "missing required terminal state: needs_ruling" \
    "the missing terminal state was not named"
  rm -f "$reg/broken-terminals.json"

  write_spec "$reg" broken-filename '.id = "not-my-filename"'
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a spec whose id disagrees with its filename was accepted"
  assert_contains "$OUT" "does not match its filename" "the identity mismatch was not reported"
  rm -f "$reg/broken-filename.json"

  write_spec "$reg" broken-trigger '.trigger.id = "not-a-registered-trigger"'
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a spec naming an unregistered trigger was accepted"
  assert_contains "$OUT" "is not in the trigger register" "the unregistered trigger was not reported"
  rm -f "$reg/broken-trigger.json"

  # Only now is a pass meaningful.
  write_spec "$reg" good "$READY"
  ls_run "$reg" "$st" validate
  expect_code 0 "$CODE" "a sound spec was refused: $OUT"
  assert_contains "$OUT" "LOOPSPEC_VALIDATE ok specs=1" "a sound registry did not report ok"

  pass "the validator refuses malformed, unknown, mislabelled and unregistered specs before any pass counts"
}

# --- what is unimplemented, unavailable or above its authority cannot run ----

test_unimplemented_or_unavailable_cannot_be_enabled() {
  local reg st
  read -r reg st < <(new_case cannot-enable)

  write_spec "$reg" on-unready-trigger '.status = "enabled" | .trigger.id = "fixture-unready" | .authority.permitted_skills = ["stow"]'
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "an enabled spec on an unimplemented trigger was accepted"
  assert_contains "$OUT" "has no implemented execution path" \
    "an unimplemented execution path did not block enabling"
  assert_contains "$OUT" "is not verified" "an unverified trigger did not block enabling"
  rm -f "$reg/on-unready-trigger.json"

  write_spec "$reg" missing-skill '.status = "enabled" | .trigger.id = "fixture-ready" | .authority.permitted_skills = ["a-skill-that-is-not-installed"]'
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "an enabled spec naming an uninstalled skill was accepted"
  assert_contains "$OUT" "is not installed" "the uninstalled skill did not block enabling"
  rm -f "$reg/missing-skill.json"

  write_spec "$reg" self-promoting ".status = \"enabled\" | .trigger.id = \"fixture-ready\" | .authority.permitted_skills = [\"stow\"] | .authority.class = \"captain-required\""
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a captain-required spec enabled itself"
  assert_contains "$OUT" "cannot self-enable" "captain-required authority did not block self-enabling"
  rm -f "$reg/self-promoting.json"

  pass "an unimplemented trigger, an uninstalled skill and captain-required authority each refuse to become enabled"
}

# --- one event selects exactly one spec, and nothing else runs ---------------

test_one_event_selects_exactly_one_spec() {
  local reg st lines
  read -r reg st < <(new_case select-one)

  write_spec "$reg" winner "$READY | .selection.priority = 10 | .selection.scope = \"alpha\""
  write_spec "$reg" runner-up "$READY | .selection.priority = 20 | .selection.scope = \"alpha\""
  write_spec "$reg" switched-off ".status = \"disabled\" | .trigger.id = \"fixture-ready\" | .selection.priority = 1 | .selection.scope = \"alpha\""

  ls_run "$reg" "$st" validate
  expect_code 0 "$CODE" "the multi-spec fixture registry did not validate: $OUT"

  ls_run "$reg" "$st" select --trigger fixture-ready --scope alpha
  expect_code 0 "$CODE" "selection refused an unambiguous registry: $OUT"
  assert_contains "$OUT" "LOOPSPEC_SELECT winner" "the lowest-priority enabled spec did not win"
  assert_not_contains "$OUT" "runner-up" "selection returned more than the winner"
  assert_not_contains "$OUT" "switched-off" "a disabled spec was selectable despite the best priority"
  lines=$(printf '%s\n' "$OUT" | grep -c "LOOPSPEC_SELECT")
  [ "$lines" -eq 1 ] || fail "expected exactly one selection line, got $lines"

  pass "one event selects exactly one eligible spec by the deterministic key, and a disabled spec cannot win"
}

test_no_match_produces_no_execution() {
  local reg st
  read -r reg st < <(new_case no-match)
  write_spec "$reg" only-spec "$READY"

  ls_run "$reg" "$st" select --trigger fixture-unready
  expect_code 1 "$CODE" "an event with no matching spec was not refused"
  assert_contains "$OUT" "refuse_no_match" "a missing match did not refuse"

  ls_run "$reg" "$st" select --trigger definitely-not-a-trigger
  expect_code 1 "$CODE" "an unregistered trigger was not refused"
  assert_contains "$OUT" "refuse_no_match" "an unregistered trigger did not refuse"

  [ -z "$(ls -A "$st")" ] || fail "a refused selection still wrote state"

  pass "no match refuses and writes nothing, and an unknown trigger never reads as no work to do"
}

test_unresolved_tie_fails_closed() {
  local reg st
  read -r reg st < <(new_case tie)

  # Same key in every component: the registry itself is ambiguous.
  write_spec "$reg" twin-a "$READY | .selection.priority = 5 | .selection.scope = \"same\""
  write_spec "$reg" twin-b "$READY | .selection.priority = 5 | .selection.scope = \"same\""
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a registry with a duplicated selection key validated"
  assert_contains "$OUT" "ambiguous selection key" "the duplicated selection key was not reported"
  rm -f "$reg/twin-a.json" "$reg/twin-b.json"

  # Distinct scopes keep the registry legal, so the tie can only surface at
  # selection time - and it must still refuse rather than pick one.
  write_spec "$reg" scoped-a "$READY | .selection.priority = 5 | .selection.scope = \"alpha\""
  write_spec "$reg" scoped-b "$READY | .selection.priority = 5 | .selection.scope = \"beta\""
  ls_run "$reg" "$st" validate
  expect_code 0 "$CODE" "a legal two-scope registry was refused: $OUT"

  ls_run "$reg" "$st" select --trigger fixture-ready
  expect_code 1 "$CODE" "a runtime tie was resolved instead of refused"
  assert_contains "$OUT" "refuse_ambiguous_tie" "a runtime tie did not fail closed"

  # Naming the scope removes the ambiguity rather than guessing at it.
  ls_run "$reg" "$st" select --trigger fixture-ready --scope beta
  expect_code 0 "$CODE" "a disambiguated selection was still refused: $OUT"
  assert_contains "$OUT" "LOOPSPEC_SELECT scoped-b" "disambiguation selected the wrong spec"

  pass "an ambiguous registry is refused, and a runtime tie refuses instead of choosing"
}

test_disabled_and_specified_only_cannot_run() {
  local reg st status
  for status in specified draft ready_not_active disabled retired; do
    read -r reg st < <(new_case "status-$status")
    write_spec "$reg" candidate ".status = \"$status\" | .trigger.id = \"fixture-ready\""
    ls_run "$reg" "$st" validate
    expect_code 0 "$CODE" "a $status spec did not validate: $OUT"
    ls_run "$reg" "$st" select --trigger fixture-ready
    expect_code 1 "$CODE" "a $status spec was selectable"
    assert_contains "$OUT" "refuse_not_enabled" "a $status spec did not refuse with refuse_not_enabled"
  done
  pass "specified, draft, ready_not_active, disabled and retired specs all validate yet none can be selected"
}

# --- iteration state: versions, duplicates, crashes, bounds -----------------

test_claiming_cannot_bypass_the_eligibility_gate() {
  local reg st status
  read -r reg st < <(new_case claim-gate)

  # Naming a spec directly must not be a way around selection's checks.
  for status in specified draft ready_not_active disabled retired; do
    write_spec "$reg" gated ".status = \"$status\" | .trigger.id = \"fixture-ready\""
    ls_run "$reg" "$st" claim gated --event-key bypass --spec-version 1 --headroom 90
    expect_code 1 "$CODE" "a $status spec started an iteration when claimed directly"
    assert_contains "$OUT" "refuse_not_enabled" "a $status spec did not refuse to start an iteration"
    assert_absent "$st/loopspec/gated.state.json" "a refused $status claim still wrote loop state"
    rm -f "$reg/gated.json"
  done

  write_spec "$reg" on-unready "$READY | .trigger.id = \"fixture-unready\" | .status = \"enabled\""
  ls_run "$reg" "$st" claim on-unready --event-key bypass --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "an iteration started on an unimplemented trigger"
  assert_contains "$OUT" "refuse_" "an unimplemented trigger did not refuse a direct claim"
  rm -f "$reg/on-unready.json"

  # An in-flight iteration must still be closable after its spec is disabled,
  # so turning a loop off never strands work that already started.
  write_spec "$reg" live "$READY"
  ls_run "$reg" "$st" claim live --event-key inflight --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "a runnable spec was refused: $OUT"
  jq '.status = "disabled"' "$reg/live.json" >"$reg/live.tmp" && mv "$reg/live.tmp" "$reg/live.json"
  ls_run "$reg" "$st" claim live --event-key another --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "a disabled spec started a new iteration"
  assert_contains "$OUT" "refuse_not_enabled" "disabling did not stop the next iteration"
  ls_run "$reg" "$st" finish live --event-key inflight --terminal no_delta --verifier-result pass
  expect_code 0 "$CODE" "disabling a loop stranded the iteration already in flight: $OUT"

  pass "an iteration can start only through the eligibility gate, while in-flight work can still be closed out"
}

test_shipped_instance_cannot_be_claimed_directly() {
  local st
  st="$TMP_ROOT/shipped-claim-state"
  mkdir -p "$st"
  ls_run "$ROOT/loopspecs" "$st" claim approved-work-reconciliation \
    --event-key direct --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "the ready_not_active shipped instance started an iteration"
  assert_contains "$OUT" "refuse_not_enabled" "the shipped instance did not refuse a direct claim"
  assert_absent "$st/loopspec" "a refused claim on the shipped instance still wrote loop state"
  pass "the shipped instance is inert to a direct claim, not only to selection"
}

test_version_change_cannot_alter_a_running_iteration() {
  local reg st
  read -r reg st < <(new_case version-change)
  write_spec "$reg" loop "$READY"

  ls_run "$reg" "$st" claim loop --event-key evt-1 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "the first claim was refused: $OUT"
  assert_contains "$OUT" "iteration=1" "the first claim did not open iteration 1"

  # The spec is edited underneath the open iteration.
  jq '.spec_version = 2' "$reg/loop.json" >"$reg/loop.json.new" && mv "$reg/loop.json.new" "$reg/loop.json"

  ls_run "$reg" "$st" claim loop --event-key evt-1 --spec-version 2 --headroom 90
  expect_code 1 "$CODE" "an iteration resumed across a version change"
  assert_contains "$OUT" "refuse_version_changed" "a changed spec version did not refuse"

  # A caller still holding the old version is refused just as firmly.
  ls_run "$reg" "$st" claim loop --event-key evt-1 --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "a stale requested version was accepted"
  assert_contains "$OUT" "refuse_version_changed" "a stale requested version did not refuse"

  ls_run "$reg" "$st" state loop
  expect_code 0 "$CODE" "state could not be read after a refused version change: $OUT"
  assert_contains "$OUT" '"spec_version": 1' "the persisted iteration lost its original version"

  pass "a spec version change refuses rather than silently altering the iteration already running"
}

test_duplicate_wakes_do_not_duplicate_side_effects() {
  local reg st
  read -r reg st < <(new_case duplicate-wakes)
  write_spec "$reg" loop "$READY"

  ls_run "$reg" "$st" claim loop --event-key sha-aaa --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "the first wake was refused: $OUT"
  ls_run "$reg" "$st" finish loop --event-key sha-aaa --terminal no_delta --verifier-result pass
  expect_code 0 "$CODE" "finishing the first iteration was refused: $OUT"

  ls_run "$reg" "$st" claim loop --event-key sha-aaa --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "a duplicate wake opened a second iteration"
  assert_contains "$OUT" "refuse_duplicate_event" "a duplicate wake did not refuse"

  ls_run "$reg" "$st" state loop
  assert_contains "$OUT" '"iteration": 1' "a duplicate wake advanced the iteration counter"
  assert_contains "$OUT" '"last_terminal": "no_delta"' "the recorded terminal changed under a duplicate wake"

  # A genuinely new event still proceeds, so dedupe has not wedged the loop.
  ls_run "$reg" "$st" claim loop --event-key sha-bbb --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "a new event key was refused after a duplicate: $OUT"
  assert_contains "$OUT" "iteration=2" "a new event key did not advance the iteration"

  pass "a repeated wake refuses and mutates nothing, while a genuinely new event still advances"
}

test_crash_and_resume_preserve_version_and_state() {
  local reg st
  read -r reg st < <(new_case crash-resume)
  write_spec "$reg" loop "$READY"

  ls_run "$reg" "$st" claim loop --event-key sha-ccc --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "the claim before the crash was refused: $OUT"
  assert_contains "$OUT" "resumed=false" "the first claim reported itself as a resume"

  # The iteration is left open, exactly as an interrupted worker would leave it.
  ls_run "$reg" "$st" claim loop --event-key sha-ccc --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "resuming an interrupted iteration was refused: $OUT"
  assert_contains "$OUT" "resumed=true" "the interrupted iteration was not resumed"
  assert_contains "$OUT" "iteration=1" "resuming re-counted the iteration"
  assert_contains "$OUT" "version=1" "resuming lost the iteration's version"

  # A different event may not steal an open iteration.
  ls_run "$reg" "$st" claim loop --event-key sha-ddd --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "a second event key claimed an already-open iteration"
  assert_contains "$OUT" "refuse_iteration_open" "an open iteration was not protected"

  ls_run "$reg" "$st" state loop
  assert_contains "$OUT" '"iteration": 1' "the resumed iteration counter drifted"
  assert_contains "$OUT" '"open": true' "the resumed iteration lost its open state"

  pass "an interrupted iteration resumes at the same version and count, and no other event can steal it"
}

test_no_progress_reaches_its_named_terminal() {
  local reg st
  read -r reg st < <(new_case no-progress)
  write_spec "$reg" loop "$READY | .no_progress.max_iterations_without_progress = 2"

  ls_run "$reg" "$st" claim loop --event-key p1 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "claim p1 refused: $OUT"
  ls_run "$reg" "$st" finish loop --event-key p1 --terminal no_delta --verifier-result pass --progress none
  expect_code 0 "$CODE" "finish p1 refused: $OUT"

  ls_run "$reg" "$st" claim loop --event-key p2 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "claim p2 refused: $OUT"
  ls_run "$reg" "$st" finish loop --event-key p2 --terminal no_delta --verifier-result pass --progress none
  expect_code 0 "$CODE" "finish p2 refused: $OUT"

  ls_run "$reg" "$st" claim loop --event-key p3 --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "the loop kept iterating after repeated no-progress"
  assert_contains "$OUT" "refuse_no_progress" "no-progress did not refuse"

  ls_run "$reg" "$st" state loop
  assert_contains "$OUT" '"last_terminal": "no_progress_stalled"' \
    "no-progress refused without recording its named terminal state"
  assert_contains "$OUT" '"open": false' "the stalled loop was left open"

  pass "consecutive no-progress iterations stop the loop at its declared no_progress_stalled terminal"
}

test_progress_resets_the_no_progress_counter() {
  local reg st
  read -r reg st < <(new_case progress-resets)
  write_spec "$reg" loop "$READY | .no_progress.max_iterations_without_progress = 2"

  ls_run "$reg" "$st" claim loop --event-key q1 --spec-version 1 --headroom 90
  ls_run "$reg" "$st" finish loop --event-key q1 --terminal no_delta --verifier-result pass --progress none
  expect_code 0 "$CODE" "finish q1 refused: $OUT"
  ls_run "$reg" "$st" claim loop --event-key q2 --spec-version 1 --headroom 90
  ls_run "$reg" "$st" finish loop --event-key q2 --terminal no_delta --verifier-result pass --progress made
  expect_code 0 "$CODE" "finish q2 refused: $OUT"

  ls_run "$reg" "$st" claim loop --event-key q3 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "real progress did not clear the no-progress count: $OUT"

  pass "verifier-declared progress resets the no-progress count, so the bound tracks stalling and not age"
}

test_budget_exhaustion_stops_the_loop() {
  local reg st
  read -r reg st < <(new_case budget)
  write_spec "$reg" loop "$READY | .budgets.max_iterations = 1"

  ls_run "$reg" "$st" claim loop --event-key b1 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "the only budgeted iteration was refused: $OUT"
  ls_run "$reg" "$st" finish loop --event-key b1 --terminal no_delta --verifier-result pass
  expect_code 0 "$CODE" "finishing within budget was refused: $OUT"

  ls_run "$reg" "$st" claim loop --event-key b2 --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "the loop iterated past its declared budget"
  assert_contains "$OUT" "refuse_budget_exceeded" "an exceeded iteration budget did not refuse"

  pass "an iteration budget is a hard stop, not a suggestion"
}

test_capacity_stop_blocks_a_new_iteration_but_not_in_flight_work() {
  local reg st
  read -r reg st < <(new_case capacity)
  write_spec "$reg" loop "$READY | .budgets.capacity_stop_band_percent = 20"

  ls_run "$reg" "$st" claim loop --event-key c1 --spec-version 1
  expect_code 1 "$CODE" "unknown capacity was treated as available headroom"
  assert_contains "$OUT" "refuse_capacity_unknown" "missing capacity evidence did not refuse"

  ls_run "$reg" "$st" claim loop --event-key c1 --spec-version 1 --headroom 5
  expect_code 1 "$CODE" "an iteration started inside the capacity stop band"
  assert_contains "$OUT" "refuse_capacity_stop" "the capacity stop band did not refuse"

  # In-flight work stays verifiable while capacity is short.
  ls_run "$reg" "$st" claim loop --event-key c1 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "a claim with ample headroom was refused: $OUT"

  ls_run "$reg" "$st" validate
  expect_code 0 "$CODE" "validation was blocked by the capacity stop band: $OUT"
  ls_run "$reg" "$st" finish loop --event-key c1 --terminal no_delta --verifier-result pass
  expect_code 0 "$CODE" "in-flight work could not be completed under a capacity stop: $OUT"

  pass "the capacity stop band prevents starting a new iteration while in-flight work stays verifiable"
}

# --- verification can never be assumed --------------------------------------

test_an_unavailable_verifier_can_never_become_a_pass() {
  local reg st required
  read -r reg st < <(new_case verifier)
  write_spec "$reg" loop "$READY"
  required=$(jq -r '.verification.required_evidence | length' "$reg/loop.json")

  ls_run "$reg" "$st" claim loop --event-key v1 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "claim refused: $OUT"

  ls_run "$reg" "$st" finish loop --event-key v1 --terminal delta_emitted --verifier-result unavailable
  expect_code 1 "$CODE" "an unavailable verifier produced a success terminal"
  assert_contains "$OUT" "refuse_verifier_unavailable" "an unavailable verifier did not refuse"

  ls_run "$reg" "$st" finish loop --event-key v1 --terminal delta_emitted --verifier-result fail
  expect_code 1 "$CODE" "a rejecting verifier produced a success terminal"
  assert_contains "$OUT" "refuse_verification_mismatch" "a rejecting verifier did not refuse"

  ls_run "$reg" "$st" finish loop --event-key v1 --terminal delta_emitted --verifier-result pass
  expect_code 1 "$CODE" "a success terminal was reached with no evidence"
  assert_contains "$OUT" "refuse_evidence_missing" "missing evidence did not refuse"

  ls_run "$reg" "$st" finish loop --event-key v1 --terminal not_a_terminal --verifier-result pass
  expect_code 1 "$CODE" "an undeclared terminal was accepted"
  assert_contains "$OUT" "refuse_unknown_terminal" "an undeclared terminal did not refuse"

  # The only route out of an unavailable verifier is the failure terminal.
  ls_run "$reg" "$st" finish loop --event-key v1 --terminal verification_failed --verifier-result unavailable
  expect_code 0 "$CODE" "an unavailable verifier could not reach its failure terminal: $OUT"
  assert_contains "$OUT" "kind=failure" "verification_failed was not recorded as a failure"

  pass "an unavailable or rejecting verifier can only reach a failure terminal, never a pass"
}

test_a_success_terminal_requires_its_declared_evidence() {
  local reg st required i
  local -a args=()
  read -r reg st < <(new_case evidence)
  write_spec "$reg" loop "$READY"
  required=$(jq -r '.verification.required_evidence | length' "$reg/loop.json")

  ls_run "$reg" "$st" claim loop --event-key e1 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "claim refused: $OUT"

  # One short of the declared requirement must still refuse.
  args=()
  i=1
  while [ "$i" -lt "$required" ]; do
    args+=(--evidence "item-$i")
    i=$((i + 1))
  done
  ls_run "$reg" "$st" finish loop --event-key e1 --terminal delta_emitted --verifier-result pass "${args[@]}"
  expect_code 1 "$CODE" "a success terminal accepted fewer evidence items than declared"
  assert_contains "$OUT" "refuse_evidence_missing" "short evidence did not refuse"

  args+=(--evidence "item-$required")
  ls_run "$reg" "$st" finish loop --event-key e1 --terminal delta_emitted --verifier-result pass "${args[@]}"
  expect_code 0 "$CODE" "complete evidence was still refused: $OUT"
  assert_contains "$OUT" "terminal=delta_emitted" "the success terminal was not recorded"

  pass "a success terminal is reachable only with the full evidence the spec declares"
}

test_untruthful_state_refuses_rather_than_guessing() {
  local reg st
  read -r reg st < <(new_case bad-state)
  write_spec "$reg" loop "$READY"

  mkdir -p "$st/loopspec"
  printf 'this is not json\n' >"$st/loopspec/loop.state.json"

  ls_run "$reg" "$st" claim loop --event-key s1 --spec-version 1 --headroom 90
  expect_code 1 "$CODE" "an unreadable state file was treated as a fresh loop"
  assert_contains "$OUT" "refuse_state_unreadable" "unreadable state did not refuse"

  ls_run "$reg" "$st" state loop
  expect_code 1 "$CODE" "unreadable state was reported as readable"
  assert_contains "$OUT" "refuse_state_unreadable" "reading unreadable state did not refuse"

  pass "state that cannot be read truthfully refuses instead of restarting the loop from zero"
}

test_unwritable_state_refuses_rather_than_running_unrecorded() {
  local reg st
  read -r reg st < <(new_case unwritable-state)
  write_spec "$reg" loop "$READY"

  mkdir -p "$st/loopspec"
  chmod 0500 "$st/loopspec"
  # Root ignores the mode bits, so prove the directory is really unwritable
  # before trusting a refusal that would otherwise be vacuous.
  if touch "$st/loopspec/.probe" 2>/dev/null; then
    rm -f "$st/loopspec/.probe"
    chmod 0700 "$st/loopspec"
    printf 'skip: loop state directory is writable despite mode 0500 (running as root)\n'
    return 0
  fi

  ls_run "$reg" "$st" claim loop --event-key w1 --spec-version 1 --headroom 90
  chmod 0700 "$st/loopspec"
  expect_code 1 "$CODE" "an iteration started while its state could not be recorded"
  assert_contains "$OUT" "refuse_state_unwritable" "unwritable state did not refuse"

  pass "an iteration refuses to start when its state cannot be recorded truthfully"
}

test_finishing_without_an_open_iteration_refuses() {
  local reg st
  read -r reg st < <(new_case no-open)
  write_spec "$reg" loop "$READY"

  ls_run "$reg" "$st" finish loop --event-key ghost --terminal no_delta --verifier-result pass
  expect_code 1 "$CODE" "a terminal was recorded with no iteration open"
  assert_contains "$OUT" "refuse_no_open_iteration" "finishing nothing did not refuse"

  ls_run "$reg" "$st" claim loop --event-key real --spec-version 1 --headroom 90
  ls_run "$reg" "$st" finish loop --event-key other --terminal no_delta --verifier-result pass
  expect_code 1 "$CODE" "one event finished another event's iteration"
  assert_contains "$OUT" "refuse_no_open_iteration" "a mismatched event key did not refuse"

  pass "a terminal can only be recorded against the open iteration that owns the event"
}

# --- the shipped registry tells the truth about itself ----------------------

test_shipped_registry_is_valid_and_inert() {
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" validate
  expect_code 0 "$CODE" "the shipped registry does not validate: $OUT"

  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" list
  assert_contains "$OUT" "approved-work-reconciliation" "the shipped instance is missing"
  assert_contains "$OUT" "status=ready_not_active" "the shipped instance is not ready_not_active"

  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" select --trigger required-artifact-changes
  expect_code 1 "$CODE" "the shipped instance was selectable while not active"
  assert_contains "$OUT" "refuse_not_enabled" "the inert shipped instance did not refuse"

  assert_absent "$TMP_ROOT/shipped-state/loopspec" "reading the shipped registry created loop state"

  pass "the shipped instance validates, reports ready_not_active, and refuses to be selected"
}

test_shipped_instance_references_rather_than_duplicates_its_skill() {
  local skills procedure_fields gated

  skills=$(jq -r '.authority.permitted_skills | join(",")' "$SPEC_SOURCE")
  [ "$skills" = "research-approved-work" ] \
    || fail "the shipped instance should permit exactly research-approved-work, got: $skills"

  # Duplication is prevented structurally, not by good intentions: the contract
  # declares no field in which a procedure could be restated, so a spec can name
  # a skill but never carry a second copy of that skill's workflow.
  procedure_fields=$(jq -r '
    [.objects | to_entries[] | (.value.required // {}) + (.value.optional // {}) | keys[]]
    | map(select(test("^(steps?|procedures?|workflows?|instructions?|scripts?|commands?|prompts?)$")))
    | join(",")
  ' "$ROOT/loopspecs/schema.json")
  [ -z "$procedure_fields" ] \
    || fail "the schema gained a field a skill's workflow could be copied into: $procedure_fields"

  # The referenced skill is a declared precondition, so its absence is a stated
  # reason this loop cannot run rather than something discovered mid-iteration.
  gated=$(jq -r '[.preconditions[] | select(.description | test("research-approved-work"))] | length' "$SPEC_SOURCE")
  [ "$gated" -ge 1 ] \
    || fail "the shipped instance does not make the referenced skill a precondition"

  pass "the shipped instance names the research-approved-work skill, and the contract has nowhere to duplicate it"
}

# --- the unified terminal-state vocabulary ----------------------------------
#
# Two systems previously named the same terminal facts twice: a LoopSpec
# finalising on no_progress_stalled and the platform execution node finalising
# on iteration-cap-failed are one fact under two names. terminal-states.json
# now names each fact once and records where every source name lands.
#
# The execution-node side is pinned here as literal names rather than read from
# the platform, because that repository is not present in CI. These are the
# eight FINALIZE_MATRIX outcomes of scripts/runtime_execution_node.py at
# platform commit 5d86b7e; the pin is what makes a platform-side change to the
# vocabulary show up as a failing test here rather than as silent drift.
NODE_FINALIZE_OUTCOMES="context-ceiling budget-finish finish-signal timeout stop-signal iteration-cap-clean iteration-cap-failed unclassified"

# map_case <name> <jq-filter> - a registry whose terminal-state map is the real
# one put through <jq-filter>; echoes "<registry> <state>".
map_case() {
  local d="$TMP_ROOT/$1" filter=$2
  mkdir -p "$d/registry" "$d/state"
  cp "$ROOT/loopspecs/schema.json" "$d/registry/schema.json"
  cp "$ROOT/loopspecs/triggers.json" "$d/registry/triggers.json"
  cp "$ROOT/loopspecs/approved-work-reconciliation.json" "$d/registry/"
  jq "$filter" "$ROOT/loopspecs/terminal-states.json" >"$d/registry/terminal-states.json" \
    || fail "could not build terminal-state map fixture $1"
  printf '%s %s\n' "$d/registry" "$d/state"
}

test_an_unmapped_terminal_state_is_refused_not_defaulted() {
  local reg st
  read -r reg st < <(new_case unmapped-refused)
  write_spec "$reg" good "$READY"

  # The negative controls come first. A resolver that answers everything
  # confidently proves nothing by answering a real state correctly.
  ls_run "$reg" "$st" terminal-map --resolve loopspec not_a_terminal_state
  expect_code 1 "$CODE" "an unmapped loopspec state resolved instead of refusing"
  assert_contains "$OUT" "refuse_unmapped_terminal" "an unmapped state did not refuse"

  ls_run "$reg" "$st" terminal-map --resolve execution-node not-a-finalize-outcome
  expect_code 1 "$CODE" "an unmapped execution-node state resolved instead of refusing"
  assert_contains "$OUT" "refuse_unmapped_terminal" "an unmapped node outcome did not refuse"

  ls_run "$reg" "$st" terminal-map --resolve not-a-source no_delta
  expect_code 1 "$CODE" "an unknown source vocabulary resolved instead of refusing"
  assert_contains "$OUT" "refuse_unmapped_terminal" "an unknown source did not refuse"

  # A state one of the two sides does declare is still refused on the other,
  # so the two vocabularies cannot leak into each other through the resolver.
  ls_run "$reg" "$st" terminal-map --resolve loopspec timeout
  expect_code 1 "$CODE" "a node outcome resolved against the loopspec vocabulary"
  ls_run "$reg" "$st" terminal-map --resolve execution-node no_delta
  expect_code 1 "$CODE" "a loopspec state resolved against the node vocabulary"

  ls_run "$reg" "$st" terminal-map --resolve loopspec no_delta
  expect_code 0 "$CODE" "a mapped state refused: $OUT"
  assert_contains "$OUT" "LOOPSPEC_TERMINAL_MAP loopspec no_delta -> no_delta" \
    "the mapped state did not resolve to its unified state"

  # The map is a registry contract file, not a spec: it is never listed,
  # never shown and never counted, so it can never be selected or claimed.
  ls_run "$reg" "$st" list
  assert_not_contains "$OUT" "terminal-states" "the terminal-state map was listed as a spec"
  ls_run "$reg" "$st" show terminal-states
  expect_code 1 "$CODE" "the terminal-state map was shown as a spec"
  assert_contains "$OUT" "refuse_unknown_spec" "showing a contract file did not refuse"
  ls_run "$reg" "$st" validate
  expect_code 0 "$CODE" "the fixture registry did not validate: $OUT"
  assert_contains "$OUT" "specs=1" "the terminal-state map was counted as a spec"

  pass "an unmapped terminal state refuses on both sides rather than defaulting to a plausible unified state"
}

test_the_mapping_is_total_in_both_directions() {
  local reg st name unified declared rows
  read -r reg st < <(new_case mapping-total)
  write_spec "$reg" good "$READY"

  # Direction one: every terminal state the shipped spec declares resolves to
  # exactly one unified state.
  declared=$(jq -r '.terminal_states[].name' "$SPEC_SOURCE")
  [ -n "$declared" ] || fail "the shipped instance declares no terminal states"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    ls_run "$reg" "$st" terminal-map --resolve loopspec "$name"
    expect_code 0 "$CODE" "declared terminal state $name does not map: $OUT"
    unified=$(printf '%s\n' "$OUT" | awk '/LOOPSPEC_TERMINAL_MAP/ {print $5}')
    [ -n "$unified" ] || fail "terminal state $name resolved to nothing"
    [ "$(printf '%s\n' "$OUT" | grep -c 'LOOPSPEC_TERMINAL_MAP')" -eq 1 ] \
      || fail "terminal state $name resolved to more than one unified state"
  done <<<"$declared"

  # Direction two: every finalize outcome the platform declares resolves too.
  for name in $NODE_FINALIZE_OUTCOMES; do
    ls_run "$reg" "$st" terminal-map --resolve execution-node "$name"
    expect_code 0 "$CODE" "node outcome $name does not map: $OUT"
    [ "$(printf '%s\n' "$OUT" | grep -c 'LOOPSPEC_TERMINAL_MAP')" -eq 1 ] \
      || fail "node outcome $name resolved to more than one unified state"
  done

  # And the map carries no node row the platform does not actually have, so the
  # pin above cannot pass by being a subset of an invented vocabulary.
  rows=$(ls_run "$reg" "$st" terminal-map --source execution-node; printf '%s' "$OUT")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case " $NODE_FINALIZE_OUTCOMES " in
      *" $name "*) ;;
      *) fail "the map records node outcome $name, which the platform matrix does not declare" ;;
    esac
  done < <(printf '%s\n' "$rows" | awk -F'\t' 'NF > 1 {print $2}')

  pass "every terminal state in both vocabularies maps to exactly one unified state, and the map invents none"
}

test_the_merge_is_a_reduction_with_nothing_unreachable() {
  local reg st unified_count source_count reachable

  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" terminal-map --unified
  expect_code 0 "$CODE" "the unified vocabulary could not be read: $OUT"
  unified_count=$(printf '%s\n' "$OUT" | grep -c 'costs_model_turn=')
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" terminal-map
  expect_code 0 "$CODE" "the mapping rows could not be read: $OUT"
  source_count=$(printf '%s\n' "$OUT" | grep -c 'costs_model_turn=')

  [ "$unified_count" -lt "$source_count" ] \
    || fail "the merged vocabulary has $unified_count members against $source_count source states, so it is not a reduction"

  # No unified state may exist that nothing can reach, because an unreachable
  # state is a claim about behaviour that cannot happen.
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" terminal-map --unified
  reachable=$(printf '%s\n' "$OUT" | awk -F'sources=' 'NF > 1 && $2 + 0 == 0 {print}')
  [ -z "$reachable" ] || fail "unified states no source state reaches: $reachable"

  # The reduction claim is only meaningful if the validator can reject its
  # opposite, so watch it reject a map that is not one.
  # One unified state per source state: everything is still reachable and every
  # other invariant still holds, so only the reduction claim can fail here.
  read -r reg st < <(map_case not-a-reduction '
    .unified = ([ .sources[] | .map[] | (.state | gsub("-"; "_"))
                  | {name: ., kind: "failure", costs_model_turn: true, description: "one name per source state"} ]
                | map(if .name == "no_delta" then .kind = "neutral" | .costs_model_turn = false else . end))
    | .sources = (.sources | map(.map = (.map | map(.unified = (.state | gsub("-"; "_"))))))')
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a map that renames rather than reduces was accepted"
  assert_contains "$OUT" "so the merge is not a reduction" "the missing reduction was not named"

  read -r reg st < <(map_case unreachable-unified \
    '.unified += [{"name": "orphan_state", "kind": "failure", "costs_model_turn": true, "description": "nothing maps here"}]')
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "an unreachable unified state was accepted"
  assert_contains "$OUT" "is unreachable" "the unreachable unified state was not named"

  read -r reg st < <(map_case undeclared-target '.sources[0].map[0].unified = "invented_state"')
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a row mapping to an undeclared unified state was accepted"
  assert_contains "$OUT" "not a declared unified state" "the undeclared target was not named"

  pass "the merged vocabulary is strictly smaller than the sum, nothing is unreachable, and the validator rejects the opposite of each claim"
}

test_no_terminal_state_loses_its_distinction_in_the_merge() {
  local reg st collapsed

  # Where the merge does collapse two source names onto one unified state, the
  # map must say where the difference they used to carry still lives. This is
  # the certification clause made mechanical rather than left as prose.
  read -r reg st < <(map_case undeclared-collapse \
    'del(.sources[] | select(.source == "execution-node") | .map[] | select(.state == "timeout") | .distinction)')
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a collapse across differing consequences was accepted without a declared distinction"
  assert_contains "$OUT" "does not declare how the distinction is preserved" \
    "the undeclared collapse was not named"

  # Only now does the shipped map's silence mean something.
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" validate
  expect_code 0 "$CODE" "the shipped registry no longer validates: $OUT"

  # Every collapse in the shipped map is declared, and the states that carry
  # different consequences are not collapsed at all: the node's clean and
  # failed iteration caps land on different unified states.
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" terminal-map --resolve execution-node iteration-cap-clean
  expect_code 0 "$CODE" "iteration-cap-clean does not map: $OUT"
  collapsed=$(printf '%s\n' "$OUT" | awk '/LOOPSPEC_TERMINAL_MAP/ {print $5}')
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" terminal-map --resolve execution-node iteration-cap-failed
  expect_code 0 "$CODE" "iteration-cap-failed does not map: $OUT"
  [ "$collapsed" != "$(printf '%s\n' "$OUT" | awk '/LOOPSPEC_TERMINAL_MAP/ {print $5}')" ] \
    || fail "a clean and a failed iteration cap collapsed onto the same unified state"

  # The one fact this increment exists to name once: the node's failed
  # iteration cap and the loop's stall are the same terminal.
  assert_contains "$OUT" "-> no_progress_stalled" \
    "iteration-cap-failed no longer unifies with the loop's no_progress_stalled"

  pass "a collapse that would drop a distinction is refused, and the two vocabularies' matching facts unify onto one name"
}

test_no_delta_still_costs_no_model_turn() {
  local reg st free kind

  # The property, as the vocabulary declares it: exactly one unified state may
  # be reached without spending a model turn, and it is no_delta.
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" terminal-map --unified
  expect_code 0 "$CODE" "the unified vocabulary could not be read: $OUT"
  free=$(printf '%s\n' "$OUT" | awk -F'\t' '$3 == "costs_model_turn=false" {print $1}')
  [ "$free" = "no_delta" ] \
    || fail "the zero-model-turn state should be exactly no_delta, got: ${free:-none}"
  kind=$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "no_delta" {print $2}')
  [ "$kind" = "neutral" ] \
    || fail "no_delta must stay neutral so reaching it can never demand a verifier verdict, got: $kind"

  # Dropping or moving the property is refused, so its presence is a fact the
  # validator holds rather than a comment someone remembered to keep.
  read -r reg st < <(map_case zero-turn-dropped \
    '(.unified[] | select(.name == "no_delta")).costs_model_turn = true')
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a vocabulary with no zero-model-turn state was accepted"

  read -r reg st < <(map_case zero-turn-moved \
    '(.unified[] | select(.name == "no_delta")).costs_model_turn = true
     | (.unified[] | select(.name == "cancelled")).costs_model_turn = false')
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "the zero-model-turn property was allowed to move off no_delta"
  assert_contains "$OUT" "must be no_delta" "the moved property was not named"

  read -r reg st < <(map_case zero-turn-not-neutral \
    '(.unified[] | select(.name == "no_delta")).kind = "failure"')
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "no_delta was allowed to stop being neutral"

  # And the property behaviourally: reaching no_delta demands no verifier
  # verdict and no evidence, which is what "costs no model turn" means in
  # practice. The negative control is the same call against a success terminal.
  read -r reg st < <(new_case zero-turn-behaviour)
  write_spec "$reg" loop "$READY"
  ls_run "$reg" "$st" claim loop --event-key sha-1 --spec-version 1 --headroom 90
  expect_code 0 "$CODE" "the iteration could not be claimed: $OUT"
  ls_run "$reg" "$st" finish loop --event-key sha-1 --terminal delta_emitted --verifier-result unavailable
  expect_code 1 "$CODE" "a success terminal was reachable without a verifier verdict"
  ls_run "$reg" "$st" finish loop --event-key sha-1 --terminal no_delta --verifier-result unavailable
  expect_code 0 "$CODE" "no_delta demanded a verifier verdict it must never need: $OUT"
  assert_contains "$OUT" "terminal=no_delta kind=neutral" "no_delta was not recorded as the neutral terminal"

  pass "no_delta survives the merge as the one terminal reachable without spending a model turn"
}

test_a_spec_terminal_cannot_drift_from_the_map() {
  local reg st

  read -r reg st < <(new_case terminal-drift)

  write_spec "$reg" no-mapping "$READY | del(.terminal_states[0].maps_to)"
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a terminal state with no unified mapping was accepted"
  assert_contains "$OUT" "missing required field: terminal_states[].maps_to" \
    "the missing mapping was not named"
  rm -f "$reg/no-mapping.json"

  write_spec "$reg" invented-mapping "$READY | .terminal_states[0].maps_to = \"PROBABLY_FINE\""
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a terminal state mapping outside the unified vocabulary was accepted"
  rm -f "$reg/invented-mapping.json"

  write_spec "$reg" wrong-mapping "$READY | .terminal_states[0].maps_to = \"cancelled\""
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a terminal state disagreeing with the map was accepted"
  assert_contains "$OUT" "but terminal-states.json maps it to" "the disagreement was not named"
  rm -f "$reg/wrong-mapping.json"

  write_spec "$reg" unmapped-name \
    "$READY | .terminal_states[0].name = \"invented_terminal\" | .no_progress.terminal = \"no_progress_stalled\""
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a terminal state absent from the map was accepted"
  assert_contains "$OUT" "has no loopspec row in terminal-states.json" \
    "the unmapped terminal state was not named"
  rm -f "$reg/unmapped-name.json"

  write_spec "$reg" wrong-kind "$READY | .terminal_states[1].kind = \"failure\""
  ls_run "$reg" "$st" validate
  expect_code 1 "$CODE" "a terminal state contradicting its unified kind was accepted"
  assert_contains "$OUT" "declares kind" "the kind disagreement was not named"
  rm -f "$reg/wrong-kind.json"

  write_spec "$reg" good "$READY"
  ls_run "$reg" "$st" validate
  expect_code 0 "$CODE" "a correctly mapped spec was refused: $OUT"

  pass "a spec terminal state that is unmapped, invented, disagreeing or miskinded is refused rather than defaulted"
}

test_trigger_register_reports_one_of_sixteen() {
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" triggers --summary
  expect_code 0 "$CODE" "the trigger summary failed: $OUT"
  assert_contains "$OUT" "LOOPSPEC_TRIGGERS total=16" "the register does not hold exactly sixteen triggers"
  assert_contains "$OUT" "specified=16" "not every trigger is specified"
  assert_contains "$OUT" "detector_implemented=1" "the register no longer reports exactly one implemented detector"
  assert_contains "$OUT" "execution_path_implemented=0" "a trigger claims an implemented execution path"
  assert_contains "$OUT" "verified=0" "a trigger claims to be verified"
  assert_contains "$OUT" "enabled=0" "a trigger claims to be enabled"
  assert_contains "$OUT" "outside_the_sixteen=1" "the PR-merged detector is no longer held outside the sixteen"

  # The one implemented detector is the merge-conflict poll, and nothing else.
  ls_run "$ROOT/loopspecs" "$TMP_ROOT/shipped-state" triggers
  assert_contains "$OUT" "merge-conflict-appears	detector=implemented" \
    "merge-conflict-appears is no longer the implemented detector"
  [ "$(printf '%s\n' "$OUT" | grep -c "detector=implemented")" -eq 1 ] \
    || fail "more than one trigger reports an implemented detector"

  pass "the register reports one implemented detector of sixteen, none verified, none enabled"
}

test_validator_is_not_vacuous
test_unimplemented_or_unavailable_cannot_be_enabled
test_one_event_selects_exactly_one_spec
test_no_match_produces_no_execution
test_unresolved_tie_fails_closed
test_disabled_and_specified_only_cannot_run
test_claiming_cannot_bypass_the_eligibility_gate
test_shipped_instance_cannot_be_claimed_directly
test_version_change_cannot_alter_a_running_iteration
test_duplicate_wakes_do_not_duplicate_side_effects
test_crash_and_resume_preserve_version_and_state
test_no_progress_reaches_its_named_terminal
test_progress_resets_the_no_progress_counter
test_budget_exhaustion_stops_the_loop
test_capacity_stop_blocks_a_new_iteration_but_not_in_flight_work
test_an_unavailable_verifier_can_never_become_a_pass
test_a_success_terminal_requires_its_declared_evidence
test_untruthful_state_refuses_rather_than_guessing
test_unwritable_state_refuses_rather_than_running_unrecorded
test_finishing_without_an_open_iteration_refuses
test_shipped_registry_is_valid_and_inert
test_shipped_instance_references_rather_than_duplicates_its_skill
test_an_unmapped_terminal_state_is_refused_not_defaulted
test_the_mapping_is_total_in_both_directions
test_the_merge_is_a_reduction_with_nothing_unreachable
test_no_terminal_state_loses_its_distinction_in_the_merge
test_no_delta_still_costs_no_model_turn
test_a_spec_terminal_cannot_drift_from_the_map
test_trigger_register_reports_one_of_sixteen
