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
  printf 'resolved: shipped clean\n' > "$state/task5.status"

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
  grep -F 'content truncated. Read and reconcile the full set: bin/fm-wake-drain.sh --open-decisions' "$out" >/dev/null \
    || fail "content truncation omitted the full reader"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

test_full_reader_preserves_all_decisions_without_consuming_wakes() {
  local dir state i note expected out
  dir=$(make_case full-reader)
  state="$dir/state"
  expected="$dir/expected"
  out="$dir/full.out"
  printf 'kind=secondmate\n' > "$state/many.meta"
  for i in $(seq 1 96); do
    note="Question $i? $(printf 'Context %.0s' {1..40})END-$i"
    printf 'needs-decision [key=call-%s]: %s\n' "$i" "$note" >> "$state/many.status"
    printf 'many [key=call-%s] needs-decision: %s\n' "$i" "$note" >> "$expected"
  done
  printf 'note: Context that still needs presentation.\n' >> "$state/many.status"
  append_wake "$state" check fixture 'Handle this separately.' || fail "could not queue fixture"
  cp "$state/.wake-queue" "$dir/queue-before"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --open-decisions > "$out" || fail "full reader failed"
  [ "$(wc -l < "$out" | tr -d ' ')" = 96 ] || fail "full reader did not return all 96 decisions"
  LC_ALL=C sort "$expected" > "$dir/expected-sorted"
  LC_ALL=C sort "$out" > "$dir/actual-sorted"
  cmp -s "$dir/expected-sorted" "$dir/actual-sorted" || fail "full reader lost keys or note content"
  cmp -s "$dir/queue-before" "$state/.wake-queue" || fail "full reader consumed queued wakes"
  [ ! -e "$state/.main-eligible-rows" ] || fail "full reader claimed queued wakes"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" || fail "drain failed"
  grep -F 'many note: Context that still needs presentation.' "$dir/drain.out" >/dev/null \
    || fail "full reader consumed an unread status presentation"
  grep -E '^OPEN DECISIONS: .*omitted.*bin/fm-wake-drain.sh --open-decisions' "$dir/drain.out" >/dev/null \
    || fail "omission notice did not name the full reader"
  grep -E '^WAKE_ACK_REQUIRED: .*open-decisions=96.*--ack-through 1 ' "$dir/drain.err" >/dev/null \
    || fail "queued acknowledgement did not carry the complete count"
  pass "the full reader preserves 96 decisions without consuming or claiming wakes"
}

test_empty_queue_recovery_counts_all_decisions() {
  local dir state i
  dir=$(make_case empty-recovery-count)
  state="$dir/state"
  for i in $(seq 1 96); do
    printf 'needs-decision [key=call-%s]: Choose option %s.\n' "$i" "$i" >> "$state/many.status"
  done
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_publish "$STATE/.watcher-down" downtime' \
    _ "$ROOT/bin/fm-wake-lib.sh" || fail "could not publish recovery"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail "empty recovery drain failed"
  grep -E '^WAKE_ACK_REQUIRED: .*open-decisions=96.*--ack-through 0 ' "$dir/err" >/dev/null \
    || fail "empty-queue acknowledgement did not carry the complete count"
  pass "empty-queue recovery names all 96 open decisions on the acknowledgement line"
}

test_count_distinguishes_empty_from_failed_read() {
  local dir state reader
  dir=$(make_case count-read-failure)
  state="$dir/state"
  reader="$dir/identity-reader"
  append_wake "$state" check fixture 'Handle this separately.' || fail "could not queue fixture"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail "empty decision drain failed"
  grep -E '^WAKE_ACK_REQUIRED: .*open-decisions=0 ' "$dir/err" >/dev/null || fail "empty set was not counted as zero"
  printf 'needs-decision [key=route-check]: Choose the route.\n' > "$state/task.status"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"
  FM_STATUS_IDENTITY_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" \
    || fail "drain did not preserve its wake after presentation failure"
  grep -E '^WAKE_ACK_REQUIRED: .*open-decisions=unknown ' "$dir/err" >/dev/null || fail "failed read claimed a known count"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --open-decisions > "$dir/full" || fail "full reader failed after recovery"
  grep -Fx 'task [key=route-check] needs-decision: Choose the route.' "$dir/full" >/dev/null \
    || fail "full reader lost the canonical routing key"
  printf 'resolved [key=route-check]: Take the north route.\n' >> "$state/task.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --open-decisions > "$dir/full" || fail "full reader failed after resolution"
  [ ! -s "$dir/full" ] || fail "full reader retained a resolved routing key"
  pass "empty, unreadable, and resolved decision sets remain distinct"
}

test_full_reader_refuses_an_unreadable_status_log() {
  local dir state
  dir=$(make_case full-reader-unreadable)
  state="$dir/state"
  printf 'needs-decision [key=visible]: Keep this one.\n' > "$state/alpha.status"
  printf 'needs-decision [key=hidden]: Do not lose this one.\n' > "$state/beta.status"
  chmod 000 "$state/beta.status"
  if FM_STATE_OVERRIDE="$state" "$DRAIN" --open-decisions > "$dir/full" 2> "$dir/err"; then
    chmod 600 "$state/beta.status"
    fail "full reader reported success while beta.status was unreadable: $(cat "$dir/full")"
  fi
  chmod 600 "$state/beta.status"
  grep -F "$state/beta.status" "$dir/err" >/dev/null \
    || fail "full reader failure did not name the unreadable log: $(cat "$dir/err")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --open-decisions > "$dir/full" || fail "full reader failed once every log was readable"
  grep -Fx 'beta [key=hidden] needs-decision: Do not lose this one.' "$dir/full" >/dev/null \
    || fail "full reader lost the decision from the restored log"
  pass "the full reader fails and names a status log it cannot read instead of omitting its decisions"
}

test_fold_read_failure_leaves_the_count_unknown() {
  local dir state reader
  dir=$(make_case fold-read-failure)
  state="$dir/state"
  reader="$dir/fold-only-failing-reader"
  printf 'needs-decision [key=one]: Choose the first.\n' > "$state/task.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail "bootstrap drain failed"
  printf 'needs-decision [key=two]: Choose the second.\n' >> "$state/task.status"
  # Every other presentation read succeeds; only the open-decisions fold's own
  # read fails, which its cursor's .read.<pid> scratch sibling identifies.
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
for scratch in "${1%/*}"/.*.open-decisions-cursor.read.*; do
  [ -e "$scratch" ] && exit 1
done
exec perl -e 'open my $f, "<", $ARGV[0] or exit 1; seek $f, $ARGV[1], 0 or exit 1; defined(read $f, my $b, $ARGV[2]) or exit 1; print $b or exit 1' "$1" "$2" "$3"
SH
  chmod +x "$reader"
  append_wake "$state" check fixture 'Handle this separately.' || fail "could not queue fixture"
  cp "$state/.wake-queue" "$dir/queue-before"
  FM_STATUS_SPAN_READER="$reader" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" \
    || fail "drain failed under a fold read failure"
  grep -E '^WAKE_ACK_REQUIRED: .*open-decisions=unknown ' "$dir/err" >/dev/null \
    || fail "a failed fold read produced a counted acknowledgement: $(grep WAKE_ACK_REQUIRED "$dir/err")"
  cmp -s "$dir/queue-before" "$state/.wake-queue" || fail "the failed fold read consumed the queued wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail "drain failed after the fold read recovered"
  grep -E '^WAKE_ACK_REQUIRED: .*open-decisions=2 ' "$dir/err" >/dev/null \
    || fail "the recovered fold did not count both open decisions: $(grep WAKE_ACK_REQUIRED "$dir/err")"
  pass "a failed open-decisions fold read leaves the acknowledgement count unknown"
}

test_full_reader_preserves_all_decisions_without_consuming_wakes
test_full_reader_refuses_an_unreadable_status_log
test_empty_queue_recovery_counts_all_decisions
test_count_distinguishes_empty_from_failed_read
test_fold_read_failure_leaves_the_count_unknown
test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
