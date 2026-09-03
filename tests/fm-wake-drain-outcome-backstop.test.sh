#!/usr/bin/env bash
# tests/fm-wake-drain-outcome-backstop.test.sh - executable regressions for the
# main-drain backstop that recovers a captain-facing latest status event after
# its queue row disappeared without a newer supervision-branch outcome.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
OUTCOMES="$ROOT/bin/fm-branch-outcome.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-outcome-backstop-tests)

set_mtime() {  # <epoch> <file>
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

append_outcome() {  # <state> <task> <summary>
  FM_STATE_OVERRIDE="$1" "$OUTCOMES" append \
    --task "$2" --verdict captain --summary "$3" >/dev/null
}

backstop_body() {  # <drain-output>
  awk '
    /^STATUS OUTCOME BACKSTOP \(/ { in_section=1; next }
    in_section && /^(OPEN DECISIONS|RECORD DIVERGENCE|UNREAD STATUS|WAKE_ACK_REQUIRED)/ { exit }
    in_section { print }
  ' "$1"
}

test_uncovered_keyless_captain_events_surface_on_the_next_main_drain() {
  local dir state out body old
  dir=$(make_case uncovered-keyless)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: PR https://example.test/3346 checks green\n' > "$state/done-task.status"
  printf 'blocked: release credential unavailable\n' > "$state/blocked-task.status"
  printf 'needs-decision: choose REST or RPC\n' > "$state/decision-task.status"
  set_mtime "$old" "$state/done-task.status"
  set_mtime "$old" "$state/blocked-task.status"
  set_mtime "$old" "$state/decision-task.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for uncovered keyless captain events"
  grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null \
    || fail "uncovered keyless events produced no outcome backstop: $(cat "$out")"
  body=$(backstop_body "$out")
  case "$body" in *'done-task done: PR https://example.test/3346 checks green'*) ;; *) fail "keyless done event did not surface in the backstop: $body" ;; esac
  grep -F 'blocked-task blocked: release credential unavailable' "$out" >/dev/null \
    || fail "keyless blocked event did not surface through OPEN DECISIONS: $(cat "$out")"
  grep -F 'decision-task needs-decision: choose REST or RPC' "$out" >/dev/null \
    || fail "keyless needs-decision event did not surface through OPEN DECISIONS: $(cat "$out")"
  pass "a newest keyless done, blocked, or needs-decision event with no newer branch outcome surfaces on the next main drain"
}

test_newer_task_outcome_and_routine_latest_events_stay_silent() {
  local dir state out old
  dir=$(make_case covered-and-routine)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: already delivered completion\n' > "$state/covered.status"
  set_mtime "$old" "$state/covered.status"
  append_outcome "$state" covered 'covered completion reached main'
  printf 'working: rebased onto merged #76\n' > "$state/working.status"
  printf 'paused: waiting for the scheduled release window\n' > "$state/paused.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for covered and routine latest events"
  if grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null; then
    fail "a newer branch outcome or routine latest event was re-presented: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "covered and routine latest events broke the silent drain contract: $(cat "$out")"
  pass "a newer task-matching branch outcome suppresses the backstop and routine latest events stay silent"
}

test_older_or_other_task_outcome_cannot_hide_a_new_captain_event() {
  local dir state out body future
  dir=$(make_case stale-outcomes)
  state="$dir/state"
  out="$dir/drain.out"

  append_outcome "$state" same-task 'older completion'
  append_outcome "$state" unrelated-task 'newer but unrelated completion'
  future=$(( $(date +%s) + 20 ))
  printf 'failed: a later attempt failed\n' > "$state/same-task.status"
  printf 'PR ready for review\n' > "$state/no-task-outcome.status"
  set_mtime "$future" "$state/same-task.status"
  set_mtime "$future" "$state/no-task-outcome.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for stale branch outcomes"
  body=$(backstop_body "$out")
  case "$body" in *'same-task failed: a later attempt failed'*) ;; *) fail "an older same-task outcome hid a later failure: $body" ;; esac
  case "$body" in *'no-task-outcome PR ready for review'*) ;; *) fail "another task's newer outcome hid a captain-facing event: $body" ;; esac
  pass "only a strictly newer outcome for the same task can suppress its latest captain event"
}

test_branch_annotation_cannot_consume_the_main_resurfacing_backstop() {
  local dir state branch_out branch_err main_out sequence generation old
  dir=$(make_case branch-then-main)
  state="$dir/state"
  branch_out="$dir/branch.out"
  branch_err="$dir/branch.err"
  main_out="$dir/main.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: branch intake never produced an outcome\n' > "$state/lost-task.status"
  set_mtime "$old" "$state/lost-task.status"
  append_wake "$state" signal lost-task.status 'signal: lost-task.status' \
    || fail "could not queue the branch-owned status signal"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" mode5-backstop \
    || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish mode5-backstop 1 \
    || fail "branch grant publication failed"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$branch_out" 2> "$branch_err" \
    || fail "branch drain failed: $(cat "$branch_err")"
  if grep -F 'STATUS OUTCOME BACKSTOP (' "$branch_out" >/dev/null; then
    fail "the branch actor presented the main-only outcome backstop"
  fi
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$branch_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$branch_err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "branch drain omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "branch acknowledgement did not consume its queue row"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$main_out" \
    || fail "main drain failed after the branch lost its wake"
  grep -F 'lost-task done: branch intake never produced an outcome' "$main_out" >/dev/null \
    || fail "the next main drain did not recover the branch-acknowledged keyless done event: $(cat "$main_out")"
  pass "a branch annotation and queue acknowledgement cannot consume the main drain's loss backstop"
}

test_same_second_outcome_uses_status_causal_position() {
  local dir state first_out second_out epoch
  dir=$(make_case same-second-causal-order)
  state="$dir/state"
  first_out="$dir/first.out"
  second_out="$dir/second.out"
  epoch=$(date +%s)

  printf 'done: first completion\n' > "$state/same-second.status"
  set_mtime "$epoch" "$state/same-second.status"
  append_outcome "$state" same-second 'first completion handled'
  set_mtime "$epoch" "$state/same-second.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first_out" \
    || fail "main drain failed for same-second covered status"
  [ ! -s "$first_out" ] \
    || fail "a same-second handled status was re-presented: $(cat "$first_out")"

  printf 'failed: genuinely later same-second event\n' >> "$state/same-second.status"
  set_mtime "$epoch" "$state/same-second.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second_out" \
    || fail "main drain failed for later same-second status"
  grep -F 'same-second failed: genuinely later same-second event' "$second_out" >/dev/null \
    || fail "a later same-second status was hidden by the older outcome: $(cat "$second_out")"
  pass "status byte position distinguishes handled and later same-second events"
}

test_drain_does_not_scan_append_only_outcome_history() {
  local dir state out i
  dir=$(make_case bounded-history)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'done: covered before large history\n' > "$state/bounded-task.status"
  append_outcome "$state" bounded-task 'covered before large history'
  i=1
  while [ "$i" -le 20000 ]; do
    printf 'historical payload that the bounded drain must not parse %06d\n' "$i"
    i=$((i + 1))
  done >> "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed with large append-only outcome history"
  [ ! -s "$out" ] \
    || fail "drain consulted malformed lifetime history instead of the bounded task index: $(cat "$out")"
  pass "drain cost and suppression are independent of append-only outcome history"
}

test_successful_backstop_is_idempotent_without_consuming_delayed_annotation() {
  local dir state first_out second_out signal_out
  dir=$(make_case idempotent-receipt)
  state="$dir/state"
  first_out="$dir/first.out"
  second_out="$dir/second.out"
  signal_out="$dir/signal.out"

  printf 'done: keyless completion awaiting recovery\n' > "$state/receipt-task.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first_out" \
    || fail "first keyless backstop drain failed"
  grep -F 'receipt-task done: keyless completion awaiting recovery' "$first_out" >/dev/null \
    || fail "first drain did not surface the keyless completion: $(cat "$first_out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second_out" \
    || fail "second keyless backstop drain failed"
  [ ! -s "$second_out" ] \
    || fail "a successful backstop presentation repeated unchanged: $(cat "$second_out")"

  append_wake "$state" signal receipt-task.status 'signal: receipt-task.status' \
    || fail "could not publish the delayed signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$signal_out" 2>/dev/null \
    || fail "delayed-signal drain failed"
  grep -F 'latest wake-EVENT observed at drain, not current state: receipt-task.status: done: keyless completion awaiting recovery' "$signal_out" >/dev/null \
    || fail "the backstop receipt consumed the delayed signal annotation: $(cat "$signal_out")"
  pass "backstop receipts prevent repeats without consuming delayed signal annotations"
}

test_output_failure_does_not_commit_the_backstop_receipt() {
  local dir state fakebin out retry_out real_cat
  dir=$(make_case output-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/failed.out"
  retry_out="$dir/retry.out"
  real_cat=$(command -v cat)
  mkdir -p "$fakebin"

  printf 'done: retry after the output consumer fails\n' > "$state/output-task.status"
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  "$state"/.status-presentation.prepared.*) exit 1 ;;
esac
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "the top-level empty-queue drain changed its compatibility exit on an output failure"
  [ ! -s "$out" ] || fail "the failed output consumer received unexpected bytes: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$retry_out" \
    || fail "backstop retry failed after the output consumer recovered"
  grep -F 'output-task done: retry after the output consumer fails' "$retry_out" >/dev/null \
    || fail "the output failure consumed the backstop receipt: $(cat "$retry_out")"
  pass "a failed output consumer leaves the backstop unacknowledged for retry"
}

test_receipt_commit_failure_repeats_the_already_presented_backstop() {
  local dir state fakebin out retry_out final_out real_mv
  dir=$(make_case receipt-commit-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/failed.out"
  retry_out="$dir/retry.out"
  final_out="$dir/final.out"
  real_mv=$(command -v mv)
  mkdir -p "$fakebin"

  printf 'done: presentation precedes its durable receipt\n' > "$state/atomic-task.status"
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do last=\$arg; done
if [ "\${last:-}" = "$state/.status-presentation-cursor" ]; then exit 1; fi
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "the top-level empty-queue drain changed its compatibility exit on a receipt failure"
  grep -F 'atomic-task done: presentation precedes its durable receipt' "$out" >/dev/null \
    || fail "receipt failure prevented the prepared backstop presentation: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$retry_out" \
    || fail "backstop retry failed after receipt storage recovered"
  grep -F 'atomic-task done: presentation precedes its durable receipt' "$retry_out" >/dev/null \
    || fail "the uncommitted backstop did not retry after storage recovered: $(cat "$retry_out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$final_out" \
    || fail "post-recovery idempotence drain failed"
  [ ! -s "$final_out" ] \
    || fail "the successfully committed retry repeated: $(cat "$final_out")"
  pass "receipt failure may repeat a presented backstop but cannot lose it"
}

test_rejected_decision_line_surfaces_once_through_backstop() {
  local dir state first_out second_out
  dir=$(make_case rejected-decision)
  state="$dir/state"
  first_out="$dir/first.out"
  second_out="$dir/second.out"

  printf 'blocked [key=bad/value]: credential missing\n' > "$state/rejected.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first_out" \
    || fail "rejected-decision drain failed"
  grep -F 'rejected blocked [key=bad/value]: credential missing' "$first_out" >/dev/null \
    || fail "captain-facing rejected decision was lost: $(cat "$first_out")"
  if grep -F 'OPEN DECISIONS' "$first_out" >/dev/null; then
    fail "malformed decision key entered the open-decision fold: $(cat "$first_out")"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second_out" \
    || fail "second rejected-decision drain failed"
  [ ! -s "$second_out" ] \
    || fail "rejected decision backstop repeated unchanged: $(cat "$second_out")"
  pass "captain-facing decisions rejected by the fold surface once"
}

test_missing_index_self_heals_on_first_drain() {
  local dir state out old
  dir=$(make_case index-selfheal-covered)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'done: handled before cache interruption\n' > "$state/recovered.status"
  old=$(( $(date +%s) - 20 ))
  set_mtime "$old" "$state/recovered.status"
  printf '%s\n' '{"seq":1,"epoch":'"$((old + 10))"',"task":"recovered","wake":"","verdict":"captain","summary":"legacy handled outcome"}' \
    > "$state/branch-outcomes.jsonl"
  printf '1\n' > "$state/.branch-outcomes-cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "first drain failed while self-healing a missing outcome index"
  [ ! -s "$out" ] \
    || fail "self-healed index re-presented a handled outcome: $(cat "$out")"
  [ -f "$state/.branch-outcome-index-ready" ] \
    || fail "first drain did not publish the outcome-index ready marker"
  if grep -F 'Pi supervision' "$out" >/dev/null; then
    fail "self-heal drain still mentioned Pi supervision: $(cat "$out")"
  fi
  pass "a missing outcome index self-heals on the first drain and suppresses its handled status"
}

# The rebuild recreates the caches from lifetime history; a task teardown
# already removed (no record, no status log) must not get its footprint back.
test_index_rebuild_skips_a_retired_task() {
  local dir state
  dir=$(make_case index-rebuild-retired)
  state="$dir/state"
  printf 'working: still going\n' > "$state/live.status"
  printf '%s\n' \
    '{"seq":1,"epoch":1700000000,"task":"retired","wake":"","verdict":"captain","summary":"merged long ago","silent":false,"statusEndpoint":0,"statusIdent":"-"}' \
    '{"seq":2,"epoch":1700000001,"task":"live","wake":"","verdict":"routine","summary":"healthy","silent":false,"statusEndpoint":0,"statusIdent":"-"}' \
    > "$state/branch-outcomes.jsonl"
  printf '2\n' > "$state/.branch-outcomes-cursor"
  FM_STATE_OVERRIDE="$state" "$OUTCOMES" processed-init > "$dir/init.out" 2>&1 \
    || fail "processed-init failed: $(cat "$dir/init.out")"
  [ -f "$state/.branch-outcome-index-ready" ] || fail "rebuild did not publish the ready marker"
  [ -f "$state/.live.branch-outcome-index" ] || fail "rebuild skipped a task that still has a status log"
  [ ! -e "$state/.retired.branch-outcome-index" ] \
    || fail "rebuild resurrected the outcome index of a task with no record and no status log"
  pass "outcome index rebuild leaves a retired task without an index"
}

test_uncovered_event_surfaces_on_first_drain_without_index() {
  local dir state out body
  dir=$(make_case index-selfheal-uncovered)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'done: uncovered completion with no index\n' > "$state/fresh.status"
  printf '%s\n' '{"seq":1,"epoch":1,"task":"other","wake":"","verdict":"captain","summary":"unrelated"}' \
    > "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "first drain failed for an uncovered status with no outcome index"
  grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null \
    || fail "first drain skipped the backstop instead of self-healing: $(cat "$out")"
  body=$(backstop_body "$out")
  case "$body" in *'fresh done: uncovered completion with no index'*) ;; *)
    fail "uncovered status did not surface after index self-heal: $body"
    ;;
  esac
  [ -f "$state/.branch-outcome-index-ready" ] \
    || fail "first drain did not publish the outcome-index ready marker"
  if grep -F 'Pi supervision' "$out" >/dev/null; then
    fail "uncovered self-heal drain mentioned Pi supervision: $(cat "$out")"
  fi
  pass "a fresh home with a status log and no index surfaces the backstop on its first drain"
}

test_malformed_outcome_store_fails_closed_without_pi_advice() {
  local dir state out
  dir=$(make_case index-selfheal-store-fault)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'done: must not surface over a corrupt outcome store\n' > "$state/unsafe.status"
  printf 'not-json\n' > "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed closed incorrectly on a malformed outcome store"
  grep -F 'STATUS OUTCOME BACKSTOP SKIPPED:' "$out" >/dev/null \
    || fail "malformed store did not fail closed: $(cat "$out")"
  grep -F 'outcome store is unsafe' "$out" >/dev/null \
    || fail "store-fault skip lost its repair wording: $(cat "$out")"
  if grep -F 'Pi supervision' "$out" >/dev/null; then
    fail "store-fault skip still advised restarting Pi supervision: $(cat "$out")"
  fi
  grep -F 'unsafe done:' "$out" >/dev/null \
    && fail "malformed store still presented a backstop event: $(cat "$out")"
  [ ! -f "$state/.branch-outcome-index-ready" ] \
    || fail "a store fault published a ready marker"
  pass "a genuine outcome-store fault fails closed without Pi-specific restart advice"
}

test_held_lock_mode_rejects_an_unlocked_caller() {
  local dir state out
  dir=$(make_case index-selfheal-held-lock-guard)
  state="$dir/state"
  out="$dir/processed-init.out"

  printf '%s\n' '{"seq":1,"epoch":1,"task":"other","wake":"","verdict":"captain","summary":"unrelated"}' \
    > "$state/branch-outcomes.jsonl"

  if FM_STATE_OVERRIDE="$state" "$OUTCOMES" processed-init --held-lock > "$out" 2>&1; then
    fail "processed-init accepted --held-lock without parent lock ownership"
  fi
  [ ! -e "$state/.branch-outcomes-processed" ] \
    || fail "unowned held-lock mode mutated the processed marker"
  [ ! -e "$state/.branch-outcome-index-ready" ] \
    || fail "unowned held-lock mode published the outcome index"
  pass "held-lock initialization rejects callers outside the lock owner's process tree"
}

test_held_lock_mode_accepts_a_lock_owner_descendant() {
  local dir state
  dir=$(make_case index-selfheal-held-lock-descendant)
  state="$dir/state"

  printf '%s\n' '{"seq":1,"epoch":1,"task":"other","wake":"","verdict":"captain","summary":"unrelated"}' \
    > "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_lock_acquire_wait "$STATE/.branch-outcomes.lock" || exit 1
    trap "fm_lock_release \"$STATE/.branch-outcomes.lock\"" EXIT
    sh -c '"'"'$1 processed-init --held-lock'"'"' _ "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$OUTCOMES" \
    || fail "processed-init rejected a descendant of the outcome lock owner"
  [ -f "$state/.branch-outcome-index-ready" ] \
    || fail "descendant held-lock initialization did not publish the outcome index"
  pass "held-lock initialization accepts a descendant of the outcome lock owner"
}

test_index_self_heal_runs_under_the_outcome_lock() {
  local dir state busy_out healed_out holder i
  dir=$(make_case index-selfheal-lock)
  state="$dir/state"
  busy_out="$dir/busy.out"
  healed_out="$dir/healed.out"

  printf 'done: uncovered while the outcome lock is contested\n' > "$state/locked.status"
  printf '%s\n' '{"seq":1,"epoch":1,"task":"other","wake":"","verdict":"captain","summary":"unrelated"}' \
    > "$state/branch-outcomes.jsonl"

  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_lock_try_acquire "$STATE/.branch-outcomes.lock" || exit 1
    trap "fm_lock_release \"$STATE/.branch-outcomes.lock\"" EXIT
    sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ -e "$state/.branch-outcomes.lock" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.branch-outcomes.lock" ] \
    || { kill "$holder" 2>/dev/null || true; fail "test lock holder did not publish the outcome lock"; }

  FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$busy_out" \
    || fail "drain failed while the outcome lock was held"
  grep -F 'branch outcome history is busy' "$busy_out" >/dev/null \
    || fail "contested lock did not skip the backstop: $(cat "$busy_out")"
  [ ! -f "$state/.branch-outcome-index-ready" ] \
    || fail "self-heal published a ready marker without holding the outcome lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$healed_out" \
    || fail "drain failed after the outcome lock was released"
  grep -F 'locked done: uncovered while the outcome lock is contested' "$healed_out" >/dev/null \
    || fail "self-heal under the lock did not surface the uncovered event: $(cat "$healed_out")"
  [ -f "$state/.branch-outcome-index-ready" ] \
    || fail "self-heal under the lock did not publish the ready marker"
  pass "index self-heal runs only while the outcome lock is held"
}

test_overbound_routine_event_stays_silent() {
  local dir state out
  dir=$(make_case overbound-routine-event)
  state="$dir/state"
  out="$dir/drain.out"

  perl -e 'print "working: ", "x" x 70000, "\n"' > "$state/oversized.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for an over-bound routine event"
  [ ! -s "$out" ] \
    || fail "unclassifiable over-bound routine event was presented: $(cat "$out")"
  pass "an over-bound unclassifiable routine event stays silent"
}

test_backstop_output_is_bounded() {
  local dir state out old i payload count longest
  dir=$(make_case bounded-output)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))
  payload=$(printf '%0300d' 0)
  i=1
  while [ "$i" -le 30 ]; do
    printf 'done: completion-%02d %s\n' "$i" "$payload" > "$state/task-$i.status"
    set_mtime "$old" "$state/task-$i.status"
    i=$((i + 1))
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed for bounded output"
  grep -F 'STATUS OUTCOME BACKSTOP:' "$out" | grep -F 'more omitted (byte cap)' >/dev/null \
    || fail "an over-budget backstop did not report bounded omission: $(cat "$out")"
  count=$(backstop_body "$out" | grep -c '^task-' || true)
  [ "$count" -gt 0 ] && [ "$count" -lt 30 ] \
    || fail "backstop byte cap presented an unexpected task count: $count"
  longest=$(backstop_body "$out" | awk '{ if (length > max) max=length } END { print max + 0 }')
  [ "$longest" -le 219 ] || fail "a backstop item exceeded its 219-character budget: $longest"
  pass "the outcome backstop caps each item and its total task output deterministically"
}

test_uncovered_keyless_captain_events_surface_on_the_next_main_drain
test_newer_task_outcome_and_routine_latest_events_stay_silent
test_older_or_other_task_outcome_cannot_hide_a_new_captain_event
test_branch_annotation_cannot_consume_the_main_resurfacing_backstop
test_same_second_outcome_uses_status_causal_position
test_drain_does_not_scan_append_only_outcome_history
test_successful_backstop_is_idempotent_without_consuming_delayed_annotation
test_output_failure_does_not_commit_the_backstop_receipt
test_receipt_commit_failure_repeats_the_already_presented_backstop
test_rejected_decision_line_surfaces_once_through_backstop
test_missing_index_self_heals_on_first_drain
test_index_rebuild_skips_a_retired_task
test_uncovered_event_surfaces_on_first_drain_without_index
test_malformed_outcome_store_fails_closed_without_pi_advice
test_held_lock_mode_rejects_an_unlocked_caller
test_held_lock_mode_accepts_a_lock_owner_descendant
test_index_self_heal_runs_under_the_outcome_lock
test_overbound_routine_event_stays_silent
test_backstop_output_is_bounded
