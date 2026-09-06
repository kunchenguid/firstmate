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

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

# Progress that arrives while a keyed decision is still open is presented AS
# progress under that open key, so activity is never mistaken for an answer.
# The suffix comes from the same presentation snapshot the section already
# holds; it never reopens a resolved key and never gates anything.
test_open_decision_row_matches_base_except_its_own_newer_progress() {
  local dir state_base state_head basedrain
  dir=$(make_case latest-progress-queued-base-head)
  state_base="$dir/state-base"
  state_head="$dir/state-head"
  basedrain=$(base_wake_drain_bin "$dir/basebin") || fail "could not build a base-pinned fm-wake-drain.sh"

  mkdir -p "$state_base" "$state_head"
  printf 'needs-decision [key=k1]: pick REST or RPC\n' > "$state_base/t1.status"
  printf 'working: still going\n' >> "$state_base/t1.status"
  append_wake "$state_base" signal t1.status "working: still going" \
    || fail "queueing t1's own wake failed at base"
  printf 'needs-decision [key=k1]: pick REST or RPC\n' > "$state_head/t1.status"
  printf 'working: still going\n' >> "$state_head/t1.status"
  append_wake "$state_head" signal t1.status "working: still going" \
    || fail "queueing t1's own wake failed at head"

  FM_STATE_OVERRIDE="$state_base" "$basedrain" > "$dir/base.out" || fail "base first drain failed"
  FM_STATE_OVERRIDE="$state_head" "$DRAIN" > "$dir/head.out" || fail "head first drain failed"

  # Every line outside the open-decision row's own text - the queued
  # annotation included - stays byte-identical to base. The raw queued
  # row's own leading epoch column legitimately differs between the two
  # separately-timed drain invocations, so it is normalized out before
  # comparing; every other column (sequence, kind, task, payload) is not.
  rg -v -- '^t1 \[key=k1\]' "$dir/base.out" | sed -E 's/^[0-9]+(\t)/TS\1/' > "$dir/base.filtered"
  rg -v -- '^t1 \[key=k1\]' "$dir/head.out" | sed -E 's/^[0-9]+(\t)/TS\1/' > "$dir/head.filtered"
  diff "$dir/base.filtered" "$dir/head.filtered" >/dev/null \
    || fail "output outside the open-decision row itself differs from base: $(diff "$dir/base.filtered" "$dir/head.filtered")"
  rg -qF -- 't1 [key=k1] needs-decision: pick REST or RPC' "$dir/base.out" \
    || fail "test setup error: base output is missing the expected row"
  rg -qF -- 't1 [key=k1] needs-decision: pick REST or RPC · latest: working: still going' "$dir/head.out" \
    || fail "head's open row did not carry the expected latest-progress suffix"
  rg -qF -- "$(printf '\tsignal\tt1.status\t')" "$dir/head.out" \
    || fail "t1's own queued annotation line went missing at head"

  # The presentation manifest (whose "task<TAB>ident<TAB>presented<TAB>backstop"
  # row carries the backstop receipt column, fm-classify-lib.sh:986-1009) and
  # the legacy per-task open-decisions cursor are the only durable artifacts
  # this drain writes; both must come out identical to base on this
  # manifest-less first run, field for field except the device/inode-derived
  # ident, which two separate state directories can never share.
  cut -f1,3,4 "$state_base/.status-presentation-cursor" 2>/dev/null > "$dir/base.manifest"
  cut -f1,3,4 "$state_head/.status-presentation-cursor" 2>/dev/null > "$dir/head.manifest"
  diff "$dir/base.manifest" "$dir/head.manifest" >/dev/null \
    || fail "the presentation manifest (backstop receipt column included) differs from base on the first drain: $(diff "$dir/base.manifest" "$dir/head.manifest")"
  rg -v -- '^ident=' "$state_base/.t1.open-decisions-cursor" 2>/dev/null > "$dir/base.cursor"
  rg -v -- '^ident=' "$state_head/.t1.open-decisions-cursor" 2>/dev/null > "$dir/head.cursor"
  diff "$dir/base.cursor" "$dir/head.cursor" >/dev/null \
    || fail "the legacy open-decisions cursor differs from base on the first drain: $(diff "$dir/base.cursor" "$dir/head.cursor")"

  pass "on the first manifest-less drain, only the open-decision row's own text differs from base; the queued annotation, presentation manifest, backstop receipt column, and legacy cursor are byte-identical"
}

test_open_decision_row_shows_latest_terminal_event_on_empty_queue() {
  local dir state out
  dir=$(make_case latest-progress-empty-queue)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=k1]: pick REST or RPC\n' > "$state/t1.status"
  printf 'done: finished\n' >> "$state/t1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  rg -qF -- 't1 [key=k1] needs-decision: pick REST or RPC · latest: done: finished' "$out" \
    || fail "the open row did not carry the task's latest terminal event on the empty-queue path: $(cat "$out")"
  rg -qF -- 'OPEN DECISIONS: close one by answering it' "$out" \
    || fail "k1 stopped reporting as open after gaining a later done: event"
  pass "an open decision stays open and shows the task's latest done event even on the empty-queue fast path"
}

test_open_decisions_on_one_task_share_one_latest_lookup() {
  local dir state out
  dir=$(make_case latest-progress-shared-lookup)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=k1]: pick REST or RPC\n'
    printf 'needs-decision [key=k2]: pick sync or async\n'
    printf 'working: still going\n'
  } > "$state/t1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with two open keys on one task"

  rg -qF -- 't1 [key=k1] needs-decision: pick REST or RPC · latest: working: still going' "$out" \
    || fail "k1's row is missing the shared latest-progress suffix: $(cat "$out")"
  rg -qF -- 't1 [key=k2] needs-decision: pick sync or async · latest: working: still going' "$out" \
    || fail "k2's row is missing the shared latest-progress suffix: $(cat "$out")"
  pass "two open keys on one task both carry the same task-level latest-progress lookup"
}

test_over_long_latest_progress_note_is_capped_with_a_marker() {
  local dir state out line
  dir=$(make_case latest-progress-cap)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=k1]: pick REST or RPC\n'
    printf 'working: '
    awk 'BEGIN { while (i++ < 200) printf "and-then-some " }'
    printf '\n'
  } > "$state/t1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long latest-progress note"

  line=$(rg -F -- 't1' "$out")
  case "$line" in
    't1 [key=k1] needs-decision: pick REST or RPC'*'[truncated]') : ;;
    *) fail "an over-long latest-progress suffix was not capped with its lede intact: $line" ;;
  esac
  [ "${#line}" -le 219 ] \
    || fail "a capped decision item with a latest-progress suffix ran ${#line} characters past its per-item budget"
  pass "a decision row whose latest-progress suffix would overflow the item cap is still cut with the shared truncation marker"
}

test_latest_progress_suffix_writes_no_durable_state() {
  local dir state out cursor manifest before_cursor before_manifest after_cursor after_manifest
  dir=$(make_case latest-progress-no-durable-write)
  state="$dir/state"
  out="$dir/drain.out"
  cursor="$state/.t1.open-decisions-cursor"
  manifest="$state/.status-presentation-cursor"

  printf 'needs-decision [key=k1]: pick REST or RPC\n' > "$state/t1.status"
  printf 'working: still going\n' >> "$state/t1.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "bootstrap drain failed"
  [ -s "$cursor" ] || fail "no open-decisions cursor was persisted"
  [ -s "$manifest" ] || fail "no presentation manifest was persisted"
  before_cursor=$(LC_ALL=C cksum "$cursor")
  before_manifest=$(LC_ALL=C cksum "$manifest")

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  rg -qF -- '· latest: working: still going' "$out" \
    || fail "the latest-progress suffix did not reappear on the second drain: $(cat "$out")"
  after_cursor=$(LC_ALL=C cksum "$cursor")
  after_manifest=$(LC_ALL=C cksum "$manifest")
  [ "$after_cursor" = "$before_cursor" ] \
    || fail "presenting the latest-progress suffix advanced or rewrote the open-decisions cursor"
  [ "$after_manifest" = "$before_manifest" ] \
    || fail "presenting the latest-progress suffix advanced or rewrote the presentation manifest"
  pass "the latest-progress suffix writes no durable cursor, manifest, or receipt"
}

test_open_decisions_skipped_when_presentation_locked() {
  local dir state out err holder
  dir=$(make_case latest-progress-presentation-locked)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  printf 'needs-decision [key=k1]: pick REST or RPC\n' > "$state/t1.status"
  printf 'working: still going\n' >> "$state/t1.status"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.status-presentation-lock" "$dir/presentation.ready" &
  holder=$!
  local i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/presentation.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/presentation.ready" ] \
    || { kill "$holder" 2>/dev/null || true; fail "presentation holder never acquired its lock"; }

  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$DRAIN" > "$out" 2> "$err" \
    || { kill "$holder" 2>/dev/null || true; fail "drain failed while the presentation lock was held"; }
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  if rg -qF -- 'OPEN DECISIONS' "$out"; then
    fail "a contended presentation lock still printed OPEN DECISIONS content: $(cat "$out")"
  fi
  rg -qF -- 'STATUS PRESENTATION SKIPPED' "$out" \
    || fail "a contended presentation lock did not report the skip advisory"
  [ ! -e "$state/.t1.open-decisions-cursor" ] \
    || fail "a skipped presentation still persisted an open-decisions cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain after lock release failed"
  rg -qF -- 't1 [key=k1] needs-decision: pick REST or RPC · latest: working: still going' "$out" \
    || fail "the open row did not recover its latest-progress suffix once the lock cleared: $(cat "$out")"
  pass "a contended presentation lock skips OPEN DECISIONS (and its latest-progress lookup) exactly like base, and recovers once cleared"
}

# Cost bound: the latest-event lookup runs at most once per open TASK per
# drain, reused across every open key on that task, and never touches the
# open-decisions fold's own bounded read. Isolated via two
# structurally matched tasks - one still open, one already resolved - so any
# shared-reader traffic from other presentation sections (unread status,
# outcome backstop) is identical between them and cancels out of the delta.
test_latest_event_lookup_runs_once_per_open_task_never_per_row() {
  local dir state out reader probe span_open span_resolved
  dir=$(make_case latest-progress-lookup-cost)
  state="$dir/state"
  out="$dir/drain.out"
  reader="$dir/span-reader"
  probe="$dir/open-decisions-probe.tsv"

  {
    printf 'needs-decision [key=k1]: pick REST or RPC\n'
    printf 'needs-decision [key=k2]: pick sync or async\n'
    printf 'working: still going\n'
  } > "$state/topen.status"
  {
    printf 'needs-decision [key=k1]: pick REST or RPC\n'
    printf 'needs-decision [key=k2]: pick sync or async\n'
    printf 'resolved [key=k1]: went with REST\n'
    printf 'resolved [key=k2]: went with sync\n'
    printf 'working: still going\n'
  } > "$state/tresolved.status"

  # Prime cursors/receipts through two ordinary drains so the measured drain's
  # only reads are this section's own (the fold makes no further reads once
  # caught up; see status_open_decisions_incremental's offset<size guard).
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first priming drain failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second priming drain failed"

  cat > "$reader" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$1" >> "$dir/span-reads.log"
tail -c +"\$((\$2 + 1))" "\$1" | head -c "\$3"
SH
  chmod +x "$reader"
  : > "$dir/span-reads.log"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" FM_OPEN_DECISIONS_READ_PROBE="$probe" \
    "$DRAIN" > "$out" || fail "measured drain failed"
  rg -qF -- 'topen [key=k1]' "$out" || fail "topen's open decision vanished on the measured drain"

  [ ! -s "$probe" ] \
    || fail "the open-decisions fold read bytes on an already-caught-up drain (should stay bounded to zero): $(cat "$probe")"

  span_open=$(rg -c -F -- "$state/topen.status" "$dir/span-reads.log")
  span_resolved=$(rg -c -F -- "$state/tresolved.status" "$dir/span-reads.log")
  [ "$((span_open - span_resolved))" -eq 1 ] \
    || fail "expected exactly one extra latest-event lookup for the still-open task (open=$span_open resolved=$span_resolved), reused across its two open keys"
  pass "the latest-event lookup costs exactly one read per open task, reused across every open key on it, with no extra fold reads"
}

# Direct unit tests of the pure row composer (_fm_open_decision_row_text),
# sourced by extracting its own declaration out of bin/fm-wake-drain.sh - that
# file is an executable with real top-level side effects, not a library, so
# this is the way to reach the real function without running any of them.
load_open_decision_row_composer() {
  eval "$(sed -n '/^_fm_open_decision_row_text() {/,/^}/p' "$ROOT/bin/fm-wake-drain.sh")"
}

test_row_composer_no_event_leaves_the_row_unchanged() {
  load_open_decision_row_composer
  local out
  out=$(_fm_open_decision_row_text t1 k1 needs-decision 'pick REST or RPC' '' '')
  [ "$out" = 't1 [key=k1] needs-decision: pick REST or RPC' ] \
    || fail "an unknown/absent latest event changed the row: $out"
  pass "the row composer leaves the row unchanged with no known latest event"
}

test_row_composer_same_verb_adds_no_suffix() {
  load_open_decision_row_composer
  local out
  out=$(_fm_open_decision_row_text t1 k1 blocked 'waiting on infra' blocked 'waiting on infra')
  [ "$out" = 't1 [key=k1] blocked: waiting on infra' ] \
    || fail "a latest event with the same verb as the row wrongly added a suffix: $out"
  pass "the row composer adds no suffix when the latest event's verb matches the row's own verb"
}

test_row_composer_appends_an_accepted_later_event() {
  load_open_decision_row_composer
  local out
  out=$(_fm_open_decision_row_text t1 k1 needs-decision 'pick REST or RPC' working 'still going')
  [ "$out" = 't1 [key=k1] needs-decision: pick REST or RPC · latest: working: still going' ] \
    || fail "the row composer did not append an accepted differing-verb latest event: $out"
  pass "the row composer appends an accepted later event whose verb differs from the row's own"
}

test_row_composer_output_still_hits_the_existing_item_cap() {
  load_open_decision_row_composer
  # shellcheck source=bin/fm-line-cap-lib.sh
  . "$ROOT/bin/fm-line-cap-lib.sh"
  local out capped longnote
  longnote=$(awk 'BEGIN { while (i++ < 200) printf " and-then-some" }')
  out=$(_fm_open_decision_row_text t1 k1 needs-decision "pick REST or RPC$longnote" '' '')
  fm_cap_line_var "$out" 219
  capped=$FM_LINE_CAP_LINE
  case "$capped" in
    't1 [key=k1] needs-decision: pick REST or RPC'*'[truncated]') : ;;
    *) fail "the row composer's output did not cap the same way through the shared line-cap helper: $capped" ;;
  esac
  [ "${#capped}" -le 219 ] || fail "capped composer output ran ${#capped} characters past the item budget"
  pass "the row composer's output still hits the existing shared per-item cap unchanged"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
test_row_composer_no_event_leaves_the_row_unchanged
test_row_composer_same_verb_adds_no_suffix
test_row_composer_appends_an_accepted_later_event
test_row_composer_output_still_hits_the_existing_item_cap
test_open_decision_row_matches_base_except_its_own_newer_progress
test_open_decision_row_shows_latest_terminal_event_on_empty_queue
test_open_decisions_on_one_task_share_one_latest_lookup
test_over_long_latest_progress_note_is_capped_with_a_marker
test_latest_progress_suffix_writes_no_durable_state
test_open_decisions_skipped_when_presentation_locked
test_latest_event_lookup_runs_once_per_open_task_never_per_row
