#!/usr/bin/env bash
# tests/fm-wake-drain-unread-status.test.sh - drain must surface every still-
# unread informational status line since the last presentation, not only the
# newest line. This is a portable tests/ regression: the drain decides WHICH
# status lines to surface, so the real drain/classify functions over crafted
# status logs are sufficient (no harness). The incident this pins: a `note:`
# answer immediately followed by a routine `note:` was buried because the
# annotation kept only the newest line and `note:` never folds into OPEN
# DECISIONS.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-unread-status-tests)

# Establish the durable last-presentation cursor by draining once over a
# bootstrap line so later appends are "new since last drain".
prime_cursor() {  # <state> <status-file>
  local state=$1 status=$2
  printf 'working: bootstrap cursor line\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "bootstrap drain failed while priming the unread cursor"
}

test_incident_note_answer_buried_under_routine_note_surfaces_both() {
  local dir state out status
  dir=$(make_case incident-buried-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task1.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on the incident shape"

  grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || fail "the incident shape produced no UNREAD STATUS section: $(cat "$out")"
  grep -F 'task1 note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the buried answer note was not surfaced: $(cat "$out")"
  grep -F 'task1 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the newest routine note was dropped while surfacing the answer: $(cat "$out")"
  pass "a note: answer buried under a later routine note: is surfaced with both lines"
}

test_already_presented_notes_are_not_replayed() {
  local dir state out status
  dir=$(make_case no-replay)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task2.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain of unread notes failed"
  grep -F 'captain said use REST not RPC' "$out" >/dev/null \
    || fail "setup error: first drain did not surface the answer note"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after presentation failed"
  if grep -F 'captain said use REST not RPC' "$out" >/dev/null; then
    fail "an already-presented answer note was replayed as new: $(cat "$out")"
  fi
  if grep -F 're-read acknowledgement' "$out" >/dev/null; then
    fail "an already-presented routine note was replayed as new: $(cat "$out")"
  fi
  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "the second drain reprinted an UNREAD STATUS section with no new lines: $(cat "$out")"
  fi
  pass "already-presented note: lines are not re-surfaced on the next drain"
}

test_brand_new_note_after_presentation_is_surfaced() {
  local dir state out status
  dir=$(make_case brand-new-note)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task3.status"
  prime_cursor "$state" "$status"

  printf 'note: first answer\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the first note failed"
  grep -F 'task3 note: first answer' "$out" >/dev/null \
    || fail "setup error: first note was not presented"

  printf 'note: follow-up after ack\n' >> "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain of the brand-new note failed"
  grep -F 'task3 note: follow-up after ack' "$out" >/dev/null \
    || fail "a brand-new note after presentation was not surfaced: $(cat "$out")"
  if grep -F 'task3 note: first answer' "$out" >/dev/null; then
    fail "the already-presented first note was replayed next to the new one: $(cat "$out")"
  fi
  pass "a brand-new note: after presentation is surfaced without replaying handled lines"
}

test_signal_annotation_surfaces_every_unread_note_not_only_the_newest() {
  local dir state out err status
  dir=$(make_case signal-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  status="$state/task4.status"
  prime_cursor "$state" "$status"

  printf 'note: captain said use REST not RPC\n' >> "$status"
  printf 'note: re-read acknowledgement\n' >> "$status"
  append_wake "$state" signal task4.status "signal: task4.status" \
    || fail "queueing the incident-shape status signal failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" \
    || fail "signal drain failed on the incident shape"

  grep -F 'unread wake-EVENT since last drain, not current state: task4.status: note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the signal annotation dropped the buried answer note: $(cat "$out")"
  grep -F 'latest wake-EVENT observed at drain, not current state: task4.status: note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the signal annotation dropped the newest routine note: $(cat "$out")"
  grep "$(printf '\tsignal\ttask4.status\t')" "$out" >/dev/null \
    || fail "surfacing unread notes hid the authoritative raw wake row"
  pass "a queued status signal annotates every unread note, not only the newest"
}

test_pending_reply_resolution_surfaces_once() {
  local dir state out status
  dir=$(make_case pending-reply-resolution)
  state="$dir/state"
  out="$dir/drain.out"
  status="$state/task5.status"
  prime_cursor "$state" "$status"

  {
    printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=task5 pending-reply-id=abcdef0123456789 request=ship it\n'
    printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=task5 pending-reply-id=abcdef0123456789 via=status\n'
    printf 'note: re-read acknowledgement\n'
  } >> "$status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a pending-reply resolution"

  grep -F 'pending-reply-resolved: task=task5 pending-reply-id=abcdef0123456789 via=status' "$out" >/dev/null \
    || fail "the pending-reply resolution was buried under the later note: $(cat "$out")"
  grep -F 'task5 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the trailing note was not surfaced with the pending-reply resolution: $(cat "$out")"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the pending-reply resolution did not close its open decision: $(cat "$out")"
  fi

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain after pending-reply presentation failed"
  if grep -F 'pending-reply-resolved:' "$out" >/dev/null; then
    fail "an already-presented pending-reply resolution was replayed: $(cat "$out")"
  fi
  pass "a pending-reply resolution buried under a later note surfaces once and closes OPEN DECISIONS"
}

test_open_decisions_fold_is_unchanged() {
  local dir state out
  dir=$(make_case open-decisions-regression)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task6.status"
  printf 'working: continuing other work\n' >> "$state/task6.status"
  printf 'note: re-read acknowledgement\n' >> "$state/task6.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried needs-decision plus a note"

  grep -F 'task6 [key=api-shape] needs-decision: pick REST or RPC' "$out" >/dev/null \
    || fail "OPEN DECISIONS no longer surfaces a buried needs-decision: $(cat "$out")"
  grep -F 'task6 note: re-read acknowledgement' "$out" >/dev/null \
    || fail "the unread note was not surfaced alongside the still-open decision: $(cat "$out")"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "OPEN DECISIONS lost its answerer-closes hint"

  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task6.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after resolving the keyed decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  if grep -F 'pick REST or RPC' "$out" >/dev/null; then
    fail "a resolved decision leaked back through the unread surface: $(cat "$out")"
  fi
  pass "OPEN DECISIONS still folds needs-decision/blocked independently of unread notes"
}

test_routine_working_lines_stay_silent_on_the_empty_queue() {
  local dir state out
  dir=$(make_case silent-working)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task7.status"
  printf 'done: shipped clean\n' > "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with only routine working/done lines"

  if grep -F 'UNREAD STATUS' "$out" >/dev/null; then
    fail "routine working/done lines printed an UNREAD STATUS section: $(cat "$out")"
  fi
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "routine working/done lines printed OPEN DECISIONS: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty-queue routine case was not silent: $(cat "$out")"
  pass "routine working/done lines still print nothing on an empty-queue drain"
}

test_incident_note_answer_buried_under_routine_note_surfaces_both
test_already_presented_notes_are_not_replayed
test_brand_new_note_after_presentation_is_surfaced
test_signal_annotation_surfaces_every_unread_note_not_only_the_newest
test_pending_reply_resolution_surfaces_once
test_open_decisions_fold_is_unchanged
test_routine_working_lines_stay_silent_on_the_empty_queue
