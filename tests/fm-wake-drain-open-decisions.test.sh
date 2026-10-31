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

make_fake_tasks_axi_ready() {
  local fakebin=$1
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  '--version ') echo 'tasks-axi 0.2.6' ;;
  'update --help')
    if [ "${FM_FAKE_TASKS_AXI_STALL_UPDATE:-0}" = 1 ]; then
      printf 'update-probe-started\n' >> "$FM_FAKE_TASKS_AXI_LOG"
      sleep 5
    fi
    echo '--archive-body'
    ;;
  'mv --help') echo '[<id>...]' ;;
  'ready '*|ready)
    if [ "${FM_FAKE_TASKS_AXI_EMPTY:-0}" = 1 ]; then
      printf 'ready[0]{id,since}:\nHelp for ready tasks-axi output\n'
    else
      printf 'ready[1]{id,since}:\n  ready-task,2026-10-30\n'
    fi
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
}

run_drain_with_backlog() {
  local dir=$1 state=$2 out=$3
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$dir/home/config" FM_DATA_OVERRIDE="$dir/home/data" \
    PATH="$dir/fakebin:$PATH" "$DRAIN" > "$out"
}

test_ready_work_only_on_heartbeat() {
  local dir state out
  dir=$(make_case ready-work)
  state="$dir/state"
  mkdir -p "$dir/home/config" "$dir/home/data"
  : > "$dir/home/.tasks.toml"
  printf '# backlog\n' > "$dir/home/data/backlog.md"
  make_fake_tasks_axi_ready "$dir/fakebin"
  append_wake "$state" heartbeat '' 'scheduled review' || fail "queueing heartbeat failed"
  out="$dir/heartbeat.out"
  run_drain_with_backlog "$dir" "$state" "$out" || fail "heartbeat drain failed"
  grep -F 'READY WORK (queued and dispatchable now):' "$out" >/dev/null \
    || fail "heartbeat did not print READY WORK: $(cat "$out")"
  grep -F 'ready-task,2026-10-30' "$out" >/dev/null \
    || fail "READY WORK omitted its ready row and since date"

  dir=$(make_case ready-work-empty)
  state="$dir/state"
  mkdir -p "$dir/home/config" "$dir/home/data"
  : > "$dir/home/.tasks.toml"
  printf '# backlog\n' > "$dir/home/data/backlog.md"
  make_fake_tasks_axi_ready "$dir/fakebin"
  append_wake "$state" heartbeat '' 'scheduled review' || fail "queueing heartbeat failed"
  out="$dir/empty.out"
  FM_FAKE_TASKS_AXI_EMPTY=1 run_drain_with_backlog "$dir" "$state" "$out" \
    || fail "empty-ready heartbeat drain failed"
  if grep -F 'READY WORK' "$out" >/dev/null; then
    fail "heartbeat with no ready items printed READY WORK"
  fi

  dir=$(make_case ready-work-non-heartbeat)
  state="$dir/state"
  mkdir -p "$dir/home/config" "$dir/home/data"
  : > "$dir/home/.tasks.toml"
  printf '# backlog\n' > "$dir/home/data/backlog.md"
  make_fake_tasks_axi_ready "$dir/fakebin"
  append_wake "$state" signal task.status 'working: changed' || fail "queueing signal failed"
  out="$dir/non-heartbeat.out"
  run_drain_with_backlog "$dir" "$state" "$out" || fail "non-heartbeat drain failed"
  if grep -F 'READY WORK' "$out" >/dev/null; then
    fail "non-heartbeat drain printed READY WORK"
  fi
  pass "READY WORK is shown with its since date only when a heartbeat is drained"
}

test_large_drain_rows_reach_ready_lookup() {
  local dir state out i payload
  dir=$(make_case ready-work-large)
  state="$dir/state"
  mkdir -p "$dir/home/config" "$dir/home/data"
  : > "$dir/home/.tasks.toml"
  printf '# backlog\n' > "$dir/home/data/backlog.md"
  make_fake_tasks_axi_ready "$dir/fakebin"
  payload=$(printf '%0200d' 0)
  append_wake "$state" heartbeat '' 'scheduled review' || fail "queueing heartbeat failed"
  for ((i = 0; i < 700; i++)); do
    append_wake "$state" signal "large-$i" "$payload" || fail "queueing large row $i failed"
  done
  out="$dir/large.out"
  run_drain_with_backlog "$dir" "$state" "$out" || fail "large heartbeat drain failed"
  grep -F 'ready-task,2026-10-30' "$out" >/dev/null \
    || fail "large heartbeat rows prevented READY WORK output"
  awk -F '\t' '$3 == "signal" && $4 ~ /^large-[0-9]+$/ { bytes += length($0) + 1; rows++ }
    END { if (rows != 700 || bytes <= 131072) exit 1 }' "$out" \
    || fail "deduped RAW_ROWS did not contain 700 distinct rows exceeding 128 KiB"
  pass "more than 128 KiB of distinct drain rows reach the ready-work lookup"
}

test_stalled_backlog_gate_does_not_block_drain() {
  local dir state out probe_log
  dir=$(make_case ready-work-stalled-gate)
  state="$dir/state"
  mkdir -p "$dir/home/config" "$dir/home/data"
  : > "$dir/home/.tasks.toml"
  printf '# backlog\n' > "$dir/home/data/backlog.md"
  make_fake_tasks_axi_ready "$dir/fakebin"
  probe_log="$dir/tasks-axi.log"
  append_wake "$state" heartbeat '' 'scheduled review' || fail "queueing heartbeat failed"
  out="$dir/drain.out"
  FM_TASKS_AXI_TIMEOUT=1 FM_FAKE_TASKS_AXI_STALL_UPDATE=1 \
    FM_FAKE_TASKS_AXI_LOG="$probe_log" run_drain_with_backlog "$dir" "$state" "$out" \
    || fail "drain failed after the backlog gate probe stalled"
  grep -F 'update-probe-started' "$probe_log" >/dev/null \
    || fail "the backlog gate probe did not reach the intentional stall"
  grep -F 'heartbeat' "$out" >/dev/null \
    || fail "the drain did not present the heartbeat after the lookup timed out"
  if grep -F 'READY WORK' "$out" >/dev/null; then
    fail "a stalled backlog gate printed READY WORK"
  fi
  pass "a stalled backlog gate times out and the drain continues"
}

test_manual_backlog_suppresses_ready_work() {
  local dir state out
  dir=$(make_case ready-work-manual)
  state="$dir/state"
  mkdir -p "$dir/home/config" "$dir/home/data"
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  printf '# backlog\n' > "$dir/home/data/backlog.md"
  append_wake "$state" heartbeat '' 'scheduled review' || fail "queueing heartbeat failed"
  out="$dir/manual.out"
  run_drain_with_backlog "$dir" "$state" "$out" || fail "manual-backend drain failed"
  if grep -F 'READY WORK' "$out" >/dev/null; then
    fail "manual backlog backend printed READY WORK"
  fi
  pass "manual backlog homes do not print READY WORK"
}

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
test_ready_work_only_on_heartbeat
test_large_drain_rows_reach_ready_lookup
test_stalled_backlog_gate_does_not_block_drain
test_manual_backlog_suppresses_ready_work
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
