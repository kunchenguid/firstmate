#!/usr/bin/env bash
# tests/fm-wake-drain-voice-first.test.sh - a captain voice note is presented
# ahead of every other queued wake, under the VOICE heading, whichever order
# the rows were enqueued in. Portable tests/ regression: the drain alone decides
# the presented order, so the real drain over a crafted queue is sufficient (no
# harness). The incident this pins: on 2026-09-10 eleven spoken turns sat queued
# behind a text message that pulled firstmate onto other work, and none were
# answered. Precedence is presentation only - sequence numbers, the
# acknowledgement cutoff, and durability through acknowledgement must be exactly
# what they are without a voice row.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-voice-first-tests)

# The vc- row is appended directly with fm_wake_append because the producer
# (the fm_inbox_conversation.py capture command) is not on main.
VOICE_ID='vc-9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
VOICE_KEY="inbox:$VOICE_ID"
TYPED_KEY='inbox:1757000000-typed1'

# The line number of the first presented row carrying <key>, or empty.
row_line() {  # <drain-stdout> <key>
  awk -F '\t' -v key="$2" 'NF == 5 && $4 == key { print NR; exit }' "$1"
}

# The sequence field of the presented row carrying <key>, or empty.
row_sequence() {  # <drain-stdout> <key>
  awk -F '\t' -v key="$2" 'NF == 5 && $4 == key { print $2; exit }' "$1"
}

assert_voice_presented_first() {  # <case-name> <drain-stdout> <ordinary-key>
  local name=$1 out=$2 ordinary=$3 heading voice_line ordinary_line other_heading
  heading=$(grep -n '^VOICE:' "$out" | head -1 | cut -d: -f1)
  [ -n "$heading" ] || fail "$name: no VOICE heading was printed: $(cat "$out")"
  voice_line=$(row_line "$out" "$VOICE_KEY")
  ordinary_line=$(row_line "$out" "$ordinary")
  [ -n "$voice_line" ] || fail "$name: voice row was not presented: $(cat "$out")"
  [ -n "$ordinary_line" ] || fail "$name: ordinary row was not presented: $(cat "$out")"
  [ "$heading" -lt "$voice_line" ] || fail "$name: VOICE heading did not precede the voice row: $(cat "$out")"
  [ "$voice_line" -lt "$ordinary_line" ] || fail "$name: voice row was presented after the ordinary row: $(cat "$out")"
  other_heading=$(grep -n '^OTHER WAKES' "$out" | head -1 | cut -d: -f1)
  [ -n "$other_heading" ] || fail "$name: the ordinary rows were not labelled as coming after the voice notes: $(cat "$out")"
  [ "$voice_line" -lt "$other_heading" ] && [ "$other_heading" -lt "$ordinary_line" ] \
    || fail "$name: OTHER WAKES heading did not sit between the voice row and the ordinary row: $(cat "$out")"
  [ "$(grep -c '^VOICE:' "$out")" -eq 1 ] || fail "$name: VOICE heading printed more than once: $(cat "$out")"
}

# Acknowledge from the drain's stderr and prove the ordering changed nothing
# about durability: rows stayed queued until the ack, and the ack consumed them.
assert_ack_contract_intact() {  # <case-name> <state> <drain-stderr> <expected-cutoff>
  local name=$1 state=$2 err=$3 expected=$4 cutoff
  cutoff=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  [ "$cutoff" = "$expected" ] || fail "$name: acknowledgement cutoff was $cutoff, expected the highest queued sequence $expected"
  [ -s "$state/.wake-queue" ] || fail "$name: presentation consumed rows before acknowledgement"
  ack_drain_err "$state" "$err" || fail "$name: acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "$name: acknowledged rows remained queued"
}

test_voice_note_enqueued_after_ordinary_wake_is_presented_first() {
  local dir state out err
  dir=$(make_case ordinary-then-voice)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" check "$TYPED_KEY" "check: captain inbox note 1757000000-typed1 - typed note" \
    || fail "ordinary check wake append failed"
  append_wake "$state" check "$VOICE_KEY" "check: captain inbox note $VOICE_ID - I hear you" \
    || fail "voice check wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "drain failed: $(cat "$err")"
  assert_voice_presented_first ordinary-then-voice "$out" "$TYPED_KEY"
  # Presentation moved the row; its sequence is still the one it was appended with.
  [ "$(row_sequence "$out" "$TYPED_KEY")" = 1 ] || fail "ordinary row lost its sequence number: $(cat "$out")"
  [ "$(row_sequence "$out" "$VOICE_KEY")" = 2 ] || fail "voice row lost its sequence number: $(cat "$out")"
  assert_ack_contract_intact ordinary-then-voice "$state" "$err" 2
  pass "a voice note queued after an ordinary wake is still presented first under VOICE"
}

test_voice_note_enqueued_before_ordinary_wakes_stays_first_and_keeps_their_order() {
  local dir state out err typed_line signal_line
  dir=$(make_case voice-then-ordinary)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  printf 'working: under way\n' > "$state/task.status"

  append_wake "$state" check "$VOICE_KEY" "check: captain inbox note $VOICE_ID - Speaking" \
    || fail "voice check wake append failed"
  append_wake "$state" check "$TYPED_KEY" "check: captain inbox note 1757000000-typed1 - typed note" \
    || fail "ordinary check wake append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" \
    || fail "signal wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "drain failed: $(cat "$err")"
  assert_voice_presented_first voice-then-ordinary "$out" "$TYPED_KEY"
  typed_line=$(row_line "$out" "$TYPED_KEY")
  signal_line=$(row_line "$out" task.status)
  [ -n "$signal_line" ] || fail "signal row was not presented: $(cat "$out")"
  [ "$typed_line" -lt "$signal_line" ] || fail "rows behind the voice note lost their queue order: $(cat "$out")"
  [ "$(row_sequence "$out" "$VOICE_KEY")" = 1 ] || fail "voice row lost its sequence number: $(cat "$out")"
  assert_ack_contract_intact voice-then-ordinary "$state" "$err" 3
  pass "a voice note queued first stays first and the rows behind it keep their order"
}

test_typed_inbox_note_alone_prints_no_voice_heading() {
  local dir state out err
  dir=$(make_case typed-only)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  append_wake "$state" check "$TYPED_KEY" "check: captain inbox note 1757000000-typed1 - typed note" \
    || fail "ordinary check wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "drain failed: $(cat "$err")"
  if grep -E '^(VOICE:|OTHER WAKES)' "$out" >/dev/null; then
    fail "a typed inbox note was labelled as voice: $(cat "$out")"
  fi
  [ -n "$(row_line "$out" "$TYPED_KEY")" ] || fail "typed note row was not presented: $(cat "$out")"
  assert_ack_contract_intact typed-only "$state" "$err" 1
  pass "a typed inbox note is an ordinary wake and prints no VOICE heading"
}

test_voice_note_enqueued_after_ordinary_wake_is_presented_first
test_voice_note_enqueued_before_ordinary_wakes_stays_first_and_keeps_their_order
test_typed_inbox_note_alone_prints_no_voice_heading
