#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  register_task_fixture "$state" task1
  printf 'working: continuing other work\n' >> "$state/task1.status"
  register_task_fixture "$state" task1
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"
  register_task_fixture "$state" task1

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  register_task_fixture "$state" task2
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  register_task_fixture "$state" task2
  printf 'done: shipped\n' >> "$state/task2.status"
  register_task_fixture "$state" task2

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  register_task_fixture "$state" task3
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"
  register_task_fixture "$state" task3

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  register_task_fixture "$state" task4
  printf 'resolved: shipped clean\n' > "$state/task5.status"
  register_task_fixture "$state" task5

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  register_task_fixture "$state" task6
  printf 'working: continuing\n' >> "$state/task6.status"
  register_task_fixture "$state" task6
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  register_task_fixture "$state" task7
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  register_task_fixture "$state" task8
  printf 'working: continuing\n' >> "$state/task8.status"
  register_task_fixture "$state" task8

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  register_task_fixture "$state" local
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"
  register_task_fixture "$state" task-long

  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  register_task_fixture "$state" task-short
  FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

task_in() {  # <home> <tasks-axi arguments...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

open_decisions_body() {  # <drain-output>
  awk '
    /^OPEN DECISIONS \(/ { in_section=1; next }
    in_section && /^(RECORD DIVERGENCE|WAKE_ACK_REQUIRED)/ { exit }
    in_section { print }
  ' "$1"
}

test_terminal_and_parked_history_does_not_reopen_work() {
  local dir state out err second body
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped terminal decision projection regression: tasks-axi not installed"
    return
  }
  dir=$(make_case retired-history)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"
  second="$dir/second.out"
  mkdir -p "$dir/data" "$dir/records"
  cat > "$dir/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "records/completed.md"
done_keep = 0
EOF

  task_in "$dir" add archived-blocker 'Archived blocker' --kind scout --start >/dev/null
  task_in "$dir" 'done' archived-blocker --report data/archived-blocker/report.md >/dev/null
  printf 'needs-decision [key=old]: historical blocker must not reopen execution\n' > "$state/archived-blocker.status"
  register_task_fixture "$state" archived-blocker

  task_in "$dir" add parked-blocker 'Parked blocker' --kind scout >/dev/null
  task_in "$dir" hold parked-blocker --reason 'explicit archive boundary' --kind parked >/dev/null
  printf 'blocked [key=old-wait]: historical wait must not reopen execution\n' > "$state/parked-blocker.status"
  register_task_fixture "$state" parked-blocker

  task_in "$dir" add active-decision 'Active decision' --kind scout --start >/dev/null
  printf 'needs-decision [key=live]: choose the active path\n' > "$state/active-decision.status"
  register_task_fixture "$state" active-decision
  printf 'needs-decision [key=unknown]: preserve an unclassified integrity problem\n' > "$state/unknown-decision.status"
  register_task_fixture "$state" unknown-decision

  task_in "$dir" add archived-outcome 'Archived outcome' --kind scout --start >/dev/null
  task_in "$dir" 'done' archived-outcome --report data/archived-outcome/report.md >/dev/null
  printf 'done: meaningful result was never handed off\n' > "$state/archived-outcome.status"
  register_task_fixture "$state" archived-outcome

  task_in "$dir" add archived-note 'Archived note' --kind scout --start >/dev/null
  task_in "$dir" 'done' archived-note --report data/archived-note/report.md >/dev/null
  printf 'note: unread answer from archived work stays visible once\n' > "$state/archived-note.status"
  register_task_fixture "$state" archived-note

  append_wake "$state" signal archived-blocker.status 'signal: archived blocker' \
    || fail "could not queue the archived task's raw wake"
  FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" > "$out" 2> "$err" || fail "mixed active/archive drain failed"

  grep "$(printf '\tsignal\tarchived-blocker.status\t')" "$out" >/dev/null \
    || fail "the archived task's actionable raw wake was hidden: $(cat "$out")"
  grep -F 'archived-outcome done: meaningful result was never handed off' "$out" >/dev/null \
    || fail "the archived task's unreported outcome was hidden: $(cat "$out")"
  grep -F 'archived-note note: unread answer from archived work stays visible once' "$out" >/dev/null \
    || fail "the archived task's unread note was hidden: $(cat "$out")"
  body=$(open_decisions_body "$out")
  case "$body" in
    *'active-decision [key=live] needs-decision: choose the active path'*) ;;
    *) fail "the active task's independent decision disappeared: $body" ;;
  esac
  case "$body" in
    *'unknown-decision [key=unknown] needs-decision: preserve an unclassified integrity problem'*) ;;
    *) fail "the unknown task's decision/integrity evidence disappeared: $body" ;;
  esac
  case "$body" in
    *'archived-blocker'*|*'parked-blocker'*)
      fail "terminal or explicitly parked history reopened work through OPEN DECISIONS: $body"
      ;;
  esac

  ack_drain_err "$state" "$err" || fail "the mixed raw wake did not acknowledge through its generation guard"
  FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_HOME="${state%/state}" FM_STATE_OVERRIDE="$state" \
    "$DRAIN" > "$second" || fail "second mixed active/archive drain failed"
  body=$(open_decisions_body "$second")
  case "$body" in *'active-decision'*'unknown-decision'*|*'unknown-decision'*'active-decision'*) ;; *)
    fail "active and unknown decisions did not remain independently open: $body" ;;
  esac
  case "$body" in *'archived-blocker'*|*'parked-blocker'*)
    fail "retired historical blockers repeated on the next drain: $body" ;;
  esac
  if grep -F 'meaningful result was never handed off' "$second" >/dev/null \
    || grep -F 'unread answer from archived work' "$second" >/dev/null; then
    fail "one-shot archived outcome/note repeated after successful presentation: $(cat "$second")"
  fi
  pass "terminal and parked status history cannot reopen work while raw wakes, active decisions, unknown evidence, notes, outcomes, and guarded ack survive"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
test_terminal_and_parked_history_does_not_reopen_work
