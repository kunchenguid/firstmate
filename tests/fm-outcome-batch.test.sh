#!/usr/bin/env bash
# tests/fm-outcome-batch.test.sh - routine captain outcomes from the
# supervision session are held so they reach main together, and blockers,
# failures, sign-in needs, review-ready work, questions, and anything the
# records cannot prove routine are never delayed (bin/fm-outcome-batch-lib.sh).
#
# Drives fm_outcome_batch_verdict and fm_outcome_batch_due over the real outcome
# store, read through bin/fm-branch-outcome.sh, and real status logs folded by
# bin/fm-classify-lib.sh. Rows are written in the store's own line format so a
# case can date them; the reader validates every one. A captain row is written
# marked batchable, as the supervision engine marks a finished result that asks
# nothing, unless a case says otherwise. The host's park-time
# release is covered by tests/fm-outcome-batch-host.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-outcome-batch)

new_case() {  # <name>
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/config" "$CASE/state"
  : >"$CASE/config/outcome-batch"
  : >"$CASE/state/branch-outcomes.jsonl"
  NEXT_SEQ=1
}

outcome() {  # <task> <summary> [epoch] [wake] [verdict] [batchable]: append the next row
  jq -cn --argjson s "$NEXT_SEQ" --arg t "$1" --arg m "$2" --argjson e "${3:-$(date +%s)}" \
    --arg w "${4:-signal: $1.status}" --arg v "${5:-captain}" --arg b "${6:-true}" \
    '{seq: $s, epoch: $e, task: $t, wake: $w, verdict: $v, summary: $m}
     | if $v == "captain" and $b == "true"
       then . + {silent: false, statusEndpoint: 0, statusIdent: "", batchable: true} else . end' \
    >>"$CASE/state/branch-outcomes.jsonl"
  NEXT_SEQ=$((NEXT_SEQ + 1))
}

status() { printf '%s\n' "$2" >>"$CASE/state/$1.status"; }
store() { FM_STATE_OVERRIDE="$CASE/state" "$ROOT/bin/fm-branch-outcome.sh" "$@" >/dev/null </dev/null || fail "store: $*"; }

verdict() { bash -c '. "$1/bin/fm-outcome-batch-lib.sh"; shift; fm_outcome_batch_verdict "$@"' _ "$ROOT" "$CASE/config" "$CASE/state" "$@"; }
due() { bash -c '. "$1/bin/fm-outcome-batch-lib.sh"; fm_outcome_batch_due "$2" "$3"' _ "$ROOT" "$CASE/config" "$CASE/state"; }

test_off_and_routine_hold() {
  new_case off
  rm -f "$CASE/config/outcome-batch"
  status t1 'working [at=1]: setup complete'
  outcome t1 'setup finished; continuing with the tests'
  assert_equals now "$(verdict 1)" "without the setting every captain outcome goes now"
  new_case routine
  status t1 'working [at=1]: setup complete'
  outcome t1 'setup finished; continuing with the tests'
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
    outcome t1 "$summary"
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
Please choose A or B
Which layout do you prefer
the worker asks whether to keep the old flag
ROWS
  for verb in blocked failed needs-decision 'done'; do
    new_case "verb-$verb"
    status t1 "$verb [at=2]: see the report"
    outcome t1 'progress note for the captain'
    assert_equals now "$(verdict 1)" "a task whose newest status is $verb is never delayed"
  done
  # The reviewer's case: a question stays open under an unrelated progress line.
  new_case open-earlier-key
  status t1 'needs-decision [at=1] [key=pick]: choose A or B'
  status t1 'working [at=2]: independent work continues'
  outcome t1 'progress note' '' 'signal: t1.status: continuing'
  assert_equals now "$(verdict 1)" "an open earlier question is never delayed by a later progress line"
  new_case other-key-resolved
  status t1 'needs-decision [at=1] [key=pick]: choose A or B'
  status t1 'needs-decision [at=2] [key=name]: a name'
  status t1 'resolved [at=3] [key=name]: named'
  status t1 'working [at=4]: on it'
  outcome t1 'progress note'
  assert_equals now "$(verdict 1)" "resolving a different key leaves the first question open"
  new_case settled-key
  status t1 'needs-decision [at=1] [key=pick]: choose A or B'
  status t1 'resolved [at=2] [key=pick]: B'
  status t1 'working [at=3]: on it'
  outcome t1 'progress note'
  assert_equals hold "$(verdict 1)" "a settled question no longer prevents batching"
  new_case no-status
  outcome t9 'progress note for the captain'
  assert_equals now "$(verdict 1)" "an outcome whose task status cannot be read is never delayed"
  new_case unscoped-check
  outcome usage-warner 'progress note' '' 'check: /x/usage-warner.check.sh: 40 percent used'
  assert_equals now "$(verdict 1)" "an outcome from a check with no task status is never delayed"
  new_case linked-status
  printf 'working [at=1]: on it\n' >"$CASE/elsewhere"
  ln -s "$CASE/elsewhere" "$CASE/state/t1.status"
  outcome t1 'progress note'
  assert_equals now "$(verdict 1)" "a linked status log is not trusted"
  new_case mixed
  status t1 'working [at=1]: on it'
  status t2 'working [at=1]: on it'
  outcome t1 'progress note'
  outcome t2 'the worker is blocked'
  assert_equals now "$(verdict 1 2)" "one urgent outcome sends the whole turn now"
  new_case routine-verdict
  status t1 'working [at=1]: on it'
  outcome t1 'progress note' '' '' routine
  assert_equals now "$(verdict 1)" "a sequence that is not a captain row is not trusted"
  new_case missing-seq
  status t1 'working [at=1]: on it'
  outcome t1 'progress note'
  assert_equals now "$(verdict 1 2)" "a sequence the store does not hold sends now"
  pass "blockers, failures, sign-ins, credentials, reviews, merges, decisions, deletions, security, prod, questions, open earlier keys, unknown or linked status, and unproven rows are never delayed"
}

# The re-review's case: the engine itself introduces the question while the
# worker's durable status still says working, so no status record shows it.
# Only the engine's explicit mark can make an outcome batchable.
test_only_a_marked_outcome_is_held() {
  local summary
  for summary in 'Please select A or B' 'setup finished; continuing with the tests' 'The build is red; intervention required'; do
    new_case "unmarked-${summary%% *}"
    status t1 'working [at=1]: continuing'
    outcome t1 "$summary" '' 'signal: t1.status' captain false
    assert_equals now "$(verdict 1)" "an unmarked captain outcome goes at once: '$summary'"
    [ ! -e "$CASE/state/.outcome-batch" ] || fail "an unmarked outcome must leave no hold record"
  done
  new_case marked-question
  status t1 'working [at=1]: continuing'
  outcome t1 'Please choose A or B'
  assert_equals now "$(verdict 1)" "a mark never overrides the wording check"
  new_case mixed-mark
  status t1 'working [at=1]: continuing'
  outcome t1 'setup finished'
  outcome t1 'Please select A or B' '' 'signal: t1.status' captain false
  assert_equals now "$(verdict 1 2)" "one unmarked outcome sends the whole turn now"
  # The store's own append owns the mark: captain only, absent unless asked.
  new_case store-append
  : >"$CASE/state/branch-outcomes.jsonl"
  status t1 'working [at=1]: continuing'
  if FM_STATE_OVERRIDE="$CASE/state" "$ROOT/bin/fm-branch-outcome.sh" append --task t1 --verdict routine \
    --summary 'note' --batchable true >/dev/null 2>&1 </dev/null; then
    fail "a routine outcome must not be recorded batchable"
  fi
  store append --task t1 --verdict captain --summary 'setup finished'
  store append --task t1 --verdict captain --summary 'tests finished' --batchable true
  assert_equals 'null true' "$(jq -r '.batchable' "$CASE/state/branch-outcomes.jsonl" | tr '\n' ' ' | sed 's/ $//')" \
    "the mark is absent by default and recorded when asked"
  assert_equals now "$(verdict 1)" "a captain row appended without the mark goes at once"
  assert_equals hold "$(verdict 2)" "a captain row appended with the mark can be held"
  printf '%s\n' '{"seq":3,"epoch":1,"task":"t1","wake":"","verdict":"routine","summary":"x","silent":false,"statusEndpoint":0,"statusIdent":"","batchable":true}' \
    >>"$CASE/state/branch-outcomes.jsonl"
  if FM_STATE_OVERRIDE="$CASE/state" "$ROOT/bin/fm-branch-outcome.sh" unread >/dev/null 2>&1 </dev/null; then
    fail "the store reader must reject a routine row marked batchable"
  fi
  pass "only a captain outcome the engine marked batchable can be held; the store records the mark only on request and rejects it on a routine row"
}

# The re-review's case: the hold is reported only when its release record was
# published, so a release can never be lost.
test_hold_needs_its_release_record() {
  local kind
  for kind in directory link failed-rename; do
    new_case "marker-$kind"
    status t1 'working [at=1]: on it'
    outcome t1 'progress note'
    case "$kind" in
      directory) mkdir "$CASE/state/.outcome-batch" ;;
      link) ln -s "$CASE/elsewhere" "$CASE/state/.outcome-batch" ;;
      failed-rename)
        mkdir -p "$CASE/bin"
        printf '#!/bin/sh
case "$*" in *.outcome-batch) exit 1 ;; esac
exec /bin/mv "$@"
' >"$CASE/bin/mv"
        chmod +x "$CASE/bin/mv" ;;
    esac
    assert_equals now "$(PATH="$CASE/bin:$PATH" verdict 1)" "$kind: an unpublished release record sends now"
    case "$kind" in
      failed-rename)
        [ ! -e "$CASE/state/.outcome-batch" ] || fail "a failed rename must leave no record"
        [ -z "$(find "$CASE/state" -name '.outcome-batch.tmp.*')" ] || fail "a failed rename must remove its temp file" ;;
      *)
        due || fail "$kind: an irregular record with an unread captain row is due at once"
        store mark-read --through 1
        if due; then fail "$kind: an irregular record with nothing unread is not due"; fi ;;
    esac
  done
  pass "a hold is reported only after its release record is read back; an irregular record sends now and releases anything unread"
}

test_unreadable_store() {
  new_case all-bad
  printf 'not json\n' >"$CASE/state/branch-outcomes.jsonl"
  assert_equals now "$(verdict 1)" "an unreadable store sends now"
  # The reviewer's case: a valid row followed by a malformed tail.
  new_case bad-tail
  status t1 'working [at=1]: on it'
  outcome t1 'progress note'
  printf 'not json\n' >>"$CASE/state/branch-outcomes.jsonl"
  assert_equals now "$(verdict 1)" "a valid row before a malformed tail is not trusted"
  printf 'first=1\n' >"$CASE/state/.outcome-batch"
  due || fail "a held batch whose store turned unreadable must reach main"
  [ -f "$CASE/state/.outcome-batch" ] || fail "an unreadable store must keep the only release marker"
  new_case gap
  status t1 'working [at=1]: on it'
  outcome t1 'progress note'
  NEXT_SEQ=3
  outcome t1 'progress note'
  assert_equals now "$(verdict 3)" "a store with a sequence gap is not trusted"
  pass "a malformed, partly written, or gapped store sends now, and a held batch over it reaches main with its marker kept"
}

test_window_and_release() {
  new_case window
  printf 'window-seconds=120\n' >"$CASE/config/outcome-batch"
  status t1 'working [at=1]: on it'
  outcome t1 'progress note' "$(($(date +%s) - 60))"
  assert_equals hold "$(verdict 1)" "a routine outcome inside the window is held"
  if due; then fail "held outcomes inside the window are not due"; fi
  outcome t1 'another progress note'
  assert_equals hold "$(verdict 2)" "a second routine outcome joins the batch"
  assert_equals "first=$(jq -r 'select(.seq == 1) | .epoch' "$CASE/state/branch-outcomes.jsonl")" "$(cat "$CASE/state/.outcome-batch")" \
    "the batch is dated by its oldest held outcome"
  new_case expired
  printf 'window-seconds=120\n' >"$CASE/config/outcome-batch"
  status t1 'working [at=1]: on it'
  outcome t1 'progress note' "$(($(date +%s) - 200))"
  printf 'first=1\n' >"$CASE/state/.outcome-batch"
  due || fail "held outcomes past the window are due"
  outcome t1 'another progress note'
  assert_equals now "$(verdict 2)" "a routine outcome after the window releases the batch"
  new_case setting-removed
  status t1 'working [at=1]: on it'
  outcome t1 'progress note'
  printf 'first=1\n' >"$CASE/state/.outcome-batch"
  rm -f "$CASE/config/outcome-batch"
  due || fail "removing the setting releases what it held"
  new_case presented
  status t1 'working [at=1]: on it'
  outcome t1 'progress note' 1
  store mark-read --through 1
  printf 'first=1\n' >"$CASE/state/.outcome-batch"
  if due; then fail "outcomes main was already shown are never released again"; fi
  [ ! -e "$CASE/state/.outcome-batch" ] || fail "a presented batch clears its record"
  pass "held outcomes are released once the window passes or the setting goes, and only once"
}

test_scale() {
  local n i start ms seqs expected
  for n in 5 20 21 100 1000; do
    # Every outcome belongs to one turn: the verdict reads the store once.
    new_case "turn-$n"
    seqs=()
    for i in $(seq 1 "$n"); do
      printf '{"seq":%s,"epoch":%s,"task":"t%s","wake":"signal: t%s.status","verdict":"captain","summary":"progress note","silent":false,"statusEndpoint":0,"statusIdent":"","batchable":true}\n' "$i" "$(date +%s)" "$i" "$i"
      printf 'working [at=1]: on it\n' >"$CASE/state/t$i.status"
      seqs+=("$i")
    done >"$CASE/state/branch-outcomes.jsonl"
    # Up to 20 routine outcomes in one turn are held together; a larger turn
    # is already one batch and goes at once without per-outcome work.
    expected=hold
    [ "$n" -le 20 ] || expected=now
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    assert_equals "$expected" "$(verdict "${seqs[@]}")" "$n outcomes in one turn: $expected"
    ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start ))
    printf '# scale: %s outcomes in one turn -> %s in %s ms\n' "$n" "$expected" "$ms"
    # A long history already shown to main, then one new outcome.
    new_case "history-$n"
    for i in $(seq 1 "$n"); do
      printf '{"seq":%s,"epoch":1,"task":"t1","wake":"signal: t1.status","verdict":"captain","summary":"progress note"}\n' "$i"
    done >"$CASE/state/branch-outcomes.jsonl"
    NEXT_SEQ=$((n + 1))
    store mark-read --through "$n"
    status t1 'working [at=1]: on it'
    outcome t1 'progress note'
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    assert_equals hold "$(verdict $((n + 1)))" "one new outcome after $n shown ones is held"
    ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start ))
    printf '# scale: 1 new outcome after %s shown ones -> verdict in %s ms, store %s bytes\n' "$n" "$ms" "$(wc -c <"$CASE/state/branch-outcomes.jsonl" | tr -d ' ')"
  done
  pass "a turn of up to 20 routine outcomes is held and a larger one goes at once, and one new outcome is judged the same after 5, 100 and 1000 shown ones (timings above)"
}

test_off_and_routine_hold
test_never_delayed
test_only_a_marked_outcome_is_held
test_hold_needs_its_release_record
test_unreadable_store
test_window_and_release
test_scale
