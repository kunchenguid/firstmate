#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
# They also pin the printed-key/answerable-key agreement: the section renders
# the key the fold decided (including the "default" bucket) and the exact
# command that closes it, so it can never advertise a key fm-send would refuse.
# The agreement is proven end to end - drain output executed through the real
# fm-send - in tests/fm-send-resolve-key.test.sh.
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
  grep -F "close it: bin/fm-send.sh task1 --resolve-key api-shape '<answer>'" "$out" >/dev/null \
    || fail "open section is missing the decision's own answerer-closes command"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

# The section used to hide the key whenever the fold landed on "default", so a
# decision whose NOTE still contained a "[key=...]" token advertised that token
# as its key - and the generic hint invited answering with it. fm-send then
# refused the key the listing had just shown. Every entry must now render the
# key the fold decided and carry the command that closes exactly that key.
test_printed_key_and_command_agree_for_every_key_form() {
  local dir state out line prev
  dir=$(make_case key-command-agreement)
  state="$dir/state"
  out="$dir/drain.out"
  # 1. The inline-marker form the generated briefs tell workers to write.
  printf 'needs-decision: [key=totals-pool-separation] display-only or engine bug\n' \
    > "$state/inline.status"
  # 2. The no-marker fallback, which folds to the shared "default" bucket.
  printf 'needs-decision: which banner color\n' > "$state/plain.status"
  # 3. The trap: no stated key, but key-shaped tokens inside the note text.
  printf 'needs-decision: pick a [key=red] or [key=blue] theme\n' > "$state/prose.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on mixed key forms"

  grep -F 'inline [key=totals-pool-separation] needs-decision: display-only or engine bug' "$out" >/dev/null \
    || fail "the inline-marker decision did not list under its stated key: $(cat "$out")"
  grep -F "close it: bin/fm-send.sh inline --resolve-key totals-pool-separation '<answer>'" "$out" >/dev/null \
    || fail "the inline-marker decision's close command did not use its stated key: $(cat "$out")"

  grep -F 'plain [key=default] needs-decision: which banner color' "$out" >/dev/null \
    || fail "the keyless decision did not list its actual (default) key: $(cat "$out")"
  grep -F "close it: bin/fm-send.sh plain --resolve-key default '<answer>'" "$out" >/dev/null \
    || fail "the keyless decision's close command did not name the default key: $(cat "$out")"

  grep -F 'prose [key=default] needs-decision: pick a [key=red] or [key=blue] theme' "$out" >/dev/null \
    || fail "a note-only key mention changed how the decision listed: $(cat "$out")"
  grep -F "close it: bin/fm-send.sh prose --resolve-key default '<answer>'" "$out" >/dev/null \
    || fail "the close command followed prose in the note instead of the folded key: $(cat "$out")"
  if grep -F -- "--resolve-key red" "$out" >/dev/null || grep -F -- "--resolve-key blue" "$out" >/dev/null; then
    fail "the section suggested closing with a key from note prose: $(cat "$out")"
  fi

  # Nothing is listed without its own command: every decision line is followed
  # by a close command, so a reader never has to infer the key from the note.
  prev=''
  while IFS= read -r line; do
    case "$prev" in
      ''|'OPEN DECISIONS'*|'  close it: '*) ;;
      *)
        case "$line" in
          '  close it: bin/fm-send.sh '*) ;;
          *) fail "a listed decision had no close command under it: $prev" ;;
        esac
        ;;
    esac
    prev=$line
  done <<EOF
$(cat "$out")
EOF
  case "$prev" in
    'OPEN DECISIONS'*|'  close it: '*) ;;
    *) fail "the section ended on a decision with no close command under it: $prev" ;;
  esac
  pass "every listed decision prints the folded key and the exact command that closes it"
}

# The close command is printed to be RUN, so an id that is not a plain task
# slug - a stray or hand-made status file - must not be pasted into one.
test_unslug_task_id_gets_a_pointer_not_a_command() {
  local dir state out
  dir=$(make_case unslug-id)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=real]: a normal task\n' > "$state/normal.status"
  printf 'needs-decision [key=odd]: a hand-made status file\n' > "$state/we ird; echo pwned.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with an odd status filename"

  grep -F "close it: bin/fm-send.sh normal --resolve-key real '<answer>'" "$out" >/dev/null \
    || fail "the ordinary task lost its close command: $(cat "$out")"
  grep -F 'a hand-made status file' "$out" >/dev/null \
    || fail "the odd-id decision was dropped instead of listed: $(cat "$out")"
  if grep -F 'bin/fm-send.sh we ird' "$out" >/dev/null; then
    fail "an unslug task id was pasted into a runnable command: $(cat "$out")"
  fi
  grep -F 'its id is not a plain slug' "$out" >/dev/null \
    || fail "the odd-id decision did not explain why it has no command: $(cat "$out")"
  pass "a task id outside the plain-slug charset gets a pointer instead of a runnable command"
}

# A leading dash is a legal filename character, but fm-send treats `-foo` as a
# flag, so the advertised close command would send nothing and leave the
# decision open. Treat it like any other unpasteable id.
test_leading_dash_task_id_gets_a_pointer_not_a_command() {
  local dir state out
  dir=$(make_case leading-dash-id)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=real]: a normal task\n' > "$state/normal.status"
  printf 'needs-decision [key=dash]: a leading-dash task id\n' > "$state/-foo.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a leading-dash status filename"

  grep -F "close it: bin/fm-send.sh normal --resolve-key real '<answer>'" "$out" >/dev/null \
    || fail "the ordinary task lost its close command: $(cat "$out")"
  grep -F 'a leading-dash task id' "$out" >/dev/null \
    || fail "the leading-dash decision was dropped instead of listed: $(cat "$out")"
  if grep -F 'close it: bin/fm-send.sh -foo' "$out" >/dev/null; then
    fail "a leading-dash task id was pasted into a runnable command: $(cat "$out")"
  fi
  grep -F 'its id is not a plain slug' "$out" >/dev/null \
    || fail "the leading-dash decision did not explain why it has no command: $(cat "$out")"
  pass "a leading-dash task id gets a pointer instead of a runnable command"
}

# The section's global byte budget now pays for each entry's close command as
# well as its note, and the two are charged together on purpose: at the cap
# boundary an entry must be dropped whole rather than listed with no way to
# close it.
test_global_cap_never_lists_a_decision_without_its_command() {
  local dir state out i decisions commands
  dir=$(make_case global-cap)
  state="$dir/state"
  out="$dir/drain.out"
  i=0
  while [ "$i" -lt 40 ]; do
    {
      printf 'needs-decision [key=k%02d]: decision %02d needs a call' "$i" "$i"
      awk 'BEGIN { while (n++ < 12) printf " and-then-some" }'
      printf '\n'
    } > "$state/task$(printf '%02d' "$i").status"
    i=$((i + 1))
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a flooded decision set"

  decisions=$(grep -c ' needs-decision: ' "$out")
  commands=$(grep -c '  close it: bin/fm-send.sh ' "$out")
  [ "$decisions" -eq "$commands" ] \
    || fail "$decisions decisions listed but $commands close commands printed"
  [ "$decisions" -gt 0 ] || fail "the flooded set listed nothing at all"
  [ "$decisions" -lt 40 ] || fail "the flood was not large enough to reach the byte cap"
  grep -E '^OPEN DECISIONS: [0-9]+ more omitted \(byte cap\)$' "$out" >/dev/null \
    || fail "entries were dropped without the omission disclosure: $(cat "$out")"
  pass "at the global byte cap an entry is dropped whole, never listed without its close command"
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

  line=$(grep -F 'task-long [key=' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"
  # The note is what gets cut; its close command must survive whole, because a
  # truncated command is a command that does not run.
  grep -F "close it: bin/fm-send.sh task-long --resolve-key api-shape '<answer>'" "$out" >/dev/null \
    || fail "the close command was cut along with its over-long note: $(cat "$out")"

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
test_printed_key_and_command_agree_for_every_key_form
test_over_long_decision_note_is_capped_with_a_marker
test_unslug_task_id_gets_a_pointer_not_a_command
test_leading_dash_task_id_gets_a_pointer_not_a_command
test_global_cap_never_lists_a_decision_without_its_command
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
