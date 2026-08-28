#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement) plus one steering-inbox read; these tests exercise
# the real drain script over crafted status logs and assert on its printed
# output, not on the fold's own source text.
#
# The inbox read exists because "open" hides a distinction that cost a
# supervision turn twice on 2026-08-27: a decision nobody has answered, and a
# decision whose answer is already sitting unread in the worker's instruction
# inbox. Re-answering the second one only enqueues a second record behind the
# same swallowed doorbell, so the row says which it is.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

# Drive the steering-inbox library through its own executable surface, so these
# cases never restate the record or sidecar format.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

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
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

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
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

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
  printf 'done: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

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
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

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
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

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
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

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
# A delivered-but-unread answer is still an OPEN decision - that is the whole
# point of the acknowledgement gate - but the row must say so, or a supervisor
# answers it again into the same blocked composer.
test_unread_answer_is_marked_on_the_open_row() {
  local dir state out rec
  dir=$(make_case unread-answer)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task-u.status"
  printf 'needs-decision [key=other-call]: unanswered so far\n' >> "$state/task-u.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" task-u "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "" >/dev/null

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a pending answer"
  grep -F 'task-u [key=api-shape]' "$out" | grep -F 'still unread by the worker' >/dev/null \
    || fail "the answered-but-unread decision was not marked:"$'\n'"$(cat "$out")"
  grep -F 'task-u [key=other-call]' "$out" | grep -Fv 'still unread' >/dev/null \
    || fail "a decision with NO answer in flight was wrongly marked as delivered:"$'\n'"$(cat "$out")"

  # The acknowledgement closes it, and the row disappears entirely.
  mv "$rec" "$state/task-u.inbox/handled/"
  inbox_lib "$state" fm_task_inbox_commit_resolutions "$state" task-u "$state/task-u.status" >/dev/null \
    || fail "the acknowledged closure failed to commit"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the acknowledgement"
  if grep -F '[key=api-shape]' "$out" >/dev/null; then
    fail "the acknowledged decision still lists as open:"$'\n'"$(cat "$out")"
  fi
  grep -F '[key=other-call]' "$out" >/dev/null \
    || fail "the genuinely open decision disappeared:"$'\n'"$(cat "$out")"
  pass "an open decision whose answer is delivered but unread says so, and clears on acknowledgement"
}

# A retired orphan must not shadow a later, genuine reopening of its key. The
# orphaned closure (its record removed instead of moved) is surfaced once and
# set aside under handled/orphaned/; after firstmate settles it by hand and
# the same key reopens afresh, that decision has NO answer in flight, so its
# row must read plainly - no "still unread" annotation - and the ladder must
# not escalate again on the retired orphan's behalf.
test_reopened_key_after_a_retired_orphan_reads_plainly() {
  local dir state out rec action
  dir=$(make_case orphan-reopened)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task-o.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" task-o "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "" >/dev/null
  rm -f "$rec"
  action=$(inbox_lib "$state" fm_task_inbox_due_action "$state" task-o)
  case "$action" in
    "escalate "*" orphaned "*) ;;
    *) fail "the orphaned closure should escalate: $action" ;;
  esac
  inbox_lib "$state" fm_task_inbox_record_orphan_escalated "$state" task-o "${action##* }" \
    || fail "could not surface and retire the orphan"
  printf 'resolved [key=api-shape]: answered: go with REST (closed by hand)\n' >> "$state/task-o.status"
  printf 'needs-decision [key=api-shape]: pick again for v2\n' >> "$state/task-o.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after a retired orphan"
  grep -F 'task-o [key=api-shape]' "$out" | grep -F 'pick again for v2' >/dev/null \
    || fail "the reopened decision was not listed as open:"$'\n'"$(cat "$out")"
  if grep -F 'task-o [key=api-shape]' "$out" | grep -F 'still unread' >/dev/null; then
    fail "a reopened key with no answer in flight was marked as already answered by a retired orphan:"$'\n'"$(cat "$out")"
  fi
  action=$(inbox_lib "$state" fm_task_inbox_due_action "$state" task-o)
  [ "$action" = quiet ] || fail "the retired orphan escalated again for the reopened key: $action"
  pass "a key reopened after its orphaned answer was retired reads as plainly open, with no repeat escalation"
}

# The unread marker is the one thing on the row a supervisor must not miss, so
# it is never what the per-item byte cut sacrifices.
test_unread_marker_survives_the_per_item_cap() {
  local dir state out rec line
  dir=$(make_case unread-capped)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-uc.status"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" task-uc "go with REST")
  inbox_lib "$state" fm_task_inbox_defer_resolution "$rec" "go with REST" "api-shape" "" >/dev/null

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a capped unread row"
  line=$(grep -F 'task-uc' "$out")
  case "$line" in
    *'[truncated] (answer already delivered, still unread by the worker)') : ;;
    *) fail "the unread marker was truncated away instead of the note: $line" ;;
  esac
  [ "${#line}" -le 219 ] || fail "an annotated item ran ${#line} characters past its per-item budget"
  pass "the delivered-but-unread marker survives the per-item cap"
}

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

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_unread_answer_is_marked_on_the_open_row
test_reopened_key_after_a_retired_orphan_reads_plainly
test_unread_marker_survives_the_per_item_cap
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
