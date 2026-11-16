#!/usr/bin/env bash
# tests/fm-outcome-batch.test.sh - routine captain outcomes from the
# supervision session are held so they reach main together, and blockers,
# failures, sign-in needs, review-ready work, and anything unproven are never
# delayed (bin/fm-outcome-batch-lib.sh).
#
# Drives fm_outcome_batch_verdict and fm_outcome_batch_due over real outcome
# store and status files. The host's own hand-up stays covered by
# tests/fm-supervision-host.test.sh with the setting absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-outcome-batch)

new_case() {  # <name>
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/config" "$CASE/state"
  : >"$CASE/config/outcome-batch"
  : >"$CASE/state/branch-outcomes.jsonl"
}

outcome() {  # <seq> <task> <summary> [epoch] [wake]
  jq -cn --argjson s "$1" --arg t "$2" --arg m "$3" --argjson e "${4:-$(date +%s)}" --arg w "${5:-signal: $2.status}" \
    '{seq: $s, epoch: $e, task: $t, wake: $w, verdict: "captain", summary: $m}' >>"$CASE/state/branch-outcomes.jsonl"
}

status() { printf '%s\n' "$2" >>"$CASE/state/$1.status"; }

verdict() { bash -c '. "$1/bin/fm-outcome-batch-lib.sh"; shift; fm_outcome_batch_verdict "$@"' _ "$ROOT" "$CASE/config" "$CASE/state" "$@"; }
due() { bash -c '. "$1/bin/fm-outcome-batch-lib.sh"; fm_outcome_batch_due "$2" "$3"' _ "$ROOT" "$CASE/config" "$CASE/state"; }

test_off_and_routine_hold() {
  new_case off
  rm -f "$CASE/config/outcome-batch"
  status t1 'working [at=1]: setup complete'
  outcome 1 t1 'setup finished; continuing with the tests'
  assert_equals now "$(verdict 1)" "without the setting every captain outcome goes now"
  new_case routine
  status t1 'working [at=1]: setup complete'
  outcome 1 t1 'setup finished; continuing with the tests'
  assert_equals hold "$(verdict 1)" "a positively routine outcome is held"
  [ -f "$CASE/state/.outcome-batch" ] || fail "a hold must leave its record"
  pass "off sends now; a positively routine outcome is held with a record"
}

test_never_delayed() {
  local summary verb n=0
  while IFS= read -r summary; do
    n=$((n + 1))
    new_case "urgent-$n"
    status t1 'working [at=1]: on it'
    outcome 1 t1 "$summary"
    assert_equals now "$(verdict 1)" "never delayed: '$summary'"
  done <<'ROWS'
the worker is blocked on a missing package
the test run failed twice
a build error stops progress
the worker needs a Google sign-in link approved
the AWS credential expired
review is ready at https://github.com/example/repo/pull/12
the PR is green and waits for a merge
a design decision is needed between two options
the change deletes the old table
a security finding came back
prod alerts fired after the deploy
ROWS
  for verb in blocked failed needs-decision done; do
    new_case "verb-$verb"
    status t1 "$verb [at=2]: see the report"
    outcome 1 t1 'progress note for the captain'
    assert_equals now "$(verdict 1)" "a task whose newest status is $verb is never delayed"
  done
  new_case no-status
  outcome 1 t9 'progress note for the captain'
  assert_equals now "$(verdict 1)" "an outcome whose task status cannot be read is never delayed"
  new_case mixed
  status t1 'working [at=1]: on it'
  status t2 'working [at=1]: on it'
  outcome 1 t1 'progress note'
  outcome 2 t2 'the worker is blocked'
  : >"$CASE/state/.outcome-batch"
  assert_equals now "$(verdict 1 2)" "one urgent outcome sends the whole turn now"
  [ ! -e "$CASE/state/.outcome-batch" ] || fail "an urgent turn must clear the hold record"
  new_case unreadable
  printf 'not json\n' >"$CASE/state/branch-outcomes.jsonl"
  assert_equals now "$(verdict 1)" "an unreadable store sends now"
  pass "blockers, failures, sign-ins, credentials, reviews, merges, decisions, deletions, security, prod, unknown status, and unreadable stores are never delayed"
}

test_window_and_release() {
  new_case window
  printf 'window-seconds=120\n' >"$CASE/config/outcome-batch"
  status t1 'working [at=1]: on it'
  outcome 1 t1 'progress note' "$(($(date +%s) - 60))"
  assert_equals hold "$(verdict 1)" "a routine outcome inside the window is held"
  if due; then fail "held outcomes inside the window are not due"; fi
  outcome 2 t1 'another progress note' "$(date +%s)"
  assert_equals hold "$(verdict 2)" "a second routine outcome joins the batch"
  new_case expired
  printf 'window-seconds=120\n' >"$CASE/config/outcome-batch"
  status t1 'working [at=1]: on it'
  outcome 1 t1 'progress note' "$(($(date +%s) - 200))"
  printf 'first=1\n' >"$CASE/state/.outcome-batch"
  due || fail "held outcomes past the window are due"
  outcome 2 t1 'another progress note'
  assert_equals now "$(verdict 2)" "a routine outcome after the window releases the batch"
  new_case processed
  status t1 'working [at=1]: on it'
  outcome 1 t1 'progress note' 1
  printf '1\n' >"$CASE/state/.branch-outcomes-processed"
  printf 'first=1\n' >"$CASE/state/.outcome-batch"
  if due; then fail "outcomes main already processed are never released again"; fi
  [ ! -e "$CASE/state/.outcome-batch" ] || fail "a processed batch clears its record"
  pass "held outcomes wait at most the window, join one batch, and are released once"
}

test_scale() {
  local n i start ms
  for n in 5 100 1000; do
    new_case "scale-$n"
    for i in $(seq 1 "$n"); do
      printf '{"seq":%s,"epoch":%s,"task":"t%s","wake":"signal: t%s.status","verdict":"captain","summary":"progress note"}\n' "$i" "$(date +%s)" "$i" "$i"
      printf 'working [at=1]: on it\n' >"$CASE/state/t$i.status"
    done >"$CASE/state/branch-outcomes.jsonl"
    printf '%s\n' $((n - 1)) >"$CASE/state/.branch-outcomes-processed"
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    assert_equals hold "$(verdict "$n")" "$n-row store: a routine outcome is held"
    ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start ))
    printf '# scale: %s outcome rows -> verdict in %s ms, store %s bytes\n' "$n" "$ms" "$(wc -c <"$CASE/state/branch-outcomes.jsonl" | tr -d ' ')"
  done
  pass "the verdict is the same at 5, 100 and 1000 stored outcomes (timings above)"
}

test_off_and_routine_hold
test_never_delayed
test_window_and_release
test_scale
