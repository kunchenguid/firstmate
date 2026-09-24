#!/usr/bin/env bash
# tests/fm-wake-drain-inbox-note.test.sh - a captain inbox note's wake must be
# presented by the drain even when it is buried among many task status wakes,
# and the row must persist until the note itself is acknowledged.
# Portable: the real fm-inbox.sh and fm-wake-drain.sh over a scratch home.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX_BIN="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-inbox-note-tests)

run_inbox() {  # <dir> <args...>
  local dir=$1
  shift
  mkdir -p "$dir/data" "$dir/config"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" "$INBOX_BIN" "$@"
}

# One status line and one production-appended signal wake per task, sourcing
# the wake library once for the whole range.
add_status_wakes() {  # <state> <first> <last>
  FM_STATE_OVERRIDE="$1" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    for i in $(seq "$2" "$3"); do
      printf "working: step %s\n" "$i" >> "$STATE/task$i.status"
      fm_wake_append signal "task$i.status" "signal: task$i.status" || exit 1
    done
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$2" "$3" || fail "status wakes $2-$3 could not be appended"
}

# Queue one note between <count> status wakes (half before, half after) and
# drain once; sets NOTE_ID and ACK_CMD.
seed_and_drain() {  # <dir> <note-text> <count>
  local dir=$1 state="$1/state" count=$3 note_out
  add_status_wakes "$state" 1 $((count / 2))
  note_out=$(run_inbox "$dir" note "$2") || fail "inbox note could not be queued"
  NOTE_ID=$(printf '%s\n' "$note_out" | awk '/^queued /{ print $2; exit }')
  [ -n "$NOTE_ID" ] || fail "inbox note printed no id: $note_out"
  add_status_wakes "$state" $((count / 2 + 1)) "$count"
  [ "$(grep -c "	signal	" "$state/.wake-queue")" -eq "$count" ] \
    || fail "fixture did not queue $count status wakes"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "drain failed: $(cat "$dir/drain.err")"
  ACK_CMD=$(grep -o 'bin/fm-wake-drain.sh --ack-through [0-9]* --recovery-generation [^ ]*' "$dir/drain.err" | head -1)
  [ -n "$ACK_CMD" ] || fail "drain printed no WAKE_ACK_REQUIRED command: $(cat "$dir/drain.err")"
}

run_ack() {  # <dir>
  local dir=$1
  # shellcheck disable=SC2086 # ACK_CMD is the printed command, split on purpose.
  set -- $ACK_CMD
  shift
  FM_STATE_OVERRIDE="$dir/state" "$DRAIN" "$@" > "$dir/ack.out" 2> "$dir/ack.err" \
    || fail "acknowledgement failed: $(cat "$dir/ack.err")"
}

test_note_among_status_wakes_is_presented_and_survives_ack() {
  local dir
  dir=$(make_case buried-note)
  seed_and_drain "$dir" "hold the release until the canary is green" 40

  grep -F "check: captain inbox note $NOTE_ID - hold the release until the canary is green" "$dir/drain.out" >/dev/null \
    || fail "the drain did not present the inbox note wake among 40 status wakes: $(cat "$dir/drain.out")"

  run_ack "$dir"
  grep -F "inbox:$NOTE_ID" "$dir/state/.wake-queue" >/dev/null \
    || fail "pending note wake was consumed by acknowledgement"
  [ -f "$dir/state/inbox/$NOTE_ID.note" ] || fail "wake acknowledgement handled the note"
  FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/again.out" 2> "$dir/again.err" \
    || fail "second drain failed"
  grep -F "check: captain inbox note $NOTE_ID - hold the release until the canary is green" "$dir/again.out" >/dev/null \
    || fail "pending note was not presented again"
  ACK_CMD=$(grep -o 'bin/fm-wake-drain.sh --ack-through [0-9]* --recovery-generation [^ ]*' "$dir/again.err" | head -1)
  run_inbox "$dir" drain --ack "$NOTE_ID" >/dev/null || fail "note acknowledgement failed"
  run_ack "$dir"
  if grep -F "inbox:$NOTE_ID" "$dir/state/.wake-queue" >/dev/null; then
    fail "handled note wake was not consumed"
  fi
  pass "pending inbox note repeats until handled among 40 status wakes"
}

test_handled_note_is_not_renamed_at_ack() {
  local dir
  dir=$(make_case handled-note)
  seed_and_drain "$dir" "rotate the staging key" 2

  run_inbox "$dir" drain --ack "$NOTE_ID" >/dev/null || fail "note acknowledgement failed"
  run_ack "$dir"
  if grep -F "inbox:$NOTE_ID" "$dir/state/.wake-queue" >/dev/null; then
    fail "handled note row was not consumed"
  fi
  pass "a note acknowledged in the same turn is not reported waiting at the wake acknowledgement"
}

test_note_above_cutoff_is_not_named() {
  local dir late_out late_id
  dir=$(make_case late-note)
  seed_and_drain "$dir" "first note" 2
  run_inbox "$dir" drain --ack "$NOTE_ID" >/dev/null || fail "note acknowledgement failed"
  late_out=$(run_inbox "$dir" note "arrived after presentation") || fail "late note could not be queued"
  late_id=$(printf '%s\n' "$late_out" | awk '/^queued /{ print $2; exit }')

  run_ack "$dir"
  grep -F "inbox:$late_id" "$dir/state/.wake-queue" >/dev/null \
    || fail "the late note's unpresented wake row was consumed by the earlier acknowledgement"
  pass "a note whose wake arrived after presentation keeps its row and is not named early"
}

test_branch_ack_releases_pending_note_to_main() {
  local dir state note_out id seq generation
  dir=$(make_case branch-note)
  state="$dir/state"
  note_out=$(run_inbox "$dir" note "approve the branch handoff") || fail "branch note queue failed"
  id=$(printf '%s\n' "$note_out" | awk '/^queued /{print $2; exit}')
  seq=$(awk -F '\t' -v key="inbox:$id" '$4 == key {print $2; exit}' "$state/.wake-queue")
  [ -n "$seq" ] || fail "branch note wake missing"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$$" branch-note >/dev/null || fail "grant activate failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish branch-note "$seq" >/dev/null || fail "grant publish failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" || fail "branch drain failed"
  generation=$(grep -o 'recovery-generation [^ ]*' "$dir/branch.err" | head -1 | cut -d' ' -f2)
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$seq" --recovery-generation "$generation" > "$dir/branch-ack.out" 2> "$dir/branch-ack.err" || fail "branch ack failed: $(cat "$dir/branch-ack.err")"
  grep -F "inbox:$id" "$state/.wake-queue" >/dev/null || fail "branch consumed pending note wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main drain failed"
  grep -F "check: captain inbox note $id" "$dir/main.out" >/dev/null || fail "main did not receive released note wake"
  pass "branch ack releases pending note wake to main"
}

test_branch_ack_releases_pending_note_to_main
test_note_among_status_wakes_is_presented_and_survives_ack
test_handled_note_is_not_renamed_at_ack
test_note_above_cutoff_is_not_named
