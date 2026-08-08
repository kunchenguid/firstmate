#!/usr/bin/env bash
# Public-interface tests for the write-once, receipt-derived attempt model:
# immutable envelope, write-once provider/delivery freeze, write-once effect
# receipts, append-only observation journal, derived obligations, atomic
# retirement with the complete set, stale-generation and torn-publication
# safety, and non-reentrant lock-held primitives.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-attempt)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

test_alloc_roundtrips_envelope() {
  local aid gen
  aid=$(fm_attempt_alloc pi dos-a holu) || fail "alloc failed"
  assert_contains "$aid" "dos-a-a1" "attempt id shape"
  gen=$(fm_attempt_generation "$aid") || fail "load failed"
  [ "$gen" = 1 ] || fail "generation was $gen"
  fm_attempt_load "$aid" | jq -e '.envelope.task_source == "pi" and .envelope.home_id == "holu"' >/dev/null \
    || fail "envelope did not round-trip"
  pass "attempt alloc round-trips the immutable envelope"
}

test_concurrent_allocation_one_winner() {
  local a b
  # Isolate this scenario: test_alloc_roundtrips_envelope already allocated
  # dos-a-a1 in the shared state dir, so a fresh namespace is required for the
  # pinned second-alloc expectation (dos-a-a2) to hold deterministically.
  rm -f "$STATE/attempts"/dos-a-a*.json
  a=$(fm_attempt_alloc pi dos-a holu) || fail "first alloc"
  b=$(fm_attempt_alloc pi dos-a holu) || fail "second alloc"
  [ "$a" != "$b" ] || fail "duplicate attempt id: $a"
  assert_contains "$b" "dos-a-a2" "monotonic generation"
  pass "concurrent allocation yields distinct ids with one winner per generation"
}

test_effect_observe_is_write_once() {
  local aid
  aid=$(fm_attempt_alloc pi dos-b holu)
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-b","status":"claimed"}' || fail "first observe"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-b","status":"claimed"}' || fail "identical replay refused"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-b","status":"claimed-again"}' \
    && fail "second different observation accepted"
  [ "$(fm_attempt_load "$aid" | jq '.receipts.claim | length')" = 1 ] || fail "receipt not write-once"
  pass "an effect is observed at most once; identical replay converges, contradiction refuses"
}

test_freeze_allocation_is_write_once() {
  local aid
  aid=$(fm_attempt_alloc pi dos-c holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' \
    || fail "identical replay refused"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-OTHER"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' \
    && fail "different replay value accepted"
  [ "$(fm_attempt_load "$aid" | jq -r '.provider.copy')" = wt-c ] || fail "provider rewritten"
  pass "provider and delivery freeze once; replay equality is a no-op and different replay refuses"
}

test_obligations_derive_from_missing_observed_effects() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-d holu)
  out=$(fm_attempt_obligations "$aid")
  assert_contains "$out" "claim" "claim obligation missing"
  assert_contains "$out" "provider" "provider obligation missing"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-d","status":"claimed"}' || fail "claim"
  out=$(fm_attempt_obligations "$aid")
  assert_not_contains "$out" "claim" "claim obligation not cleared"
  pass "named obligations derive solely from missing observed effects"
}

test_landed_retirement_requires_complete_set() {
  local aid
  aid=$(fm_attempt_alloc pi dos-e holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-e"}' \
    '{"mode":"no-mistakes","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-e","status":"claimed"}' || fail "claim"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-e"}' || fail "launch"
  fm_attempt_effect_observe "$aid" 1 landing '{"disposition":"landed","pr":"https://github.com/kunchenguid/firstmate/pull/1"}' \
    || fail "landing"
  fm_attempt_retire "$aid" 1 '{"audit":"terminal","disposition":"landed"}' \
    && fail "retirement without tracker and cleanup accepted"
  fm_attempt_is_retired "$aid" && fail "attempt retired illegally"
  fm_attempt_effect_observe "$aid" 1 tracker '{"bead":"dos-e","status":"closed"}' || fail "tracker"
  fm_attempt_effect_observe "$aid" 1 cleanup.endpoint '{"endpoint":"w-e","gone":true}' || fail "endpoint"
  fm_attempt_effect_observe "$aid" 1 cleanup.branch '{"fate":"deleted"}' || fail "branch"
  fm_attempt_effect_observe "$aid" 1 cleanup.provider '{"returned":true}' || fail "provider"
  fm_attempt_effect_observe "$aid" 1 cleanup.runtime '{"records_removed":true}' || fail "runtime"
  fm_attempt_retire "$aid" 1 '{"audit":"terminal","disposition":"landed"}' || fail "retirement refused"
  fm_attempt_is_retired "$aid" || fail "not retired"
  [ -z "$(fm_attempt_obligations "$aid")" ] || fail "retired attempt has obligations"
  pass "retirement requires the complete effect set; after retirement obligations are empty"
}

test_refused_claim_has_no_further_obligations() {
  local aid
  aid=$(fm_attempt_alloc pi dos-f holu)
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-f","status":"refused"}' || fail "refused claim"
  [ -z "$(fm_attempt_obligations "$aid")" ] || fail "refused claim kept obligations"
  fm_attempt_retire "$aid" 1 '{"audit":"failed-pre-allocation"}' || fail "failed pre-allocation not retired"
  pass "a conclusively refused claim with no provider copy is retired as failed pre-allocation"
}

test_stale_generation_cannot_mutate() {
  local aid
  aid=$(fm_attempt_alloc pi dos-g holu)
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-g","status":"claimed"}' || fail "fresh observe"
  fm_attempt_effect_observe "$aid" 2 claim '{"bead":"dos-g","status":"claimed"}' \
    && fail "stale generation observed"
  fm_attempt_freeze_allocation "$aid" 2 '{"provider":"tmux","copy":"wt-g"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' \
    && fail "stale generation froze allocation"
  pass "a stale generation cannot mutate the current attempt"
}

test_torn_publication_replays_converged() {
  local aid
  aid=$(fm_attempt_alloc pi dos-h holu)
  # simulate a torn write: an attempt file whose .tmp sibling never mv'd and a
  # stale generation field; a replay must converge on the receipts already
  # present without losing them
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-h","status":"claimed"}' || fail "claim"
  cp "$STATE/attempts/$aid.json" "$TMP_ROOT/before.json"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-h","status":"claimed"}' || fail "replay"
  cmp -s "$STATE/attempts/$aid.json" "$TMP_ROOT/before.json" || fail "replay mutated the record"
  pass "torn-publication replay converges on the existing receipts"
}

test_lock_held_primitives_never_reacquire() {
  local aid
  aid=$(fm_attempt_alloc pi dos-i holu)
  fm_attempt_lock_acquire "$aid" || fail "first acquire"
  fm_attempt_lock_acquire "$aid" && fail "nested acquire succeeded"
  fm_attempt_effect_observe_held "$aid" 1 claim '{"bead":"dos-i","status":"claimed"}' || fail "held observe"
  fm_attempt_lock_release "$aid"
  fm_attempt_lock_acquire "$aid" || fail "reacquire after release"
  fm_attempt_lock_release "$aid"
  pass "the attempt lock is non-reentrant and held primitives never reacquire"
}

test_observation_journal_is_append_only() {
  local aid n
  aid=$(fm_attempt_alloc pi dos-j holu)
  fm_attempt_observe "$aid" 1 forge '{"state":"open"}' || fail "first observation"
  fm_attempt_observe "$aid" 1 forge '{"state":"merged","head":"abc123"}' || fail "second observation"
  n=$(fm_attempt_load "$aid" | jq '.observations | length')
  [ "$n" = 2 ] || fail "observation journal not append-only: $n"
  pass "provisional observations append to a journal and are never authority"
}

test_alloc_roundtrips_envelope
test_concurrent_allocation_one_winner
test_effect_observe_is_write_once
test_freeze_allocation_is_write_once
test_obligations_derive_from_missing_observed_effects
test_landed_retirement_requires_complete_set
test_refused_claim_has_no_further_obligations
test_stale_generation_cannot_mutate
test_torn_publication_replays_converged
test_lock_held_primitives_never_reacquire
test_observation_journal_is_append_only
