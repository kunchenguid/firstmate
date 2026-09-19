#!/usr/bin/env bash
# Behavior tests for pending-close local landing-note compatibility.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$ROOT/bin/fm-backlog-transition-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-transition-lib)
CAPTURE=$TMP_ROOT/captured

fm_backlog_row_probe() {
  FM_BACKLOG_ROW_STATE=in_flight
  FM_BACKLOG_ROW_HOLD_KIND=
  return 0
}

fm_backlog_atomic_transition() {
  local args=("$@") count
  count=${#args[@]}
  printf '%s\n%s\n' "${args[count-2]}" "${args[count-1]}" > "$CAPTURE"
}

assert_replay_note() {  # <serialized-value> <expected-note>
  local encoded=$1 expected=$2 case_dir marker out
  case_dir=$TMP_ROOT/${encoded#local%20}
  marker=$case_dir/state/task-x1.backlog-close
  mkdir -p "$case_dir/state" "$case_dir/data"
  printf 'id=task-x1\ndata=%s\nspawn_gen=spawn-one\narg=--note\narg=%s\n' \
    "$case_dir/data" "$encoded" > "$marker"

  FM_HOME=$case_dir fm_backlog_close_marker_replay \
    "$case_dir/state" "$marker" "$case_dir/data" \
    || fail "pending-close replay rejected $encoded: $FM_BACKLOG_TRANSITION_ERROR"
  out=$(cat "$CAPTURE")
  assert_contains "$out" '--note' "$encoded replay dropped the note flag"
  assert_contains "$out" "$expected" "$encoded replay changed the landing note"
}

assert_replay_rejected() {  # <serialized-value>
  local encoded=$1 case_dir marker
  case_dir=$TMP_ROOT/reject-${encoded//[^A-Za-z0-9]/_}
  marker=$case_dir/state/task-x1.backlog-close
  mkdir -p "$case_dir/state" "$case_dir/data"
  printf 'id=task-x1\ndata=%s\nspawn_gen=spawn-one\narg=--note\narg=%s\n' \
    "$case_dir/data" "$encoded" > "$marker"

  FM_HOME=$case_dir fm_backlog_close_marker_replay \
    "$case_dir/state" "$marker" "$case_dir/data" \
    && fail "pending-close replay accepted $encoded"
}

test_legacy_and_named_notes_replay() {
  assert_replay_note local%20main 'local main'
  assert_replay_note local-landing:develop 'local-landing:develop'
  assert_replay_rejected local%20develop
  pass "pending-close replay accepts only supported local landing notes"
}

test_legacy_note_serializes() {
  local case_dir tmp
  case_dir=$TMP_ROOT/stage
  tmp=$case_dir/state/.task-x1.backlog-close.tmp
  mkdir -p "$case_dir/state" "$case_dir/data"
  FM_HOME=$case_dir fm_backlog_close_marker_stage \
    "$tmp" task-x1 "$case_dir/data" spawn-one "$case_dir/state" 0 \
    --note 'local main' \
    || fail "legacy local note did not serialize: $FM_BACKLOG_TRANSITION_ERROR"
  assert_grep 'arg=local%20main' "$tmp" \
    "legacy local note was not encoded in the pending-close record"
  pass "pending-close serialization preserves the supported legacy note"
}

test_arbitrary_legacy_note_rejected() {
  local case_dir tmp
  case_dir=$TMP_ROOT/stage-reject
  tmp=$case_dir/state/.task-x1.backlog-close.tmp
  mkdir -p "$case_dir/state" "$case_dir/data"
  FM_HOME=$case_dir fm_backlog_close_marker_stage \
    "$tmp" task-x1 "$case_dir/data" spawn-one "$case_dir/state" 0 \
    --note 'local develop' \
    && fail "pending-close staging accepted arbitrary legacy local note"
}

test_legacy_and_named_notes_replay
test_legacy_note_serializes
test_arbitrary_legacy_note_rejected

echo "# all fm-backlog-transition-lib tests passed"
