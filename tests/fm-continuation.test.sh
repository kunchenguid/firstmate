#!/usr/bin/env bash
# The cross-harness continuation record: bin/fm-continuation-lib.sh's schema,
# atomic write, and validation (section A, hermetic and fast), then its
# integration into bin/fm-control.sh's transactional relaunch (section B,
# stubbed session provider, no real agent - the same fixture shape as
# tests/fm-control-relaunch.test.sh):
#   A1-A7  the record's shape: round-trip fields, empty vs populated blocks,
#          schema/identity validation, one-line collapsing, Markdown render.
#   B1-B3  a harness switch (Pi->Claude, Claude->Codex, Codex->Pi) delivers a
#          fresh continuation record to the replacement's instructions.
#   B4     uncommitted work is represented in the record.
#   B5     findings with no file changes are represented explicitly, never
#          silently dropped for want of a code change.
#   B6     freshness: physical facts and the timestamp always advance to the
#          moment of relaunch, even where the narrative is carried forward.
#   B7     a corrupt or wrong-identity existing record refuses the relaunch
#          before the old agent is touched.
#   B8     a launch failure after publication still preserves the record.
#   B9     a secondmate's continuation record accounts for child work and its
#          delivery never rewrites the standing charter.
#   B10    a refusal before the agent is touched leaves the record unchanged.
#   B11    relaunching twice never creates a second record or a foreign
#          identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-continuation-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"

TMP_ROOT=$(fm_test_tmproot fm-continuation)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

# =============================================================================
# Section A: the record's shape (bin/fm-continuation-lib.sh), hermetic.
# =============================================================================

write_fixture_record() {  # <path> <task> [dirty] [modified] [findings] [objective]
  local path=$1 task=$2 dirty=${3:-no} modified=${4:-} findings=${5:-} objective=${6:-}
  fm_continuation_write "$task" ship "ship task $task" "test" \
    main abc123 "/tmp/wt-$task" "$dirty" \
    "$modified" "" "" \
    "$objective" "" "" "$findings" "" "next step" \
    | fm_continuation_write_atomic "$path"
}

test_round_trip_preserves_every_block_field() {
  local path="$TMP_ROOT/a1.continuation"
  write_fixture_record "$path" a1 no "" "the bug is in tokenizer.go" "fix the parser"
  [ "$(fm_continuation_read_field "$path" task)" = a1 ] || fail "task field did not round-trip"
  [ "$(fm_continuation_read_field "$path" schema)" = "$FM_CONTINUATION_SCHEMA" ] \
    || fail "schema field did not round-trip"
  [ "$(fm_continuation_read_block "$path" objective)" = "fix the parser" ] \
    || fail "objective block did not round-trip"
  [ "$(fm_continuation_read_block "$path" findings)" = "the bug is in tokenizer.go" ] \
    || fail "findings block did not round-trip"
  [ "$(fm_continuation_read_block "$path" next_action)" = "next step" ] \
    || fail "next_action block did not round-trip"
  pass "fm-continuation-lib: every block field round-trips through write and read"
}

test_empty_block_reads_as_empty_not_missing() {
  local path="$TMP_ROOT/a2.continuation"
  write_fixture_record "$path" a2
  assert_grep 'objective: -' "$path" "an empty block field should use the empty form on disk"
  [ -z "$(fm_continuation_read_block "$path" objective)" ] \
    || fail "an empty block field should read back as empty"
  pass "fm-continuation-lib: an empty narrative field renders and reads as empty, not omitted"
}

test_multiline_block_content_round_trips() {
  local path="$TMP_ROOT/a3.continuation" text
  text=$'line one\nline two\n\nline four after a blank line'
  fm_continuation_write a3 ship "ship task a3" test main abc123 /tmp/wt-a3 no \
    "" "" "" "" "" "" "" "" "$text" \
    | fm_continuation_write_atomic "$path"
  [ "$(fm_continuation_read_block "$path" next_action)" = "$text" ] \
    || fail "multi-line block content, including an embedded blank line, must round-trip exactly"
  pass "fm-continuation-lib: multi-line block content round-trips, including an embedded blank line"
}

test_one_line_field_collapses_embedded_newlines() {
  local path="$TMP_ROOT/a4.continuation"
  fm_continuation_write "a4" "ship" $'role\nwith a newline' test main abc123 /tmp/wt-a4 no \
    "" "" "" "" "" "" "" "" "" \
    | fm_continuation_write_atomic "$path"
  [ "$(fm_continuation_read_field "$path" role)" = "role with a newline" ] \
    || fail "an embedded newline in a single-line field should collapse to a space, not corrupt the record"
  pass "fm-continuation-lib: a single-line field collapses an embedded newline instead of corrupting the record"
}

test_validate_refuses_an_unsupported_schema() {
  local path="$TMP_ROOT/a5.continuation" err
  printf 'schema: 99\ntask: a5\n' > "$path"
  err=$(fm_continuation_validate "$path"); rc=$?
  [ "$rc" -eq 1 ] || fail "an unsupported schema version must refuse validation"
  assert_contains "$err" "schema '99'" "the refusal should name the unsupported schema"
  pass "fm-continuation-lib: validation refuses a record with an unsupported schema version"
}

test_validate_refuses_a_mismatched_task_identity() {
  local path="$TMP_ROOT/a6.continuation" err
  write_fixture_record "$path" a6
  err=$(fm_continuation_validate "$path" "someone-else"); rc=$?
  [ "$rc" -eq 1 ] || fail "a foreign task identity must refuse validation against the expected task"
  assert_contains "$err" "not the expected 'someone-else'" "the refusal should name the identity mismatch"
  fm_continuation_validate "$path" a6 || fail "the same record validates cleanly against its own task id"
  pass "fm-continuation-lib: validation refuses a record whose task field names a different task"
}

test_render_markdown_labels_every_field_and_marks_absent_ones() {
  local path="$TMP_ROOT/a7.continuation" out
  write_fixture_record "$path" a7 no "" "" "fix the parser"
  out=$(fm_continuation_render_markdown "$path")
  assert_contains "$out" "**Objective:**" "the render should label the objective"
  assert_contains "$out" "fix the parser" "the render should carry the objective's content"
  assert_contains "$out" "**Findings/evidence:**" "the render should label findings even when empty"
  assert_contains "$out" "(none recorded)" "an empty field should render as explicitly none recorded"
  pass "fm-continuation-lib: the Markdown render labels every field and marks an absent one explicitly"
}

# =============================================================================
# Section B: integration through bin/fm-control.sh relaunch.
# =============================================================================

# The same lifecycle-modelling tmux stub as tests/fm-control-relaunch.test.sh:
# the harness's exit command stops the agent, and a launch-brief literal
# starts the harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

add_ship_task() {  # <case-dir> <id> [harness]
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise continuation-record behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=$harness" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "model=default" "effort=default"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

add_secondmate_task() {  # <case-dir> <id>
  local dir=$1 id=$2
  local home="$dir/home"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin" "$home/state"
  printf '%s\n' "$id" > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" "endpoint_task_id=$id" "worktree=$dir/smhome" \
    "project=$dir/smhome" "harness=claude" "kind=secondmate" "mode=secondmate" \
    "yolo=off" "model=default" "effort=default" "home=$dir/smhome"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

continuation_field() {  # <case-dir> <id> <field>
  fm_continuation_read_field "$1/home/state/$2.continuation" "$3"
}

continuation_block() {  # <case-dir> <id> <field>
  fm_continuation_read_block "$1/home/state/$2.continuation" "$3"
}

# --- B1-B3: harness-switch profile replacement ------------------------------

harness_switch_case() {  # <name> <id> <from> <to>
  local name=$1 id=$2 from=$3 to=$4 dir out rc
  dir=$(new_case "$name" "$id")
  add_ship_task "$dir" "$id" "$from"
  printf '%s' "$to" > "$dir/fake/becomes"
  out=$(run_control "$dir" "$id" relaunch --harness "$to" --note "switching runtime" \
    --objective "carry the fix across the harness switch" \
    --next "verify the fix under $to"); rc=$?
  expect_code 0 "$rc" "a $from -> $to relaunch should succeed"$'\n'"$out"
  [ -f "$dir/home/state/$id.continuation" ] \
    || fail "a $from -> $to relaunch must publish a continuation record"
  fm_continuation_validate "$dir/home/state/$id.continuation" "$id" \
    || fail "the published continuation record must validate"
  [ "$(continuation_block "$dir" "$id" objective)" = "carry the fix across the harness switch" ] \
    || fail "the objective supplied at relaunch must land in the continuation record"
  [ "$(continuation_block "$dir" "$id" next_action)" = "verify the fix under $to" ] \
    || fail "the next action supplied at relaunch must land in the continuation record"
  assert_contains "$(cat "$dir/home/data/$id/brief.md")" "## Continuation record" \
    "the replacement's instructions must carry the continuation record"
  assert_contains "$(cat "$dir/home/data/$id/brief.md")" "carry the fix across the harness switch" \
    "the replacement's instructions must carry the continuation record's content"
  pass "fm-control relaunch: a $from -> $to profile replacement delivers a fresh continuation record"
}

test_pi_to_claude_profile_replacement() { harness_switch_case pi-claude cb1 pi claude; }
test_claude_to_codex_profile_replacement() { harness_switch_case claude-codex cb2 claude codex; }
test_codex_to_pi_profile_replacement() { harness_switch_case codex-pi cb3 codex pi; }

# --- B4: dirty work -----------------------------------------------------------

test_dirty_work_is_represented_in_the_continuation_record() {
  local dir out rc id=cb4
  dir=$(new_case dirty "$id")
  add_ship_task "$dir" "$id" claude
  printf 'unfinished refactor\n' > "$dir/wt/inprogress.txt"
  git -C "$dir/wt" add inprogress.txt
  out=$(run_control "$dir" "$id" relaunch --note "mid-refactor" \
    --completed "renamed the helper module" \
    --unresolved "callers in the other package still need updating"); rc=$?
  expect_code 0 "$rc" "a dirty-worktree relaunch should succeed"$'\n'"$out"
  [ "$(continuation_field "$dir" "$id" worktree_dirty)" = yes ] \
    || fail "uncommitted work must be reflected as worktree_dirty=yes"
  assert_contains "$(continuation_block "$dir" "$id" modified_files)" "inprogress.txt" \
    "the modified file must be named in the continuation record"
  assert_contains "$(continuation_block "$dir" "$id" unresolved)" "callers in the other package" \
    "the unresolved-work narrative must be preserved"
  pass "fm-control relaunch: uncommitted work is represented explicitly in the continuation record"
}

# --- B5: findings-only continuation, no file changes -------------------------

test_findings_only_continuation_with_no_file_changes() {
  local dir out rc id=cb5
  dir=$(new_case findings "$id")
  add_ship_task "$dir" "$id" claude
  out=$(run_control "$dir" "$id" relaunch --note "investigated, made no changes" \
    --findings "the 500 comes from an unhandled empty-input case in the parser" \
    --next "add a guard clause and a regression test"); rc=$?
  expect_code 0 "$rc" "a findings-only relaunch should succeed"$'\n'"$out"
  [ "$(continuation_field "$dir" "$id" worktree_dirty)" = no ] \
    || fail "a clean worktree must be recorded as worktree_dirty=no"
  [ -z "$(continuation_block "$dir" "$id" modified_files)" ] \
    || fail "no file changes must render as an explicitly empty modified_files block"
  assert_contains "$(continuation_block "$dir" "$id" findings)" "unhandled empty-input case" \
    "findings must be preserved even though nothing was changed"
  pass "fm-control relaunch: findings with no file changes are represented explicitly, never silently dropped"
}

# --- B6: freshness ------------------------------------------------------------

test_continuation_freshness_refreshes_physical_facts_and_timestamp() {
  local dir out rc id=cb6 first_ts second_ts
  dir=$(new_case fresh "$id")
  add_ship_task "$dir" "$id" claude
  out=$(run_control "$dir" "$id" relaunch --note "first pass" \
    --objective "fix the parser" --findings "found the bug in tokenizer.go"); rc=$?
  expect_code 0 "$rc" "the first relaunch should succeed"$'\n'"$out"
  first_ts=$(continuation_field "$dir" "$id" timestamp)
  [ -n "$first_ts" ] || fail "the first relaunch must publish a timestamp"

  printf 'still in progress\n' > "$dir/wt/wip.txt"
  git -C "$dir/wt" add wip.txt
  printf 'claude' > "$dir/fake/becomes"
  /bin/sleep 1
  out=$(run_control "$dir" "$id" relaunch --note "second pass, same harness"); rc=$?
  expect_code 0 "$rc" "the second relaunch should succeed"$'\n'"$out"
  second_ts=$(continuation_field "$dir" "$id" timestamp)
  [ "$second_ts" != "$first_ts" ] \
    || fail "a later relaunch must advance the continuation record's timestamp"
  [ "$(continuation_field "$dir" "$id" worktree_dirty)" = yes ] \
    || fail "a later relaunch must refresh worktree_dirty to the current state"
  assert_contains "$(continuation_block "$dir" "$id" modified_files)" "wip.txt" \
    "a later relaunch must refresh the modified-files list to the current state"
  [ "$(continuation_block "$dir" "$id" objective)" = "fix the parser" ] \
    || fail "a later relaunch that supplies no new objective must carry the previous one forward"
  [ "$(continuation_block "$dir" "$id" findings)" = "found the bug in tokenizer.go" ] \
    || fail "a later relaunch that supplies no new findings must carry the previous ones forward"
  pass "fm-control relaunch: physical facts and the timestamp always refresh, while unset narrative fields carry forward"
}

# --- B7: schema/identity validation refuses before the agent is touched -----

test_continuation_schema_validation_refuses_before_stopping_the_agent() {
  local dir out rc id=cb7
  dir=$(new_case badschema "$id")
  add_ship_task "$dir" "$id" claude
  printf 'schema: 99\ntask: %s\n' "$id" > "$dir/home/state/$id.continuation"
  out=$(run_control "$dir" "$id" relaunch --note "should not proceed"); rc=$?
  expect_code 1 "$rc" "a relaunch must refuse a continuation record with an unsupported schema"
  assert_contains "$out" "schema '99'" "the refusal should name the unsupported schema"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a schema-validation refusal must land before the running agent is stopped"
  [ "$(cat "$dir/home/state/$id.continuation")" = "$(printf 'schema: 99\ntask: %s\n' "$id")" ] \
    || fail "a refused relaunch must leave the unreadable record byte-identical"
  pass "fm-control relaunch: an unsupported continuation-record schema refuses before the agent is touched"
}

test_continuation_identity_mismatch_refuses_before_stopping_the_agent() {
  local dir out rc id=cb7b
  dir=$(new_case badidentity "$id")
  add_ship_task "$dir" "$id" claude
  write_fixture_record "$dir/home/state/$id.continuation" "someone-else"
  out=$(run_control "$dir" "$id" relaunch --note "should not proceed"); rc=$?
  expect_code 1 "$rc" "a relaunch must refuse a continuation record naming a different task"
  assert_contains "$out" "not the expected '$id'" "the refusal should name the identity mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an identity-mismatch refusal must land before the running agent is stopped"
  pass "fm-control relaunch: a continuation record for a different task refuses before the agent is touched"
}

# --- B8: failed replacement after publication --------------------------------

test_failed_replacement_after_publication_preserves_the_continuation_record() {
  local dir out rc id=cb8
  dir=$(new_case failpub "$id")
  add_ship_task "$dir" "$id" claude
  # `becomes` never sets pane_current_command to a recognizable alive harness,
  # so the launch owner publishes the new record but the agent never confirms.
  printf 'zsh' > "$dir/fake/becomes"
  out=$(run_control "$dir" "$id" relaunch --harness codex --note "switching runtime" \
    --objective "keep going after the switch"); rc=$?
  expect_code 1 "$rc" "a launch that never confirms alive should fail"
  [ -f "$dir/home/state/$id.continuation" ] \
    || fail "a launch failure after publication must not lose the continuation record"
  [ "$(continuation_block "$dir" "$id" objective)" = "keep going after the switch" ] \
    || fail "the continuation record published before the failed launch must survive it"
  pass "fm-control relaunch: a launch failure after publication still preserves the continuation record"
}

# --- B9: persistent secondmate child records ---------------------------------

test_secondmate_continuation_records_child_work_and_spares_the_charter() {
  local dir out rc id=cb9
  dir=$(new_case secondmate "$id")
  add_secondmate_task "$dir" "$id"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  out=$(run_control "$dir" "$id" relaunch --findings "both children are mid-review"); rc=$?
  expect_code 0 "$rc" "a checkpointed secondmate should relaunch"$'\n'"$out"
  assert_contains "$(continuation_block "$dir" "$id" durable_refs)" "children=2" \
    "the continuation record must account for the secondmate's child work"
  [ "$(cat "$dir/smhome/data/charter.md")" = "# charter" ] \
    || fail "a secondmate's standing charter must never be rewritten to deliver the continuation record"
  [ -f "$dir/home/data/$id/launch-charter.md" ] \
    || fail "the continuation record must be delivered through a launch-only overlay"
  assert_contains "$(cat "$dir/home/data/$id/launch-charter.md")" "# charter" \
    "the overlay must still carry the original charter content"
  assert_contains "$(cat "$dir/home/data/$id/launch-charter.md")" "both children are mid-review" \
    "the overlay must carry the continuation record's content"
  pass "fm-control relaunch: a secondmate's continuation record accounts for child work without rewriting its charter"
}

# --- B10: rollback -------------------------------------------------------------

test_refused_relaunch_leaves_the_continuation_record_unchanged() {
  local dir out rc id=cb10 before
  dir=$(new_case rollback "$id")
  add_ship_task "$dir" "$id" claude
  out=$(run_control "$dir" "$id" relaunch --note "first pass" \
    --objective "fix the parser"); rc=$?
  expect_code 0 "$rc" "the first relaunch should succeed"$'\n'"$out"
  before=$(cat "$dir/home/state/$id.continuation")

  # A ship relaunch without --note refuses before the agent is touched.
  out=$(run_control "$dir" "$id" relaunch --objective "a different objective"); rc=$?
  expect_code 1 "$rc" "a relaunch without --note must refuse"
  [ "$(cat "$dir/home/state/$id.continuation")" = "$before" ] \
    || fail "a refused relaunch must leave the continuation record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is touched leaves the continuation record unchanged"
}

# --- B11: no duplicate identity or copy ---------------------------------------

test_relaunch_never_duplicates_the_continuation_record() {
  local dir out rc id=cb11 count
  dir=$(new_case noduplicate "$id")
  add_ship_task "$dir" "$id" claude
  out=$(run_control "$dir" "$id" relaunch --note "first pass" --objective "first objective"); rc=$?
  expect_code 0 "$rc" "the first relaunch should succeed"$'\n'"$out"
  printf 'claude' > "$dir/fake/becomes"
  out=$(run_control "$dir" "$id" relaunch --note "second pass" --objective "second objective"); rc=$?
  expect_code 0 "$rc" "the second relaunch should succeed"$'\n'"$out"
  count=$(find "$dir/home/state" -maxdepth 1 -name "$id.continuation*" ! -name '*.continuation.pending.*' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "relaunching twice must keep exactly one continuation record, found $count"
  [ "$(continuation_field "$dir" "$id" task)" = "$id" ] \
    || fail "the single continuation record must still name the correct task"
  [ "$(continuation_block "$dir" "$id" objective)" = "second objective" ] \
    || fail "a later relaunch's explicit objective must replace, not append to, the record"
  pass "fm-control relaunch: relaunching twice never duplicates the continuation record or its identity"
}

test_round_trip_preserves_every_block_field
test_empty_block_reads_as_empty_not_missing
test_multiline_block_content_round_trips
test_one_line_field_collapses_embedded_newlines
test_validate_refuses_an_unsupported_schema
test_validate_refuses_a_mismatched_task_identity
test_render_markdown_labels_every_field_and_marks_absent_ones
test_pi_to_claude_profile_replacement
test_claude_to_codex_profile_replacement
test_codex_to_pi_profile_replacement
test_dirty_work_is_represented_in_the_continuation_record
test_findings_only_continuation_with_no_file_changes
test_continuation_freshness_refreshes_physical_facts_and_timestamp
test_continuation_schema_validation_refuses_before_stopping_the_agent
test_continuation_identity_mismatch_refuses_before_stopping_the_agent
test_failed_replacement_after_publication_preserves_the_continuation_record
test_secondmate_continuation_records_child_work_and_spares_the_charter
test_refused_relaunch_leaves_the_continuation_record_unchanged
test_relaunch_never_duplicates_the_continuation_record
