#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
#
# The status-line grammar cases at the end cover the two ways a keyed closure
# used to be swallowed in silence (an extra token before the key made the verb
# unreadable; a key token written after the colon filed the event under
# "default") plus the symmetric regression that a naive "first word wins" fix
# would introduce, and the STATUS LINE ANOMALIES section that must name every
# line the fold refuses or repairs.
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

# --- status line grammar ----------------------------------------------------

test_closure_carrying_another_token_before_the_key_closes() {
  local dir state out
  dir=$(make_case token-before-key)
  state="$dir/state"
  out="$dir/drain.out"
  # Form 1 of the incident: a correlation token sits between the verb and the
  # key, exactly as bin/fm-brief.sh tells a secondmate to write a correlated
  # reply. The verb used to read as "resolved corr=..." so the closure never
  # landed and the decision stayed open forever.
  printf 'needs-decision [key=png-sources-zip]: ship the zip or the loose files\n' > "$state/task-a.status"
  printf 'resolved corr=db5363a1b2c3d4e5 [key=png-sources-zip]: captain chose the zip\n' >> "$state/task-a.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a token-carrying closure"

  if grep -F 'png-sources-zip' "$out" | grep -F 'OPEN' >/dev/null; then
    fail "a closure carrying a correlation token left the decision open: $(cat "$out")"
  fi
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a closure carrying a correlation token left the decision open: $(cat "$out")"
  fi
  # The bracketed form bin/fm-secondmate-report.sh actually emits must work too.
  printf 'needs-decision [key=route]: pick the route\n' > "$state/task-b.status"
  printf 'resolved [corr=db5363a1b2c3d4e5] [key=route]: took the direct route\n' >> "$state/task-b.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a bracketed-token closure"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a closure carrying a bracketed correlation token left the decision open: $(cat "$out")"
  fi
  pass "a closure carrying another structured token before the key still closes"
}

test_prose_starting_with_a_verb_word_does_not_close() {
  local dir state out
  dir=$(make_case prose-close)
  state="$dir/state"
  out="$dir/drain.out"
  # The symmetric regression a naive "take the first word" fix would open: an
  # ordinary sentence that happens to start with the resolution verb must never
  # close a key it did not claim to close, because a wrongly closed decision
  # disappears with no review at all.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task-c.status"
  printf 'resolved the conflict by hand [key=api-shape] came up: still undecided\n' >> "$state/task-c.status"
  printf 'needs-decision: which database\n' > "$state/task-d.status"
  printf 'resolved the merge conflict by hand: no decision was made here\n' >> "$state/task-d.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a prose line"

  grep -F 'task-c' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "prose beginning with the resolution verb wrongly closed a keyed decision"
  grep -F 'task-d' "$out" | grep -F 'which database' >/dev/null \
    || fail "prose beginning with the resolution verb wrongly closed the default decision"
  grep -F 'STATUS LINE ANOMALIES' "$out" >/dev/null \
    || fail "an out-of-grammar line was refused silently instead of being reported"
  grep -F 'NOT APPLIED' "$out" | grep -F 'resolved the merge conflict by hand' >/dev/null \
    || fail "the refused prose line was not named in the anomaly section"
  pass "prose beginning with a verb word never closes, and its refusal is reported"
}

test_key_token_after_the_colon_is_honored_and_reported() {
  local dir state out
  dir=$(make_case misplaced-key)
  state="$dir/state"
  out="$dir/drain.out"
  # Form 2, the nastier one: the OPENING line put the key token after the colon,
  # so it used to be filed under "default" while a later, perfectly written
  # closure closed a key nothing had opened - and "default" stayed open forever.
  printf 'needs-decision: [key=insert-ask-user] no-mistakes review parked\n' > "$state/task-e.status"
  printf 'resolved [key=insert-ask-user]: captain decided FIX on both findings\n' >> "$state/task-e.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a misplaced key token"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a key token after the colon was filed under default and left it open: $(cat "$out")"
  fi
  grep -F 'STATUS LINE ANOMALIES' "$out" >/dev/null \
    || fail "the misplaced key token was repaired silently instead of being reported"
  grep -F 'applied to [key=insert-ask-user]' "$out" >/dev/null \
    || fail "the anomaly section did not name the honored key or the writer to fix"
  pass "a key token after the colon is honored, never filed under default, and reported"
}

test_close_of_a_never_opened_key_is_reported() {
  local dir state out
  dir=$(make_case unmatched-close)
  state="$dir/state"
  out="$dir/drain.out"
  # The signal that was previously lost entirely: this is the direct, same-day
  # symptom of an opening line that got misfiled under another key.
  printf 'working: under way\n' > "$state/task-f.status"
  printf 'resolved [key=never-opened]: closing something\n' >> "$state/task-f.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an unmatched closure"

  grep -F 'STATUS LINE ANOMALIES' "$out" >/dev/null \
    || fail "a closure matching no open key produced no anomaly section"
  grep -F 'closes [key=never-opened], which was never opened' "$out" >/dev/null \
    || fail "the unmatched closure was not named in the anomaly section"
  pass "a closure matching no open key is reported, not ignored"
}

test_activity_closure_from_an_earlier_drain_is_not_reported() {
  local dir state out
  dir=$(make_case activity-close)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working [key=phase]: implementation under way\n' > "$state/task-phase.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain failed on an open work phase"
  [ ! -s "$out" ] || fail "opening a work phase produced drain output: $(cat "$out")"

  printf 'resolved [key=phase]: implementation complete\n' >> "$state/task-phase.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed on a work phase closure"
  [ ! -s "$out" ] \
    || fail "a closure owned by a work phase from an earlier drain produced an anomaly: $(cat "$out")"
  pass "a work phase opened in an earlier drain owns its later closure"
}

test_lifecycle_line_without_a_colon_is_refused_and_reported() {
  local dir state out
  dir=$(make_case no-colon)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=x]: pick one\nresolved [key=x]\n' > "$state/task-no-colon.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a no-colon lifecycle line"

  grep -F 'task-no-colon' "$out" | grep -F '[key=x]' | grep -F 'pick one' >/dev/null \
    || fail "a no-colon lifecycle line silently closed its decision"
  grep -F 'NOT APPLIED' "$out" | grep -F 'resolved [key=x]' >/dev/null \
    || fail "a no-colon lifecycle line was refused silently"
  pass "a no-colon lifecycle line is refused and reported"
}

test_legacy_cursor_is_refolded_once_under_current_semantics() {
  local dir state out probe status cursor size ident
  dir=$(make_case cursor-version)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/read-probe"
  status="$state/task-cursor.status"
  cursor="$state/.task-cursor.open-decisions-cursor"
  cat > "$status" <<'EOF'
needs-decision: [key=insert-ask-user] review parked
resolved [key=insert-ask-user]: captain decided
EOF
  size=$(LC_ALL=C wc -c < "$status"); size=${size//[[:space:]]/}
  if [ "$(uname -s)" = Darwin ]; then
    ident=$(LC_ALL=C stat -f '%d:%i' "$status")
  else
    ident=$(LC_ALL=C stat -c '%d:%i' "$status")
  fi
  printf 'offset=%s\nident=%s\ndefault\tneeds-decision\t[key=insert-ask-user] review parked' \
    "$size" "$ident" > "$cursor"

  FM_OPEN_DECISIONS_READ_PROBE="$probe" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed while migrating a legacy cursor"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null \
    && fail "a legacy cursor kept its stale open set after migration: $(cat "$out")"
  grep -F 'applied to [key=insert-ask-user]' "$out" >/dev/null \
    || fail "legacy cursor migration did not re-report the status history"
  [ "$(cut -f2 "$probe")" = "$size" ] \
    || fail "legacy cursor migration did not refold from byte zero: $(cat "$probe")"

  : > "$out"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "second drain failed after migrating a legacy cursor"
  [ ! -s "$out" ] || fail "a migrated cursor re-reported history: $(cat "$out")"
  [ "$(wc -l < "$probe" | tr -d '[:space:]')" = 1 ] \
    || fail "a migrated cursor refolded its history more than once: $(cat "$probe")"
  pass "a legacy cursor is fully refolded and re-reported exactly once"
}

test_terminal_done_still_does_not_close_a_key() {
  local dir state out
  dir=$(make_case done-does-not-close)
  state="$dir/state"
  out="$dir/drain.out"
  # Deliberate, load-bearing behavior: a terminal line never cancels an open
  # captain decision, even when it carries that decision's own key.
  printf 'needs-decision [key=x]: pick one\n' > "$state/task-g.status"
  printf 'done [key=x]: shipped anyway\n' >> "$state/task-g.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a keyed terminal line"

  grep -F 'task-g' "$out" | grep -F '[key=x]' | grep -F 'pick one' >/dev/null \
    || fail "a keyed done: line closed an open captain decision"
  pass "done [key=x] still does not close the keyed decision"
}

test_clean_grammar_prints_no_anomaly_section() {
  local dir state out
  dir=$(make_case clean-grammar)
  state="$dir/state"
  out="$dir/drain.out"
  cat > "$state/task-h.status" <<'EOF'
needs-decision [key=a]: pick one
resolved [key=a]: picked
working [corr=db5363a1b2c3d4e5]: routed work under way
done: shipped
EOF

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a clean status log"

  [ ! -s "$out" ] || fail "a status log that follows the grammar was not silent: $(cat "$out")"
  pass "a status log that follows the grammar prints neither section"
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
test_closure_carrying_another_token_before_the_key_closes
test_prose_starting_with_a_verb_word_does_not_close
test_key_token_after_the_colon_is_honored_and_reported
test_close_of_a_never_opened_key_is_reported
test_activity_closure_from_an_earlier_drain_is_not_reported
test_lifecycle_line_without_a_colon_is_refused_and_reported
test_legacy_cursor_is_refolded_once_under_current_semantics
test_terminal_done_still_does_not_close_a_key
test_clean_grammar_prints_no_anomaly_section
