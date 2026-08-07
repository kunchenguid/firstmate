#!/usr/bin/env bash
# Behavior tests for bin/fm-context-briefs.sh, the generator that owns the two
# derived sections of the captain's context briefs.
#
# The load-bearing guarantee is that hand-written prose sitting immediately
# either side of a generated block survives regeneration byte for byte. That
# assertion is proved to have teeth first: the same check is run against a naive
# heading-anchored regenerator built inside the fixture, and the test fails if
# that naive implementation passes.
#
# The second guarantee proved the same way is that a source which could not be
# read never renders as a source that was read and found empty. The control case
# runs first, with a readable and genuinely empty backlog, so the assertion is
# known to distinguish the two rather than passing whatever it is given.
#
# The rest covers marker refusal (missing, duplicated, reversed, overlapping),
# marker installation (an empty section body, a half-marked brief, a refusal
# that must leave the file byte-identical), the derived content itself (deadline
# items first, clustering, plain wording for an empty section), the age stamp
# and the read-only narrative review line, unmapped repository reporting on both
# surfaces, and one end-to-end demonstration that a real lifecycle command
# refreshes the briefs on its own.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GEN="$ROOT/bin/fm-context-briefs.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-briefs)

# --- fixture ----------------------------------------------------------------

# A tasks-axi stub driven by $FAKE_TASKS, a file of
# "<id>|<state>|<repo>|<hold_until>|<created>|<title>" records. It answers the
# two read shapes the generator uses, plus the version and feature probes the
# shared backend decision in bin/fm-tasks-axi-lib.sh runs before any read.
# $FAKE_TASKS_AXI_VERSION drives that version, so a fixture can present a build
# this home refuses to read through.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
records=${FAKE_TASKS:-/dev/null}
[ -n "${FAKE_TASKS_LOG:-}" ] && printf '%s\n' "${1:-}" >> "$FAKE_TASKS_LOG"
[ -n "${FAKE_STDIN_EATER:-}" ] && read -r _ONE_LINE
# Only the backlog listing stalls, so the backend probes above it stay quick and
# a test can hold the generator open in the middle of a run.
if [ -n "${FAKE_TASKS_AXI_SLEEP:-}" ] && [ "${1:-}" = list ]; then
  sleep "$FAKE_TASKS_AXI_SLEEP"
fi
case "${1:-}" in
  --version)
    printf 'tasks-axi %s\n' "${FAKE_TASKS_AXI_VERSION:-0.2.4}"
    ;;
  update)
    printf '  --archive-body   rewrite the note recoverably\n'
    ;;
  mv)
    printf '  usage: tasks-axi mv [<id>...] <destination>\n'
    ;;
  list)
    printf 'count: 0\n'
    printf 'tasks[0]{id,state,kind,repo,title}:\n'
    while IFS='|' read -r id state repo until created title; do
      [ -n "$id" ] || continue
      printf '  %s,%s,captain,%s,%s\n' "$id" "$state" "$repo" "$title"
    done < "$records"
    ;;
  show)
    want=${2:-}
    while IFS='|' read -r id state repo until created title; do
      [ "$id" = "$want" ] || continue
      printf 'task:\n'
      printf '  id: %s\n' "$id"
      printf '  title: %s\n' "$title"
      printf '  state: %s\n' "$state"
      printf '  held: yes\n'
      printf '  hold_kind: captain\n'
      printf '  hold_until: %s\n' "$until"
      printf '  kind: captain\n'
      printf '  repo: %s\n' "$repo"
      printf '  created: %s\n' "$created"
      exit 0
    done < "$records"
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fb/tasks-axi"
  # fm-crew-state reaches for these, and a torn-down fixture reads unknown, which
  # is exactly the deterministic answer these tests want. They also record that
  # they ran when $FAKE_CALL_LOG is set, which is how a test observes whether a
  # command performed a current-state read at all.
# They also consume a line of stdin when $FAKE_STDIN_EATER is set, which is what
# any ordinary command that happens to read stdin does. No enumeration may lose a
# record to that.
  local tool
  for tool in no-mistakes tmux; do
    cat > "$fb/$tool" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_CALL_LOG:-}" ] && printf '%s\n' "${0##*/}" >> "$FAKE_CALL_LOG"
[ -n "${FAKE_STDIN_EATER:-}" ] && read -r _ONE_LINE
exit 0
SH
    chmod +x "$fb/$tool"
  done
  printf '%s\n' "$fb"
}

BRIEF_BODY='# Back office

A hand-written opening line that must never move.

*Current as at 7 August 2026, late afternoon.*

---

## Waiting on you
<!-- fm:brief:waiting-on-you:begin -->
stale content that the generator owns
<!-- fm:brief:waiting-on-you:end -->

The sentence directly after the first block.

---

## Where it stands

Narrative prose the generator must never touch.

---

## Running now
<!-- fm:brief:running-now:begin -->
stale content that the generator owns
<!-- fm:brief:running-now:end -->

The sentence directly after the second block.

---

## Where things live

- A pointer the generator must never touch.
'

# new_home <dir>: an FM_HOME with one context, one brief, and no live tasks.
new_home() {
  local home=$1
  mkdir -p "$home/data/briefs" "$home/config" "$home/state" "$home/projects"
  printf '%s' "$BRIEF_BODY" > "$home/data/briefs/back-office.md"
  cat > "$home/config/context-briefs.conf" <<'EOF'
# One line per context, named after its file in data/briefs/.
back-office: mldinvoicing, mld-bi
EOF
  printf '%s\n' "$home"
}

run_gen() {  # <home> [args...]: run the generator against <home>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$GEN" "$@"
}

# outside_blocks <file>: everything except the bytes strictly inside a generated
# block. This is the surface that must never change.
outside_blocks() {
  awk '
    /^<!-- fm:brief:(waiting-on-you|running-now):begin -->$/ { print; skip = 1; next }
    /^<!-- fm:brief:(waiting-on-you|running-now):end -->$/ { skip = 0 }
    !skip
  ' "$1"
}

# --- the guarantee, proved red first ----------------------------------------

# A naive regenerator of the kind this design exists to rule out: it anchors on
# the "## Waiting on you" heading and replaces everything up to the next rule.
# That is the implementation that silently eats the prose after a block.
test_naive_implementation_fails_the_prose_check() {
  local home before after
  home=$(new_home "$TMP_ROOT/naive")
  before="$TMP_ROOT/naive.before"
  after="$TMP_ROOT/naive.after"
  outside_blocks "$home/data/briefs/back-office.md" > "$before"

  awk '
    /^## Waiting on you$/ { print; print "regenerated"; skip = 1; next }
    skip && /^---$/ { skip = 0 }
    !skip
  ' "$home/data/briefs/back-office.md" > "$home/data/briefs/back-office.md.new"
  mv "$home/data/briefs/back-office.md.new" "$home/data/briefs/back-office.md"

  outside_blocks "$home/data/briefs/back-office.md" > "$after"
  if diff -q "$before" "$after" >/dev/null 2>&1; then
    fail "the prose check passes a naive heading-anchored rewrite, so it proves nothing"
  fi
  pass "the prose check fails a naive heading-anchored rewrite, so it has teeth"
}

test_hand_written_prose_survives_byte_for_byte() {
  local home fb before after out
  home=$(new_home "$TMP_ROOT/prose")
  fb=$(make_fakebin "$TMP_ROOT/prose")
  before="$TMP_ROOT/prose.before"
  after="$TMP_ROOT/prose.after"
  outside_blocks "$home/data/briefs/back-office.md" > "$before"

  cat > "$TMP_ROOT/prose/tasks" <<'EOF'
mld-bi-alpha-decision-one|queued|mld-bi|-|2026-08-01|Approve the first thing
mld-bi-alpha-decision-two|queued|mld-bi|-|2026-08-02|Approve the second thing
EOF
  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/prose/tasks" run_gen "$home" 2>&1)
  expect_code 0 "$?" "generate exit"
  assert_contains "$out" "updated" "generate reports the file it updated"

  outside_blocks "$home/data/briefs/back-office.md" > "$after"
  diff "$before" "$after" > "$TMP_ROOT/prose.diff" 2>&1 ||
    fail "hand-written prose changed:"$'\n'"$(cat "$TMP_ROOT/prose.diff")"

  assert_grep 'The sentence directly after the first block.' \
    "$home/data/briefs/back-office.md" "the sentence after the first block survived"
  assert_grep 'The sentence directly after the second block.' \
    "$home/data/briefs/back-office.md" "the sentence after the second block survived"
  assert_grep 'Approve the first thing' \
    "$home/data/briefs/back-office.md" "the derived section carries the decision"
  assert_no_grep 'stale content that the generator owns' \
    "$home/data/briefs/back-office.md" "the stale block content was replaced"
  pass "hand-written prose either side of both blocks is byte-identical after regeneration"
}

test_regeneration_is_idempotent_apart_from_the_stamp() {
  local home fb first second
  home=$(new_home "$TMP_ROOT/idem")
  fb=$(make_fakebin "$TMP_ROOT/idem")
  : > "$TMP_ROOT/idem/tasks"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/idem/tasks" run_gen "$home" >/dev/null 2>&1
  first="$TMP_ROOT/idem.first"
  second="$TMP_ROOT/idem.second"
  grep -v 'fm:brief:generated' "$home/data/briefs/back-office.md" > "$first"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/idem/tasks" run_gen "$home" >/dev/null 2>&1
  grep -v 'fm:brief:generated' "$home/data/briefs/back-office.md" > "$second"
  # The rendered "Generated ..." sentence carries a minute-precision clock, so
  # only the machine stamp is stripped and the human line is compared loosely.
  diff <(grep -v '^\*Generated ' "$first") <(grep -v '^\*Generated ' "$second") >/dev/null ||
    fail "a second run changed content other than its own timestamps"
  pass "a second run changes nothing but its own timestamps"
}

# --- marker refusal ---------------------------------------------------------

# refuses_and_leaves_untouched <label> <mutator>: apply <mutator> to a fresh
# brief, then require a refusal that names the file and changed no byte.
refuses_and_leaves_untouched() {
  local label=$1 mutator=$2 home fb before out code
  home=$(new_home "$TMP_ROOT/refuse-$label")
  fb=$(make_fakebin "$TMP_ROOT/refuse-$label")
  : > "$TMP_ROOT/refuse-$label/tasks"
  "$mutator" "$home/data/briefs/back-office.md"
  before="$TMP_ROOT/refuse-$label.before"
  cp "$home/data/briefs/back-office.md" "$before"

  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/refuse-$label/tasks" \
    run_gen "$home" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "$label: generate must refuse"
  assert_contains "$out" "refused:" "$label: the refusal says so plainly"
  assert_contains "$out" "back-office.md" "$label: the refusal names the file"
  assert_contains "$out" "left untouched" "$label: the refusal states the file was left alone"
  diff "$before" "$home/data/briefs/back-office.md" >/dev/null ||
    fail "$label: the refused file was modified"
  pass "$label: refused with a clear message and the file was left untouched"
}

drop_begin_marker() { grep -v 'fm:brief:waiting-on-you:begin' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
drop_end_marker() { grep -v 'fm:brief:running-now:end' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

duplicate_begin_marker() {
  awk '
    /^<!-- fm:brief:waiting-on-you:begin -->$/ && !seen { print; seen = 1 }
    { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

reverse_markers() {
  sed 's/fm:brief:running-now:begin/fm:brief:running-now:TMP/;
       s/fm:brief:running-now:end/fm:brief:running-now:begin/;
       s/fm:brief:running-now:TMP/fm:brief:running-now:end/' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

overlap_markers() {
  # Move the first block's end marker below the second block's begin marker.
  grep -v 'fm:brief:waiting-on-you:end' "$1" |
    awk '
      { print }
      /^<!-- fm:brief:running-now:begin -->$/ { print "<!-- fm:brief:waiting-on-you:end -->" }
    ' > "$1.tmp" && mv "$1.tmp" "$1"
}

test_marker_refusals() {
  refuses_and_leaves_untouched missing-begin drop_begin_marker
  refuses_and_leaves_untouched missing-end drop_end_marker
  refuses_and_leaves_untouched duplicated-begin duplicate_begin_marker
  refuses_and_leaves_untouched reversed reverse_markers
  refuses_and_leaves_untouched overlapping overlap_markers
}

test_missing_brief_file_is_refused() {
  local home fb out code
  home=$(new_home "$TMP_ROOT/nofile")
  fb=$(make_fakebin "$TMP_ROOT/nofile")
  : > "$TMP_ROOT/nofile/tasks"
  rm -f "$home/data/briefs/back-office.md"
  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/nofile/tasks" run_gen "$home" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a configured context with no brief must refuse"
  assert_contains "$out" "refused:" "the missing brief is reported as a refusal"
  pass "a configured context with no brief file is refused"
}

test_missing_mapping_is_refused() {
  local home out code
  home=$(new_home "$TMP_ROOT/nomap")
  rm -f "$home/config/context-briefs.conf"
  out=$(run_gen "$home" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "no mapping must refuse"
  assert_contains "$out" "context-briefs.conf" "the refusal names the mapping file"
  pass "a home with no context mapping is refused with the path to create"
}

# --- derived content --------------------------------------------------------

test_deadline_items_lead_and_clusters_group() {
  local home fb file
  home=$(new_home "$TMP_ROOT/content")
  fb=$(make_fakebin "$TMP_ROOT/content")
  cat > "$TMP_ROOT/content/tasks" <<'EOF'
mld-bi-payroll-decision-disclose|queued|mld-bi|2026-08-20|2026-08-01|Make the disclosure now, or wait for advice
mld-bi-payroll-decision-structure|queued|mld-bi|-|2026-08-01|Change how dentists are paid now, or hold
mld-bi-payroll-decision-register|queued|mld-bi|-|2026-08-01|Start an attendance register now
mldinvoicing-lonely-decision-tab|queued|JaredHuynhning/MLDInvoicing|-|2026-08-02|Choose whether staff want a reference tab
mld-bi-old-decision-closed|done|mld-bi|-|2026-07-01|Already decided and must not appear
EOF
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/content/tasks" run_gen "$home" >/dev/null 2>&1
  file="$home/data/briefs/back-office.md"

  assert_grep '**These have a date on them**' "$file" "the dated group leads"
  assert_grep '- **By 20 August 2026.** Make the disclosure now, or wait for advice.' "$file" \
    "the dated item states its date in plain words"
  # The backticks below are Markdown code spans, not command substitution.
  # shellcheck disable=SC2016
  assert_grep '*Raised by `mld-bi-payroll`*' "$file" "a cluster of two or more is named by the work that raised it"
  assert_grep '**mld-bi** (2)' "$file" "the repository group counts only its undated items"
  assert_grep '**mldinvoicing** (1)' "$file" "an owner-prefixed repository still matches its mapped name"
  assert_no_grep 'Already decided and must not appear' "$file" "a resolved decision is left out"
  assert_grep '4 decisions are sitting on this side, one of them with a date.' "$file" \
    "the count line reads as a sentence"

  # The dated item must appear once, at the top, not again inside its cluster.
  [ "$(grep -c 'mld-bi-payroll-decision-disclose' "$file")" = 1 ] ||
    fail "the dated item was listed twice"
  pass "dated decisions lead, clusters group, and counts read as sentences"
}

test_empty_sections_say_so_plainly() {
  local home fb file
  home=$(new_home "$TMP_ROOT/empty")
  fb=$(make_fakebin "$TMP_ROOT/empty")
  : > "$TMP_ROOT/empty/tasks"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/empty/tasks" run_gen "$home" >/dev/null 2>&1
  file="$home/data/briefs/back-office.md"
  assert_grep 'Nothing is waiting on you for this side.' "$file" "an empty decision list says so"
  assert_grep 'Nothing is running for this side right now.' "$file" "an empty running list says so"
  pass "an empty derived section says so plainly rather than writing filler"
}

# A backlog that could not be read must never render as a backlog that was read
# and found empty. The two cases are indistinguishable to the captain otherwise,
# and the block would carry a fresh generation date over a source nobody read,
# which is the one lie the staleness probe cannot catch.
#
# The assertion is proved to have teeth first: the same fixture with a readable
# backlog and no items really does render the confident empty, so an
# implementation that ignores the backend decision fails the check below rather
# than passing it by accident.
test_an_unreadable_backlog_never_reads_as_an_empty_one() {
  local home fb file empty_home empty_file
  empty_home=$(new_home "$TMP_ROOT/unread-control")
  fb=$(make_fakebin "$TMP_ROOT/unread-control")
  : > "$TMP_ROOT/unread-control/tasks"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/unread-control/tasks" \
    run_gen "$empty_home" >/dev/null 2>&1
  empty_file="$empty_home/data/briefs/back-office.md"
  assert_grep 'Nothing is waiting on you for this side.' "$empty_file" \
    "a backlog that was read and holds nothing still says so plainly"

  # Same fixture, same empty backlog, but a build this home refuses to read
  # through. The rendered wording must differ from the control above.
  home=$(new_home "$TMP_ROOT/unread-old")
  file="$home/data/briefs/back-office.md"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/unread-control/tasks" \
    FAKE_TASKS_AXI_VERSION=0.1.0 run_gen "$home" >/dev/null 2>&1
  assert_no_grep 'Nothing is waiting on you for this side.' "$file" \
    "an unreadable backlog must not claim nothing is waiting"
  assert_grep 'could not be read' "$file" "the block says it could not be read"
  assert_grep 'tasks-axi' "$file" "the block names what it could not reach"
  [ "$(grep -c 'fm:brief:generated ' "$file")" = 1 ] ||
    fail "the unread block must not carry a generation stamp, and the read one must"
  assert_grep 'fm:brief:unread waiting-on-you' "$file" \
    "the unread block is marked as unread rather than generated"

  # The manual backlog backend is an opt-out, not an empty backlog either.
  local manual manual_file
  manual=$(new_home "$TMP_ROOT/unread-manual")
  manual_file="$manual/data/briefs/back-office.md"
  printf 'manual\n' > "$manual/config/backlog-backend"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/unread-control/tasks" \
    run_gen "$manual" >/dev/null 2>&1
  assert_no_grep 'Nothing is waiting on you for this side.' "$manual_file" \
    "the manual backend must not claim nothing is waiting"
  assert_grep 'manual backlog backend' "$manual_file" \
    "the block names the manual backend as the reason"
  pass "an unreadable backlog says it could not find out and carries no generation date"
}

# check() treats an unread block as a block that failed, because the captain's
# probe is the date and an unread block deliberately carries none.
test_check_fails_a_block_whose_source_could_not_be_read() {
  local home fb out code
  home=$(new_home "$TMP_ROOT/unread-check")
  fb=$(make_fakebin "$TMP_ROOT/unread-check")
  : > "$TMP_ROOT/unread-check/tasks"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/unread-check/tasks" \
    FAKE_TASKS_AXI_VERSION=0.1.0 run_gen "$home" >/dev/null 2>&1

  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/unread-check/tasks" \
    FAKE_TASKS_AXI_VERSION=0.1.0 run_gen "$home" --check 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a block whose source could not be read must fail the audit"
  assert_contains "$out" "source could not be read" "the audit says which way the block failed"
  assert_contains "$out" "the backlog cannot be read right now" \
    "the audit also names the live read it could not perform"
  pass "check fails a block whose source could not be read and names the cause"
}

# The same distinction on the live-work half, through the same mechanism rather
# than a second one.
test_absent_task_state_never_reads_as_nothing_running() {
  local home fb file
  home=$(new_home "$TMP_ROOT/nostate")
  fb=$(make_fakebin "$TMP_ROOT/nostate")
  : > "$TMP_ROOT/nostate/tasks"
  file="$home/data/briefs/back-office.md"
  rm -rf "$home/state"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/nostate/tasks" run_gen "$home" >/dev/null 2>&1
  assert_no_grep 'Nothing is running for this side right now.' "$file" \
    "a task state directory that does not exist must not claim nothing is running"
  assert_grep 'fm:brief:unread running-now' "$file" \
    "the running block is marked as unread rather than generated"
  pass "task state that does not exist says so rather than reading as nothing running"
}

test_unreadable_task_state_never_reads_as_nothing_running() {
  local home fb file
  if [ "$(id -u)" = 0 ]; then
    pass "skipped: running as root, where an unreadable directory cannot be staged"
    return 0
  fi
  home=$(new_home "$TMP_ROOT/unread-state")
  fb=$(make_fakebin "$TMP_ROOT/unread-state")
  : > "$TMP_ROOT/unread-state/tasks"
  file="$home/data/briefs/back-office.md"
  chmod 000 "$home/state"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/unread-state/tasks" run_gen "$home" >/dev/null 2>&1
  chmod 755 "$home/state"
  assert_no_grep 'Nothing is running for this side right now.' "$file" \
    "an unlistable task state must not claim nothing is running"
  assert_grep 'fm:brief:unread running-now' "$file" \
    "the running block is marked as unread rather than generated"
  pass "task state that cannot be listed says so rather than reading as nothing running"
}

# Every live task must appear, and the count is what is asserted. A run that
# loses half of them still renders a well formed block carrying a fresh
# generation stamp, so it reads as a successful refresh and the staleness probe
# cannot catch it. That is precisely the silently wrong but fresh failure this
# whole feature exists to prevent.
#
# The enumeration must not be able to lose a record to a child that reads stdin,
# because the current-state reader reaches a tree of them and a correctness
# property that holds only while no descendant happens to read stdin is not a
# property. The stubs here do read a line, which is what makes this discriminating.
test_every_live_task_survives_a_child_that_reads_stdin() {
  local home fb file n listed
  home=$(new_home "$TMP_ROOT/stdin-eater")
  fb=$(make_fakebin "$TMP_ROOT/stdin-eater")
  : > "$TMP_ROOT/stdin-eater/tasks"
  file="$home/data/briefs/back-office.md"

  for n in 1 2 3 4; do
    # The worktree has to exist, because the current-state reader stops before
    # probing the harness when it is gone and the probe is the stdin reader here.
    mkdir -p "$home/worktrees/mldinv-live-$n"
    fm_write_meta "$home/state/mldinv-live-$n.meta" \
      "window=firstmate:fm-mldinv-live-$n" \
      "endpoint_task_id=mldinv-live-$n" \
      "worktree=$home/worktrees/mldinv-live-$n" \
      "project=$home/projects/mldinvoicing" \
      'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off'
  done

  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/stdin-eater/tasks" FAKE_STDIN_EATER=1 \
    run_gen "$home" >/dev/null 2>&1

  listed=0
  for n in 1 2 3 4; do
    grep -F -- "mldinv-live-$n" "$file" >/dev/null && listed=$((listed + 1))
  done
  [ "$listed" -eq 4 ] ||
    fail "only $listed of 4 live tasks were rendered, and the block still looks fresh"
  assert_no_grep 'Nothing is running for this side right now.' "$file" \
    "the running block must not read as empty when four tasks are live"
  pass "every live task is rendered even when a child of the state read consumes stdin"
}

# The same property on the backlog half, whose per-item read is also a child of
# the enumeration.
test_every_captain_item_survives_a_child_that_reads_stdin() {
  local home fb file n listed
  home=$(new_home "$TMP_ROOT/stdin-eater-backlog")
  fb=$(make_fakebin "$TMP_ROOT/stdin-eater-backlog")
  file="$home/data/briefs/back-office.md"
  cat > "$TMP_ROOT/stdin-eater-backlog/tasks" <<'EOF'
mld-bi-alpha-decision-one|queued|mld-bi|-|2026-08-01|Approve the first thing
mld-bi-alpha-decision-two|queued|mld-bi|-|2026-08-02|Approve the second thing
mld-bi-beta-decision-three|queued|mld-bi|-|2026-08-03|Approve the third thing
mld-bi-beta-decision-four|queued|mld-bi|-|2026-08-04|Approve the fourth thing
EOF
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/stdin-eater-backlog/tasks" FAKE_STDIN_EATER=1 \
    run_gen "$home" >/dev/null 2>&1

  listed=0
  for n in one two three four; do
    grep -F -- "decision-$n" "$file" >/dev/null && listed=$((listed + 1))
  done
  [ "$listed" -eq 4 ] ||
    fail "only $listed of 4 captain decisions were rendered, and the block still looks fresh"
  pass "every captain decision is rendered even when a child consumes stdin"
}

test_running_reports_live_work_and_skips_secondmates() {
  local home fb file
  home=$(new_home "$TMP_ROOT/running")
  fb=$(make_fakebin "$TMP_ROOT/running")
  : > "$TMP_ROOT/running/tasks"
  fm_write_meta "$home/state/mldinv-fix.meta" \
    'window=firstmate:fm-mldinv-fix' \
    'endpoint_task_id=mldinv-fix' \
    "worktree=$home/gone" \
    "project=$home/projects/mldinvoicing" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    'pr=https://github.com/acme/mldinvoicing/pull/7'
  fm_write_secondmate_meta "$home/state/frontend.meta" "$home/second" \
    'firstmate:fm-frontend' 'mld-bi'
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/running/tasks" run_gen "$home" >/dev/null 2>&1
  file="$home/data/briefs/back-office.md"
  assert_grep 'mldinv-fix' "$file" "a live work item is listed"
  assert_grep 'https://github.com/acme/mldinvoicing/pull/7' "$file" \
    "the work item carries its full pull request address"
  assert_no_grep 'frontend' "$file" "a standing second mate is not listed as running work"
  pass "running work is listed with its pull request and second mates are left out"
}

test_unmapped_repository_is_reported() {
  local home fb out
  home=$(new_home "$TMP_ROOT/unmapped")
  fb=$(make_fakebin "$TMP_ROOT/unmapped")
  cat > "$TMP_ROOT/unmapped/tasks" <<'EOF'
somewhere-decision-one|queued|a-repo-nobody-claimed|-|2026-08-01|An orphaned decision
EOF
  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/unmapped/tasks" run_gen "$home" 2>&1)
  assert_contains "$out" 'unmapped: repository "a-repo-nobody-claimed"' \
    "an unmapped repository is an explicit line"
  assert_no_grep 'An orphaned decision' "$home/data/briefs/back-office.md" \
    "an unmapped decision is not filed under an unrelated context"
  pass "a repository no context claims is reported rather than silently dropped"
}

# --- age stamp and the read-only review line --------------------------------

test_each_block_states_its_own_age() {
  local home fb file
  home=$(new_home "$TMP_ROOT/stamp")
  fb=$(make_fakebin "$TMP_ROOT/stamp")
  : > "$TMP_ROOT/stamp/tasks"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/stamp/tasks" run_gen "$home" >/dev/null 2>&1
  file="$home/data/briefs/back-office.md"
  [ "$(grep -c '^\*Generated ' "$file")" = 2 ] ||
    fail "both generated blocks must state when they were generated"
  [ "$(grep -c 'fm:brief:generated ' "$file")" = 2 ] ||
    fail "both generated blocks must carry a machine-readable stamp"
  assert_grep 'If that date is not recent this section stopped updating' "$file" \
    "the stamp tells the reader what an old date means"
  assert_grep '*Current as at 7 August 2026, late afternoon.*' "$file" \
    "the narrative review line is left exactly as written"
  pass "each generated block states its own age and the narrative review line is untouched"
}

test_check_reports_a_stale_block_and_reads_the_review_line() {
  local home fb out code
  home=$(new_home "$TMP_ROOT/check")
  fb=$(make_fakebin "$TMP_ROOT/check")
  : > "$TMP_ROOT/check/tasks"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check/tasks" run_gen "$home" >/dev/null 2>&1

  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check/tasks" run_gen "$home" --check 2>&1) &&
    code=0 || code=$?
  expect_code 0 "$code" "a freshly generated home is not stale"
  assert_contains "$out" 'last reviewed 7 August 2026, late afternoon' \
    "check reads the narrative review line"

  # Age the machine stamp by two days without touching anything else.
  local old
  old=$(( $(date +%s) - 172800 ))
  sed "s/epoch=[0-9]*/epoch=$old/" "$home/data/briefs/back-office.md" > "$home/x" &&
    mv "$home/x" "$home/data/briefs/back-office.md"
  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check/tasks" run_gen "$home" --check 2>&1) &&
    code=0 || code=$?
  expect_code 1 "$code" "an aged block must fail the check"
  assert_contains "$out" "has stopped updating" "check names the stopped generator"
  pass "check reports an aged block, exits non-zero, and reads the review line it never writes"
}

# The read-only audit is one of the two surfaces required to name a repository
# no context claims, so it reads the same records the generator does.
test_check_reports_an_unmapped_repository() {
  local home fb out code
  home=$(new_home "$TMP_ROOT/check-unmapped")
  fb=$(make_fakebin "$TMP_ROOT/check-unmapped")
  cat > "$TMP_ROOT/check-unmapped/tasks" <<'EOF'
somewhere-decision-one|queued|a-repo-nobody-claimed|-|2026-08-01|An orphaned decision
EOF
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check-unmapped/tasks" run_gen "$home" >/dev/null 2>&1

  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check-unmapped/tasks" \
    run_gen "$home" --check 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "an unmapped repository is a fact, never a failing audit"
  assert_contains "$out" 'unmapped: repository "a-repo-nobody-claimed"' \
    "the read-only audit names the unmapped repository too"
  pass "check reports an unmapped repository without turning it into a failure"
}

test_after_event_is_quiet_and_never_fails() {
  local home out code
  home=$(new_home "$TMP_ROOT/quiet")
  rm -f "$home/config/context-briefs.conf"
  out=$(run_gen "$home" --after-event 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "--after-event must never fail a lifecycle command"
  [ -z "$out" ] || fail "--after-event printed: $out"
  pass "--after-event stays silent and exits 0 even with nothing configured"
}

# --after-event runs at the end of spawn, teardown and every landing, so anything
# it prints lands in the operator's face during an unrelated command. A home it
# cannot even create a state directory in must still be completely silent.
test_after_event_is_silent_when_the_state_directory_cannot_be_made() {
  local home out code
  if [ "$(id -u)" = 0 ]; then
    pass "skipped: running as root, where an unwritable directory cannot be staged"
    return 0
  fi
  home=$(new_home "$TMP_ROOT/quiet-nostate")
  rm -rf "$home/state"
  mkdir -p "$home/sealed"
  chmod 500 "$home/sealed"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/sealed/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$GEN" --after-event 2>&1) && code=0 || code=$?
  chmod 755 "$home/sealed"
  expect_code 0 "$code" "--after-event must never fail a lifecycle command"
  [ -z "$out" ] || fail "--after-event printed on stdout or stderr: $out"
  pass "--after-event stays silent even when it cannot create a state directory"
}

# --check and --help both promise in writing that they write nothing. A home with
# no state directory proves it, because anything that creates one has written.
test_the_read_only_paths_create_nothing() {
  local home fb
  home=$(new_home "$TMP_ROOT/readonly")
  fb=$(make_fakebin "$TMP_ROOT/readonly")
  : > "$TMP_ROOT/readonly/tasks"
  rm -rf "$home/state"

  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/readonly/tasks" run_gen "$home" --help >/dev/null 2>&1
  assert_absent "$home/state" "--help created a state directory"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/readonly/tasks" run_gen "$home" --check >/dev/null 2>&1
  assert_absent "$home/state" "--check created a state directory"
  pass "the read-only paths create nothing, not even a state directory"
}

# The audit reports which repositories appear, and a repository identity comes
# from the task metadata alone. Reading what each live task is doing costs one
# bounded current-state read apiece and the audit discards every one of them, so
# on a degraded fleet that is minutes of waiting for nothing.
test_check_does_not_perform_a_current_state_read() {
  local home fb log
  home=$(new_home "$TMP_ROOT/check-cheap")
  fb=$(make_fakebin "$TMP_ROOT/check-cheap")
  : > "$TMP_ROOT/check-cheap/tasks"
  log="$TMP_ROOT/check-cheap/calls"
  # The worktree has to be present, because the current-state reader stops before
  # probing the harness when it is gone, and this test needs the probe to happen.
  mkdir -p "$home/worktrees/mldinv-live"
  fm_write_meta "$home/state/mldinv-live.meta" \
    'window=firstmate:fm-mldinv-live' \
    'endpoint_task_id=mldinv-live' \
    "worktree=$home/worktrees/mldinv-live" \
    "project=$home/projects/mldinvoicing" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off'

  # The control: rendering a brief genuinely does read current state, so the
  # log below is known to record one when it happens.
  : > "$log"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check-cheap/tasks" FAKE_CALL_LOG="$log" \
    run_gen "$home" >/dev/null 2>&1
  [ -s "$log" ] ||
    fail "the control never recorded a current-state read, so this test proves nothing"

  : > "$log"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check-cheap/tasks" FAKE_CALL_LOG="$log" \
    run_gen "$home" --check >/dev/null 2>&1
  [ -s "$log" ] &&
    fail "check performed a current-state read for data it discards:"$'\n'"$(cat "$log")"
  pass "check reports repository identities without reading what each task is doing"
}

# The other half of the audit's cost: one backlog read per captain-held item, for
# a repository the single listing call already named.
test_check_does_not_read_the_backlog_item_by_item() {
  local home fb tasklog tmp
  home=$(new_home "$TMP_ROOT/check-list-only")
  fb=$(make_fakebin "$TMP_ROOT/check-list-only")
  tasklog="$TMP_ROOT/check-list-only/tasks-axi-calls"
  tmp="$TMP_ROOT/check-list-only/tmp"
  mkdir -p "$tmp"
  cat > "$TMP_ROOT/check-list-only/tasks" <<'EOF'
mld-bi-alpha-decision-one|queued|mld-bi|-|2026-08-01|Approve the first thing
orphan-decision-two|queued|a-repo-nobody-claimed|-|2026-08-02|An orphaned decision
EOF

  # The control: rendering a brief genuinely does read each item, so the log
  # below is known to record a per-item read when one happens.
  : > "$tasklog"
  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check-list-only/tasks" FAKE_TASKS_LOG="$tasklog" \
    run_gen "$home" >/dev/null 2>&1
  grep -qx 'show' "$tasklog" ||
    fail "the control never recorded a per-item backlog read, so this test proves nothing"

  : > "$tasklog"
  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/check-list-only/tasks" \
    FAKE_TASKS_LOG="$tasklog" TMPDIR="$tmp" run_gen "$home" --check 2>&1)
  grep -qx 'show' "$tasklog" &&
    fail "check read the backlog item by item for a repository the listing already named"
  assert_contains "$out" 'unmapped: repository "a-repo-nobody-claimed"' \
    "the audit still names the unmapped repository from the listing alone"
  [ -z "$(find "$tmp" -mindepth 1 2>/dev/null)" ] ||
    fail "check created something under the temporary directory: $(find "$tmp" -mindepth 1)"
  pass "check takes each repository from the one listing and stages nothing to do it"
}

# A brief being rewritten is staged beside itself, in the directory the captain
# browses through his Obsidian symlink, and the working records are staged under
# the temporary directory. The aggregate bound on --after-event makes a run that
# is stopped part way through a designed outcome rather than an accident, so
# nothing staged may outlive it. Driving the real bound rather than signalling by
# hand exercises the way it is actually stopped in production.
test_a_stopped_run_leaves_nothing_staged() {
  local home fb tmp leftovers out code
  home=$(new_home "$TMP_ROOT/staging")
  fb=$(make_fakebin "$TMP_ROOT/staging")
  : > "$TMP_ROOT/staging/tasks"
  tmp="$TMP_ROOT/staging/tmp"
  mkdir -p "$tmp"

  PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/staging/tasks" TMPDIR="$tmp" \
    run_gen "$home" >/dev/null 2>&1
  leftovers=$(find "$tmp" "$home/data/briefs" -name '*fm-context-briefs.*' 2>/dev/null)
  [ -z "$leftovers" ] || fail "a completed run left staging paths: $leftovers"

  # The bound fires while the backlog listing is still stalled, which is exactly
  # how a degraded backend stops a refresh in production.
  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/staging/tasks" TMPDIR="$tmp" \
    FAKE_TASKS_AXI_SLEEP=30 FM_CONTEXT_BRIEFS_AFTER_EVENT_TIMEOUT=1 \
    run_gen "$home" --after-event 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "a refresh that hits the bound must still exit 0"
  [ -z "$out" ] || fail "the bounded refresh printed: $out"

  leftovers=$(find "$tmp" "$home/data/briefs" -name '*fm-context-briefs.*' 2>/dev/null)
  [ -z "$leftovers" ] || fail "a run stopped by the bound left staging paths: $leftovers"
  assert_grep 'A hand-written opening line that must never move.' \
    "$home/data/briefs/back-office.md" "the brief survived the stopped run"
  pass "nothing staged outlives a run, whether it finished or the bound stopped it"
}

# --- installing the markers -------------------------------------------------

# install_home <dir> <body>: an FM_HOME whose brief carries the two headings but
# no markers yet, which is the state --install-markers exists for.
install_home() {
  local home=$1 body=$2
  mkdir -p "$home/data/briefs" "$home/config" "$home/state"
  printf '%s' "$body" > "$home/data/briefs/back-office.md"
  printf 'back-office: mldinvoicing\n' > "$home/config/context-briefs.conf"
  printf '%s\n' "$home"
}

# A heading with nothing under it is the boundary case: the block to preserve is
# empty, and an implementation that copies it anyway duplicates the line that
# ended it into the block it was supposed to bound.
test_install_markers_handles_an_empty_section_body() {
  local home file
  home=$(install_home "$TMP_ROOT/install-adjacent" \
    '# Back office

## Waiting on you
## Running now

A closing pointer.
')
  file="$home/data/briefs/back-office.md"
  run_gen "$home" --install-markers >/dev/null 2>&1
  [ "$(grep -c '^## Running now$' "$file")" = 1 ] ||
    fail "the boundary heading was duplicated into the block above it"
  [ "$(grep -c '^## Waiting on you$' "$file")" = 1 ] ||
    fail "the first heading was duplicated"
  assert_grep 'A closing pointer.' "$file" "the hand-written pointer survived"
  # Having installed them, the file must now be one the generator accepts.
  run_gen "$home" --install-markers >/dev/null 2>&1
  [ "$(grep -c 'waiting-on-you:begin' "$file")" = 1 ] ||
    fail "a second install added a duplicate marker"
  pass "a heading with an empty body is wrapped without duplicating its boundary"
}

# A brief that only ever got one pair installed must stay repairable. The old
# guard asked for both pairs at once, so repairing the missing pair inserted a
# second copy of the pair that was already there and locked the file out.
test_install_markers_repairs_a_half_marked_brief() {
  local home file out code
  home=$(install_home "$TMP_ROOT/install-half" \
    '# Back office

## Waiting on you

Decisions live here.

---

## Running now

Live work lives here.
')
  file="$home/data/briefs/back-office.md"
  run_gen "$home" --install-markers >/dev/null 2>&1
  grep -v 'running-now:begin' "$file" > "$file.cut" && mv "$file.cut" "$file"
  grep -v 'running-now:end' "$file" > "$file.cut" && mv "$file.cut" "$file"

  out=$(run_gen "$home" --install-markers 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "repairing a half-marked brief must succeed"
  [ "$(grep -c 'waiting-on-you:begin' "$file")" = 1 ] ||
    fail "repairing the missing pair duplicated the pair that was already there"
  [ "$(grep -c 'running-now:begin' "$file")" = 1 ] ||
    fail "the missing pair was not restored exactly once"
  pass "a half-marked brief is repaired rather than locked out"
}

# The refusal message is a promise about the file on disk, so a refusal on the
# second heading must leave the first heading unwrapped too.
test_install_markers_refusal_leaves_the_file_byte_identical() {
  local home file before out code
  home=$(install_home "$TMP_ROOT/install-refuse" \
    '# Back office

## Waiting on you

Decisions live here.

---

## Running now

Live work lives here.

---

## Running now

A second copy of the heading that makes the boundary ambiguous.
')
  file="$home/data/briefs/back-office.md"
  before="$TMP_ROOT/install-refuse.before"
  cp "$file" "$before"

  out=$(run_gen "$home" --install-markers 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "an ambiguous second heading must refuse"
  assert_contains "$out" "left untouched" "the refusal states the file was left alone"
  assert_contains "$out" "back-office.md" "the refusal names the brief, not a staging copy"
  diff "$before" "$file" >/dev/null ||
    fail "the refusal claimed the file was left untouched but it was rewritten"
  pass "a refusal on the second heading leaves the whole brief byte-identical"
}

test_a_symlinked_brief_is_refused_as_a_symlink() {
  local home out code
  home=$(new_home "$TMP_ROOT/symlink")
  mv "$home/data/briefs/back-office.md" "$home/real-brief.md"
  ln -s "$home/real-brief.md" "$home/data/briefs/back-office.md"
  out=$(run_gen "$home" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a symlinked brief must refuse"
  assert_contains "$out" "symbolic link" "the refusal names the real cause"
  assert_not_contains "$out" "there is no brief at" \
    "the refusal must not claim the brief is missing"
  pass "a symlinked brief is refused for being a symlink rather than for being absent"
}

# --- the generator runs without being asked ---------------------------------

# fm-merge-local.sh is one of the lifecycle commands wired to the generator.
# Driving the real command end to end demonstrates the wiring rather than
# asserting it: the brief has no generated content before the merge and does
# after, with no separate generator call in between.
test_a_landing_refreshes_the_briefs_on_its_own() {
  local home fb proj out
  home=$(new_home "$TMP_ROOT/landing")
  fb=$(make_fakebin "$TMP_ROOT/landing")
  : > "$TMP_ROOT/landing/tasks"
  proj="$home/projects/mldinvoicing"
  fm_git_init_commit "$proj"
  git -C "$proj" branch -m main 2>/dev/null || true
  git -C "$proj" checkout -q -b fm/mldinv-land
  printf 'landed\n' > "$proj/landed.txt"
  git -C "$proj" add landed.txt
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm landed
  git -C "$proj" checkout -q main
  fm_write_meta "$home/state/mldinv-land.meta" \
    'window=firstmate:fm-mldinv-land' \
    'endpoint_task_id=mldinv-land' \
    "worktree=$home/gone" \
    "project=$proj" \
    'harness=claude' 'kind=ship' 'mode=local-only' 'yolo=off'

  assert_no_grep 'fm:brief:generated' "$home/data/briefs/back-office.md" \
    "the brief carries no generated stamp before the landing"

  out=$(PATH="$fb:$PATH" FAKE_TASKS="$TMP_ROOT/landing/tasks" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-merge-local.sh" mldinv-land 2>&1) || fail "the merge failed: $out"
  assert_contains "$out" "merged" "the merge itself succeeded"
  assert_grep 'fm:brief:generated' "$home/data/briefs/back-office.md" \
    "landing the work refreshed the brief without a separate generator call"
  assert_grep 'mldinv-land' "$home/data/briefs/back-office.md" \
    "the refreshed brief lists the task that just landed"
  pass "a real landing refreshes the context briefs on its own"
}

test_naive_implementation_fails_the_prose_check
test_hand_written_prose_survives_byte_for_byte
test_regeneration_is_idempotent_apart_from_the_stamp
test_marker_refusals
test_missing_brief_file_is_refused
test_missing_mapping_is_refused
test_deadline_items_lead_and_clusters_group
test_empty_sections_say_so_plainly
test_an_unreadable_backlog_never_reads_as_an_empty_one
test_check_fails_a_block_whose_source_could_not_be_read
test_absent_task_state_never_reads_as_nothing_running
test_unreadable_task_state_never_reads_as_nothing_running
test_every_live_task_survives_a_child_that_reads_stdin
test_every_captain_item_survives_a_child_that_reads_stdin
test_running_reports_live_work_and_skips_secondmates
test_unmapped_repository_is_reported
test_each_block_states_its_own_age
test_check_reports_a_stale_block_and_reads_the_review_line
test_check_reports_an_unmapped_repository
test_check_does_not_perform_a_current_state_read
test_check_does_not_read_the_backlog_item_by_item
test_the_read_only_paths_create_nothing
test_after_event_is_quiet_and_never_fails
test_after_event_is_silent_when_the_state_directory_cannot_be_made
test_a_stopped_run_leaves_nothing_staged
test_install_markers_handles_an_empty_section_body
test_install_markers_repairs_a_half_marked_brief
test_install_markers_refusal_leaves_the_file_byte_identical
test_a_symlinked_brief_is_refused_as_a_symlink
test_a_landing_refreshes_the_briefs_on_its_own
