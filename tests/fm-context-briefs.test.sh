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
# The rest covers marker refusal (missing, duplicated, reversed, overlapping),
# the derived content itself (deadline items first, clustering, plain wording
# for an empty section), the age stamp and the read-only narrative review line,
# unmapped repository reporting, and one end-to-end demonstration that a real
# lifecycle command refreshes the briefs on its own.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GEN="$ROOT/bin/fm-context-briefs.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-briefs)

# --- fixture ----------------------------------------------------------------

# A tasks-axi stub driven by $FAKE_TASKS, a file of
# "<id>|<state>|<repo>|<hold_until>|<created>|<title>" records. It answers the
# two read shapes the generator uses and nothing else.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
records=${FAKE_TASKS:-/dev/null}
case "${1:-}" in
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
  # fm-crew-state reaches for these; a torn-down fixture reads unknown, which is
  # exactly the deterministic answer these tests want.
  fm_fake_exit0 "$fb" no-mistakes tmux
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

  out=$(run_gen "$home" --check 2>&1) && code=0 || code=$?
  expect_code 0 "$code" "a freshly generated home is not stale"
  assert_contains "$out" 'last reviewed 7 August 2026, late afternoon' \
    "check reads the narrative review line"

  # Age the machine stamp by two days without touching anything else.
  local old
  old=$(( $(date +%s) - 172800 ))
  sed "s/epoch=[0-9]*/epoch=$old/" "$home/data/briefs/back-office.md" > "$home/x" &&
    mv "$home/x" "$home/data/briefs/back-office.md"
  out=$(run_gen "$home" --check 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "an aged block must fail the check"
  assert_contains "$out" "has stopped updating" "check names the stopped generator"
  pass "check reports an aged block, exits non-zero, and reads the review line it never writes"
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
test_running_reports_live_work_and_skips_secondmates
test_unmapped_repository_is_reported
test_each_block_states_its_own_age
test_check_reports_a_stale_block_and_reads_the_review_line
test_after_event_is_quiet_and_never_fails
test_a_landing_refreshes_the_briefs_on_its_own
