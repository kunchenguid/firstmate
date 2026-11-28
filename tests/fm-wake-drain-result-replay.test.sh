#!/usr/bin/env bash
# tests/fm-wake-drain-result-replay.test.sh - executable regressions for the
# opt-in config/result-replay gate: a completed result (`done:` line) that a
# main drain presented keeps repeating until main's matching handling
# acknowledgement, while the default drain keeps its one-shot presentation.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-result-replay-tests)

# Both postures run without the supervision host so BRANCH OUTCOMES stays out
# of the drain (bin/fm-supervision-engine-lib.sh owns that gate).
GATE_ON="$TMP_ROOT/config-on"
GATE_OFF="$TMP_ROOT/config-off"
mkdir -p "$GATE_ON" "$GATE_OFF"
: > "$GATE_ON/supervision-host-off"
: > "$GATE_ON/result-replay"
: > "$GATE_OFF/supervision-host-off"
export FM_CONFIG_OVERRIDE="$GATE_ON"

drain() {  # <state> <stdout> <stderr> [drain args...]
  local state=$1 out=$2 err=$3
  shift 3
  FM_STATE_OVERRIDE="$state" "$DRAIN" "$@" > "$out" 2> "$err"
}

replay_body() {  # <drain-output>
  awk '
    /^UNHANDLED RESULTS \(/ { in_section=1; next }
    in_section && /^(OPEN DECISIONS|RECORD DIVERGENCE|UNREAD STATUS|STATUS OUTCOME BACKSTOP)/ { exit }
    in_section { print }
  ' "$1"
}

test_unacknowledged_completed_result_repeats_only_with_the_gate() {
  local dir state config result
  for config in "$GATE_ON" "$GATE_OFF"; do
    dir=$(make_case "captured-$(basename "$config")")
    state="$dir/state"
    printf 'done: UNIQUE_COMPLETED_RESULT\n' > "$state/result.status"
    append_wake "$state" signal result.status 'signal: result.status' \
      || fail "could not queue the completion"
    FM_CONFIG_OVERRIDE="$config" drain "$state" "$dir/first.out" "$dir/first.err" \
      || fail "first drain failed: $(cat "$dir/first.err")"
    grep -F 'done: UNIQUE_COMPLETED_RESULT' "$dir/first.out" >/dev/null \
      || fail "first drain omitted the completed result: $(cat "$dir/first.out")"
    FM_CONFIG_OVERRIDE="$config" drain "$state" "$dir/second.out" "$dir/second.err" \
      || fail "second drain failed: $(cat "$dir/second.err")"
    result=absent
    if grep -F 'result done: UNIQUE_COMPLETED_RESULT' "$dir/second.out" >/dev/null; then result=present; fi
    if [ "$config" = "$GATE_ON" ]; then
      [ "$result" = present ] \
        || fail "the unacknowledged completed result disappeared with the gate on: $(cat "$dir/second.out")"
      replay_body "$dir/second.out" | grep -Fx 'result done: UNIQUE_COMPLETED_RESULT' >/dev/null \
        || fail "the repeated result was not under UNHANDLED RESULTS: $(cat "$dir/second.out")"
    else
      [ "$result" = absent ] \
        || fail "the default drain changed its one-shot presentation: $(cat "$dir/second.out")"
      [ ! -e "$state/.status-presentation-cursor" ] \
        || ! awk -F '\t' 'NF > 4 { found=1 } END { exit !found }' "$state/.status-presentation-cursor" \
        || fail "the default drain wrote a pending-result field into the receipt"
    fi
  done
  pass "an unacknowledged completed result repeats with config/result-replay and stays one-shot without it"
}

test_matching_acknowledgement_silences_the_handled_result() {
  local dir state
  dir=$(make_case acknowledged)
  state="$dir/state"
  printf 'done: handled completion\n' > "$state/handled.status"
  append_wake "$state" signal handled.status 'signal: handled.status' \
    || fail "could not queue the completion"
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first drain failed"
  drain "$state" "$dir/replay.out" "$dir/replay.err" || fail "replay drain failed"
  grep -F 'handled done: handled completion' "$dir/replay.out" >/dev/null \
    || fail "the result did not repeat before acknowledgement: $(cat "$dir/replay.out")"
  ack_drain_err "$state" "$dir/replay.err" >/dev/null 2>&1 \
    || fail "the acknowledgement printed by the replay drain failed"
  drain "$state" "$dir/after.out" "$dir/after.err" || fail "drain after acknowledgement failed"
  [ ! -s "$dir/after.out" ] || fail "a handled result repeated after its acknowledgement: $(cat "$dir/after.out")"
  [ ! -s "$dir/after.err" ] || fail "a handled result still asked for an acknowledgement: $(cat "$dir/after.err")"
  pass "the matching acknowledgement retires the result and the next drain is silent"
}

test_empty_queue_result_gets_its_own_acknowledgement() {
  local dir state
  dir=$(make_case empty-queue)
  state="$dir/state"
  printf 'done: finished without a queued signal\n' > "$state/quiet.status"
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first empty-queue drain failed"
  grep -F 'quiet done: finished without a queued signal' "$dir/first.out" >/dev/null \
    || fail "the backstop did not present the completion: $(cat "$dir/first.out")"
  grep -F 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 0 --recovery-generation ' "$dir/first.err" >/dev/null \
    || fail "an empty-queue result presentation printed no handling acknowledgement: $(cat "$dir/first.err")"
  drain "$state" "$dir/second.out" "$dir/second.err" || fail "second empty-queue drain failed"
  replay_body "$dir/second.out" | grep -Fx 'quiet done: finished without a queued signal' >/dev/null \
    || fail "the empty-queue completion disappeared before acknowledgement: $(cat "$dir/second.out")"
  ack_drain_err "$state" "$dir/second.err" > "$dir/ack.out" 2>&1 \
    || fail "the empty-queue acknowledgement failed: $(cat "$dir/ack.out")"
  [ ! -s "$dir/ack.out" ] || fail "the empty-queue acknowledgement reported a problem: $(cat "$dir/ack.out")"
  drain "$state" "$dir/third.out" "$dir/third.err" || fail "third empty-queue drain failed"
  [ ! -s "$dir/third.out" ] && [ ! -s "$dir/third.err" ] \
    || fail "the acknowledged empty-queue result was not silent: $(cat "$dir/third.out" "$dir/third.err")"
  pass "an empty-queue completion repeats with its own acknowledgement and then stays silent"
}

test_notes_stay_one_shot_with_the_gate() {
  local dir state
  dir=$(make_case notes)
  state="$dir/state"
  printf 'note: captain said use REST\n' > "$state/notes.status"
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first note drain failed"
  grep -F 'notes note: captain said use REST' "$dir/first.out" >/dev/null \
    || fail "the note was not presented: $(cat "$dir/first.out")"
  drain "$state" "$dir/second.out" "$dir/second.err" || fail "second note drain failed"
  [ ! -s "$dir/second.out" ] && [ ! -s "$dir/second.err" ] \
    || fail "an unacknowledged note repeated or asked for acknowledgement: $(cat "$dir/second.out" "$dir/second.err")"
  pass "ordinary notes keep their one-shot presentation with the gate on"
}

test_result_appended_after_presentation_is_not_acknowledged() {
  local dir state
  dir=$(make_case concurrent-append)
  state="$dir/state"
  printf 'done: first result\n' > "$state/busy.status"
  append_wake "$state" signal busy.status 'signal: busy.status' || fail "could not queue the first result"
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first drain failed"
  # This append lands after presentation and before the acknowledgement.
  printf 'done: second result\n' >> "$state/busy.status"
  ack_drain_err "$state" "$dir/first.err" >/dev/null 2>&1 || fail "the first acknowledgement failed"
  drain "$state" "$dir/second.out" "$dir/second.err" || fail "second drain failed"
  grep -F 'busy done: second result' "$dir/second.out" >/dev/null \
    || fail "the acknowledgement consumed a result appended after presentation: $(cat "$dir/second.out")"
  if grep -F 'first result' "$dir/second.out" >/dev/null; then
    fail "the acknowledged first result repeated: $(cat "$dir/second.out")"
  fi
  grep -F 'WAKE_ACK_REQUIRED:' "$dir/second.err" >/dev/null \
    || fail "the newly presented result asked for no acknowledgement: $(cat "$dir/second.err")"
  pass "an acknowledgement retires only results presented before it, never a later append"
}

test_replaced_status_file_keeps_the_pending_result() {
  local dir state body
  dir=$(make_case replacement)
  state="$dir/state"
  printf 'done: result from the first log\n' > "$state/reused.status"
  append_wake "$state" signal reused.status 'signal: reused.status' || fail "could not queue the first result"
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first drain failed"
  # Replace the log with a new file of the same length and a routine line.
  rm -f "$state/reused.status"
  printf 'working: second log starts\n' > "$state/reused.status.new"
  mv "$state/reused.status.new" "$state/reused.status"
  drain "$state" "$dir/second.out" "$dir/second.err" || fail "drain after replacement failed"
  body=$(replay_body "$dir/second.out")
  [ "$body" = 'reused done: result from the first log' ] \
    || fail "the replacement changed the pending result instead of repeating its retained text: $(cat "$dir/second.out")"
  ack_drain_err "$state" "$dir/second.err" >/dev/null 2>&1 || fail "acknowledgement after replacement failed"
  printf 'done: result from the second log\n' >> "$state/reused.status"
  drain "$state" "$dir/third.out" "$dir/third.err" || fail "drain after the second log's result failed"
  grep -F 'reused done: result from the second log' "$dir/third.out" >/dev/null \
    || fail "the old receipt acknowledged the replacement log's result: $(cat "$dir/third.out")"
  if grep -F 'result from the first log' "$dir/third.out" >/dev/null; then
    fail "the acknowledged first-log result repeated: $(cat "$dir/third.out")"
  fi
  pass "a replaced status log neither loses the pending result nor lets its receipt acknowledge new bytes"
}

test_branch_reader_neither_creates_nor_retires_main_results() {
  local dir state sequence generation
  dir=$(make_case branch-reader)
  state="$dir/state"
  printf 'done: main result\n' > "$state/main-task.status"
  append_wake "$state" signal main-task.status 'signal: main-task.status' || fail "could not queue main's row"
  drain "$state" "$dir/main.out" "$dir/main.err" || fail "main drain failed"
  grep -F 'main result' "$dir/main.out" >/dev/null || fail "main did not present its result"

  printf 'done: branch result\n' > "$state/branch-task.status"
  append_wake "$state" signal branch-task.status 'signal: branch-task.status' || fail "could not queue the branch row"
  sequence=$(awk -F '\t' '$4 == "branch-task.status" { print $2 }' "$state/.wake-queue")
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" result-replay-branch >/dev/null || fail "branch activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish result-replay-branch "$sequence" >/dev/null \
    || fail "branch grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch drain failed: $(cat "$dir/branch.err")"
  grep -F 'branch result' "$dir/branch.out" >/dev/null || fail "the branch did not present its result"
  if grep -F 'UNHANDLED RESULTS' "$dir/branch.out" >/dev/null; then
    fail "the branch actor replayed main's pending results: $(cat "$dir/branch.out")"
  fi
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$dir/branch.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/branch.err")
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 \
    || fail "branch acknowledgement failed"

  drain "$state" "$dir/main2.out" "$dir/main2.err" || fail "second main drain failed"
  replay_body "$dir/main2.out" | grep -Fx 'main-task done: main result' >/dev/null \
    || fail "a branch acknowledgement retired main's pending result: $(cat "$dir/main2.out")"
  # The main-only backstop may still surface the branch's uncovered result;
  # it must not repeat as if main had presented it earlier.
  if replay_body "$dir/main2.out" | grep -F 'branch result' >/dev/null; then
    fail "a branch presentation became main's pending result: $(cat "$dir/main2.out")"
  fi
  pass "the branch reader neither creates nor retires main's pending results"
}

test_stale_acknowledgement_does_not_retire_a_newer_result() {
  local dir state
  dir=$(make_case stale-ack)
  state="$dir/state"
  printf 'done: first episode\n' > "$state/stale.status"
  append_wake "$state" signal stale.status 'signal: stale.status' || fail "could not queue the first result"
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first drain failed"
  ack_drain_err "$state" "$dir/first.err" >/dev/null 2>&1 || fail "the first acknowledgement failed"
  printf 'done: second episode\n' >> "$state/stale.status"
  drain "$state" "$dir/second.out" "$dir/second.err" || fail "second drain failed"
  grep -F 'stale done: second episode' "$dir/second.out" >/dev/null || fail "the second result was not presented"
  # Replaying the first episode's acknowledgement must not retire the second.
  ack_drain_err "$state" "$dir/first.err" >/dev/null 2>&1 || true
  drain "$state" "$dir/third.out" "$dir/third.err" || fail "third drain failed"
  replay_body "$dir/third.out" | grep -Fx 'stale done: second episode' >/dev/null \
    || fail "a stale acknowledgement retired a newer result: $(cat "$dir/third.out")"
  pass "an acknowledgement from an earlier episode cannot retire a newer result"
}

test_partial_acknowledgement_keeps_the_unacknowledged_rows_result() {
  local dir state
  dir=$(make_case partial-ack)
  state="$dir/state"
  printf 'working: row one\n' > "$state/early.status"
  append_wake "$state" signal early.status 'signal: early.status' || fail "could not queue row one"
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first drain failed"
  printf 'done: row two result\n' > "$state/late.status"
  append_wake "$state" signal late.status 'signal: late.status' || fail "could not queue row two"
  drain "$state" "$dir/second.out" "$dir/second.err" || fail "second drain failed"
  grep -F 'late done: row two result' "$dir/second.out" >/dev/null \
    || fail "the second drain did not present row two's result: $(cat "$dir/second.out")"
  # The first drain's command covers row one only; row two stays queued.
  ack_drain_err "$state" "$dir/first.err" >/dev/null 2>&1 || fail "the row one acknowledgement failed"
  drain "$state" "$dir/third.out" "$dir/third.err" || fail "third drain failed"
  grep -F 'signal: late.status' "$dir/third.out" >/dev/null \
    || fail "the partial acknowledgement consumed row two: $(cat "$dir/third.out")"
  replay_body "$dir/third.out" | grep -Fx 'late done: row two result' >/dev/null \
    || fail "a partial acknowledgement retired the result of a row it did not cover: $(cat "$dir/third.out")"
  ack_drain_err "$state" "$dir/third.err" >/dev/null 2>&1 || fail "the full acknowledgement failed"
  drain "$state" "$dir/fourth.out" "$dir/fourth.err" || fail "fourth drain failed"
  [ ! -s "$dir/fourth.out" ] && [ ! -s "$dir/fourth.err" ] \
    || fail "the fully acknowledged result was not silent: $(cat "$dir/fourth.out" "$dir/fourth.err")"
  pass "an acknowledgement that stops below a presented row leaves that row's result repeating"
}

test_replay_is_bounded_and_names_what_it_drops() {
  local dir state i body
  dir=$(make_case bounded)
  state="$dir/state"
  : > "$state/many.status"
  for i in 1 2 3 4 5 6; do
    printf 'done: result %s\n' "$i" >> "$state/many.status"
  done
  append_wake "$state" signal many.status 'signal: many.status' || fail "could not queue the results"
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first drain failed"
  grep -F 'UNHANDLED RESULTS: 2 older result(s) for many exceed the replay bound and will not repeat' "$dir/first.out" >/dev/null \
    || fail "the drain did not name the results beyond the bound: $(cat "$dir/first.out")"
  drain "$state" "$dir/second.out" "$dir/second.err" || fail "second drain failed"
  body=$(replay_body "$dir/second.out")
  [ "$body" = "many done: result 3
many done: result 4
many done: result 5
many done: result 6" ] || fail "the replay was not the four newest results: $body"
  pass "replay keeps the four newest results per task and names the dropped count"
}

test_byte_cap_omission_survives_the_acknowledgement() {
  local dir state i long second third
  dir=$(make_case byte-cap)
  state="$dir/state"
  long=$(printf '%0200d' 0)
  for i in $(seq 1 20); do
    # A later routine line keeps the backstop out, so only the replay repeats.
    printf 'done: result %s %s\nworking: idle\n' "$i" "$long" > "$state/cap$i.status"
    append_wake "$state" signal "cap$i.status" "signal: cap$i.status" || fail "could not queue result $i"
  done
  drain "$state" "$dir/first.out" "$dir/first.err" || fail "first drain failed"
  drain "$state" "$dir/second.out" "$dir/second.err" || fail "second drain failed"
  grep -E '^UNHANDLED RESULTS: [0-9]+ more omitted \(byte cap\)$' "$dir/second.out" >/dev/null \
    || fail "twenty long results fit under the replay byte cap: $(cat "$dir/second.out")"
  second=$(replay_body "$dir/second.out" | grep -c ' done: result ')
  ack_drain_err "$state" "$dir/second.err" >/dev/null 2>&1 || fail "the acknowledgement failed"
  drain "$state" "$dir/third.out" "$dir/third.err" || fail "third drain failed"
  third=$(replay_body "$dir/third.out" | grep -c ' done: result ')
  [ "$third" -gt 0 ] || fail "the acknowledgement retired results the byte cap omitted: $(cat "$dir/third.out")"
  [ $((second + third)) -eq 20 ] \
    || fail "the replay lost or duplicated results across the byte cap: $second then $third of 20"
  pass "results the byte cap omits keep repeating after the acknowledgement of the printed ones"
}

test_unacknowledged_completed_result_repeats_only_with_the_gate
test_byte_cap_omission_survives_the_acknowledgement
test_matching_acknowledgement_silences_the_handled_result
test_empty_queue_result_gets_its_own_acknowledgement
test_notes_stay_one_shot_with_the_gate
test_result_appended_after_presentation_is_not_acknowledged
test_replaced_status_file_keeps_the_pending_result
test_branch_reader_neither_creates_nor_retires_main_results
test_stale_acknowledgement_does_not_retire_a_newer_result
test_partial_acknowledgement_keeps_the_unacknowledged_rows_result
test_replay_is_bounded_and_names_what_it_drops
