#!/usr/bin/env bash
# Behavior tests for bin/fm-context.sh - the context-window report read from
# session transcripts rather than from a harness's rendered status line.
#
# Every case builds its own transcript world under a temp root and points the
# script at it with CLAUDE_PROJECTS_ROOT and FM_HOME, so nothing here depends on
# the running machine's real transcripts or on any live session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by fm-context.sh)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-context)
CONTEXT="$ROOT/bin/fm-context.sh"
BASH_BIN=$(command -v bash)

# --- fixture builders --------------------------------------------------------

# ctx_world <name>: build an isolated home plus its transcript root and echo the
# world directory. A world is the pair the script reads: FM_HOME (whose
# state/*.meta name the crew) and CLAUDE_PROJECTS_ROOT (where transcripts live).
ctx_world() {
  local world="$TMP_ROOT/$1"
  mkdir -p "$world/home/state" "$world/transcripts"
  printf '%s\n' "$world"
}

# ctx_transcript_dir <world> <session-directory>: echo the transcript directory
# the script derives for a session whose working directory is <session-directory>,
# creating it. The mapping (every '/' and '.' becomes '-') is the harness's own
# on-disk layout; test_unmapped_directory_is_not_read pins that it is load-bearing.
ctx_transcript_dir() {
  local world=$1 path=$2 dir
  dir="$world/transcripts/$(printf '%s' "$path" | tr './' '--')"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# ctx_assistant <model> <input> <cache-creation> <cache-read>: one assistant
# transcript record carrying usage.
ctx_assistant() {
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$1" "$2" "$3" "$4"
}

# ctx_task <world> <id> <worktree>: register a crew task by writing the metadata
# line the script reads, and echo the task's transcript directory.
ctx_task() {
  local world=$1 id=$2 worktree=$3
  fm_write_meta "$world/home/state/$id.meta" "worktree=$worktree"
  ctx_transcript_dir "$world" "$worktree"
}

# ctx_run <world> [args...]: run the script against <world>. Sets CTX_OUT,
# CTX_RC, and CTX_ERR rather than echoing, so a case can assert on all three.
ctx_run() {
  local world=$1
  shift
  CTX_OUT=$(CLAUDE_PROJECTS_ROOT="$world/transcripts" FM_HOME="$world/home" \
    bash "$CONTEXT" "$@" 2>"$world/.stderr")
  CTX_RC=$?
  CTX_ERR=$(cat "$world/.stderr")
}

# ctx_field <json> <label> <field>: read one field of the reported row labelled
# <label> out of --json output.
ctx_field() {
  printf '%s\n' "$1" | jq -r --arg l "$2" --arg f "$3" 'select(.label == $l) | .[$f]'
}

# --- transcript parsing ------------------------------------------------------

test_usage_comes_from_the_last_assistant_record() {
  local world dir
  world=$(ctx_world last-record)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  {
    printf '{"type":"user","message":{"content":"hello"}}\n'
    ctx_assistant stale-model 1 1 1
    printf '{"type":"user","message":{"content":"again"}}\n'
    ctx_assistant current-model 100 200 700
  } > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000
  expect_code 0 "$CTX_RC" "a readable transcript must report cleanly"
  [ "$(ctx_field "$CTX_OUT" 'this session' used)" = 1000 ] \
    || fail "used must sum the LAST assistant record's three token fields (100+200+700), got: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' model)" = current-model ] \
    || fail "the model must come from the same record the usage came from, got: $CTX_OUT"
  pass "fm-context.sh: usage is the last assistant record's input + cache-creation + cache-read"
}

test_records_without_usage_do_not_erase_the_figure() {
  local world dir
  world=$(ctx_world no-usage)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  {
    ctx_assistant real-model 4000 3000 3000
    printf '{"type":"assistant","message":{"model":"toolresult-only"}}\n'
    printf '{"type":"summary","summary":"compacted"}\n'
    printf '{"type":"user","message":{"usage":{"input_tokens":999999}}}\n'
  } > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000
  expect_code 0 "$CTX_RC" "trailing usage-free records must not turn into a failure"
  [ "$(ctx_field "$CTX_OUT" 'this session' used)" = 10000 ] \
    || fail "records with no usage, and a user record carrying usage, must not change the figure, got: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' model)" = real-model ] \
    || fail "the model must survive trailing usage-free records, got: $CTX_OUT"
  pass "fm-context.sh: only assistant records carrying usage move the figure"
}

test_newest_transcript_wins_and_session_id_overrides_it() {
  local world dir
  world=$(ctx_world newest)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant older-model 1000 0 0 > "$dir/older.jsonl"
  # Age the older file rather than sleeping, so the ordering is exact and free.
  touch -t 200001010000 "$dir/older.jsonl"
  ctx_assistant newer-model 40000 0 10000 > "$dir/newer.jsonl"

  ctx_run "$world" --json --window 100000
  [ "$(ctx_field "$CTX_OUT" 'this session' model)" = newer-model ] \
    || fail "with no session id, the newest transcript must be reported, got: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' used)" = 50000 ] \
    || fail "the newest transcript's usage must be reported, got: $CTX_OUT"

  CTX_OUT=$(CLAUDE_PROJECTS_ROOT="$world/transcripts" FM_HOME="$world/home" \
    CLAUDE_CODE_SESSION_ID=older bash "$CONTEXT" --json --window 100000)
  [ "$(ctx_field "$CTX_OUT" 'this session' model)" = older-model ] \
    || fail "a known session id must pin its own transcript over the newest one, got: $CTX_OUT"
  pass "fm-context.sh: newest transcript by default, the named session when its id is known"
}

test_unmapped_directory_is_not_read() {
  local world
  world=$(ctx_world unmapped)
  # Same basename, but not the derived path-encoded directory name.
  mkdir -p "$world/transcripts/home"
  ctx_assistant stray-model 5000 0 0 > "$world/transcripts/home/session.jsonl"

  ctx_run "$world" --json --window 100000
  expect_code 0 "$CTX_RC" "a world with no matching transcript directory must not fail"
  [ -z "$CTX_OUT" ] \
    || fail "a transcript outside the derived directory must not be reported, got: $CTX_OUT"
  pass "fm-context.sh: only the directory derived from the session path is read"
}

test_no_transcripts_is_not_a_failure() {
  local world
  world=$(ctx_world empty)
  ctx_run "$world" --window 100000
  expect_code 0 "$CTX_RC" "an empty world must exit 0, not trip on the absent transcript"
  [ "$(printf '%s\n' "$CTX_OUT" | wc -l | tr -d ' ')" = 1 ] \
    || fail "an empty world must print the header and no row, got: $CTX_OUT"
  assert_contains "$CTX_OUT" "remaining" "the table header must still name its columns"
  assert_contains "$CTX_OUT" "model" "the table header must still name its columns"
  pass "fm-context.sh: a world with no transcripts prints the header alone and exits 0"
}

# --- output shapes -----------------------------------------------------------

test_json_row_shape_and_arithmetic() {
  local world dir keys
  world=$(ctx_world json-shape)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant shape-model 30000 0 0 > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000
  expect_code 0 "$CTX_RC" "--json must exit 0 with no threshold"
  [ "$(printf '%s\n' "$CTX_OUT" | wc -l | tr -d ' ')" = 1 ] \
    || fail "--json must emit exactly one object per line, got: $CTX_OUT"
  keys=$(printf '%s\n' "$CTX_OUT" | jq -r '[keys_unsorted[]] | sort | join(",")')
  [ "$keys" = "label,model,remaining,remaining_percent,used,used_percent,window" ] \
    || fail "--json row keys changed, got: $keys"
  [ "$(ctx_field "$CTX_OUT" 'this session' window)" = 100000 ] || fail "window must echo --window"
  [ "$(ctx_field "$CTX_OUT" 'this session' used)" = 30000 ] || fail "used is wrong: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' used_percent)" = 30 ] || fail "used_percent is wrong: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' remaining)" = 70000 ] || fail "remaining is wrong: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' remaining_percent)" = 70 ] || fail "remaining_percent is wrong: $CTX_OUT"
  # Numbers must be JSON numbers a gate can compare, never quoted strings.
  printf '%s\n' "$CTX_OUT" | jq -e '(.used | type) == "number" and (.remaining_percent | type) == "number"' >/dev/null \
    || fail "--json must emit numeric fields, not strings: $CTX_OUT"
  # Every emitted line must parse, so no table header can contaminate the stream.
  printf '%s\n' "$CTX_OUT" | jq -e . >/dev/null \
    || fail "--json emitted a line that is not JSON: $CTX_OUT"
  pass "fm-context.sh: --json emits one numeric object per session with the documented keys"
}

test_table_prints_both_used_and_remaining() {
  local world dir
  world=$(ctx_world table)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant table-model 25000 0 0 > "$dir/session.jsonl"

  ctx_run "$world" --window 100000
  expect_code 0 "$CTX_RC" "the table must exit 0 with no threshold"
  assert_contains "$CTX_OUT" "this session" "the table must label this session"
  assert_contains "$CTX_OUT" "25000 used ( 25%)" "the table must print the used figure and percent"
  assert_contains "$CTX_OUT" "75000 left ( 75%)" "the table must print the remaining figure and percent"
  assert_contains "$CTX_OUT" "table-model" "the table must name the model so a wrong --window is visible"
  pass "fm-context.sh: the table prints used and remaining together, plus the model"
}

test_usage_beyond_the_window_clamps_remaining_to_zero() {
  local world dir
  world=$(ctx_world over-window)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant over-model 250000 0 0 > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000
  [ "$(ctx_field "$CTX_OUT" 'this session' used)" = 250000 ] \
    || fail "used must report the real consumption even past the window, got: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' remaining)" = 0 ] \
    || fail "remaining must clamp at zero rather than going negative, got: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' remaining_percent)" = 0 ] \
    || fail "remaining_percent must clamp at zero, got: $CTX_OUT"
  pass "fm-context.sh: usage past the window clamps remaining to zero without hiding the overshoot"
}

test_an_unreadable_transcript_does_not_take_down_the_report() {
  local world dir
  world=$(ctx_world corrupt)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant intact-model 30000 0 0 > "$dir/session.jsonl"
  dir=$(ctx_task "$world" task-corrupt "$world/wt/corrupt")
  printf 'not json at all\n{"type":"assistant","message":{\n' > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000
  expect_code 0 "$CTX_RC" "one unreadable transcript must not fail the whole report"
  [ "$(ctx_field "$CTX_OUT" 'this session' used)" = 30000 ] \
    || fail "the readable sessions must still be reported, got: $CTX_OUT"
  assert_not_contains "$CTX_OUT" "task-corrupt" "an unreadable transcript must not be reported as a figure"
  [ -z "$CTX_ERR" ] || fail "an unreadable transcript must not leak parser noise, got: $CTX_ERR"
  pass "fm-context.sh: an unreadable transcript is skipped, the rest of the fleet still reports"
}

# --- crew discovery ----------------------------------------------------------

test_crew_tasks_are_reported_from_their_recorded_worktree() {
  local world dir
  world=$(ctx_world crew)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant self-model 10000 0 0 > "$dir/session.jsonl"
  dir=$(ctx_task "$world" task-alpha "$world/wt/alpha")
  ctx_assistant alpha-model 60000 0 0 > "$dir/session.jsonl"
  # A task whose metadata records no worktree has no transcript to resolve.
  fm_write_meta "$world/home/state/task-beta.meta" "window=fm:beta"

  ctx_run "$world" --json --window 100000
  expect_code 0 "$CTX_RC" "reporting the crew must exit 0 with no threshold"
  [ "$(ctx_field "$CTX_OUT" task-alpha used)" = 60000 ] \
    || fail "a crew task must be read from the transcript of its recorded worktree, got: $CTX_OUT"
  [ "$(ctx_field "$CTX_OUT" 'this session' used)" = 10000 ] \
    || fail "this session must be reported alongside the crew, got: $CTX_OUT"
  assert_not_contains "$CTX_OUT" "task-beta" "a task with no recorded worktree must be skipped, not guessed"
  pass "fm-context.sh: each crew task is read from its own recorded worktree, and a worktree-less task is skipped"
}

test_task_ids_narrow_the_report_to_the_crew() {
  local world dir
  world=$(ctx_world filter)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant self-model 10000 0 0 > "$dir/session.jsonl"
  dir=$(ctx_task "$world" task-alpha "$world/wt/alpha")
  ctx_assistant alpha-model 60000 0 0 > "$dir/session.jsonl"
  dir=$(ctx_task "$world" task-gamma "$world/wt/gamma")
  ctx_assistant gamma-model 20000 0 0 > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000 task-gamma
  expect_code 0 "$CTX_RC" "a named task must report cleanly"
  assert_contains "$CTX_OUT" '"label":"task-gamma"' "the named task must be reported"
  assert_not_contains "$CTX_OUT" "task-alpha" "an unnamed task must not be reported"
  assert_not_contains "$CTX_OUT" "this session" "naming tasks must drop the this-session row"

  ctx_run "$world" --json --window 100000 no-such-task
  expect_code 0 "$CTX_RC" "an unknown task id must not be an error"
  [ -z "$CTX_OUT" ] || fail "an unknown task id must report nothing, got: $CTX_OUT"
  pass "fm-context.sh: task ids narrow the report to those tasks and drop this session"
}

# --- --threshold gating ------------------------------------------------------

test_threshold_fails_only_below_the_boundary() {
  local world dir
  world=$(ctx_world threshold)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  # Exactly 40% remaining, so the boundary itself is testable from both sides.
  ctx_assistant boundary-model 60000 0 0 > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000
  [ "$(ctx_field "$CTX_OUT" 'this session' remaining_percent)" = 40 ] \
    || fail "fixture must sit exactly on the 40% boundary, got: $CTX_OUT"

  ctx_run "$world" --json --window 100000 --threshold 39
  expect_code 0 "$CTX_RC" "40% remaining is above a 39% threshold"
  ctx_run "$world" --json --window 100000 --threshold 40
  expect_code 0 "$CTX_RC" "the threshold is a floor: remaining exactly at it must pass"
  ctx_run "$world" --json --window 100000 --threshold 41
  expect_code 1 "$CTX_RC" "40% remaining is below a 41% threshold and must exit 1"
  pass "fm-context.sh: --threshold exits 1 only strictly below the boundary, 0 at it and above"
}

test_default_threshold_never_fails() {
  local world dir
  world=$(ctx_world no-threshold)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant exhausted-model 100000 0 0 > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000
  expect_code 0 "$CTX_RC" "with no --threshold, even zero remaining must report rather than fail"
  [ "$(ctx_field "$CTX_OUT" 'this session' remaining_percent)" = 0 ] \
    || fail "fixture must have exhausted the window, got: $CTX_OUT"
  pass "fm-context.sh: the default threshold reports without ever failing"
}

test_threshold_reports_every_session_before_failing() {
  local world dir
  world=$(ctx_world threshold-fleet)
  dir=$(ctx_transcript_dir "$world" "$world/home")
  ctx_assistant roomy-model 10000 0 0 > "$dir/session.jsonl"
  dir=$(ctx_task "$world" task-tight "$world/wt/tight")
  ctx_assistant tight-model 95000 0 0 > "$dir/session.jsonl"
  dir=$(ctx_task "$world" task-roomy "$world/wt/roomy")
  ctx_assistant spare-model 20000 0 0 > "$dir/session.jsonl"

  ctx_run "$world" --json --window 100000 --threshold 50
  expect_code 1 "$CTX_RC" "one session below the threshold must fail the whole run"
  assert_contains "$CTX_OUT" '"label":"task-tight"' "the breaching session must still be reported"
  assert_contains "$CTX_OUT" '"label":"task-roomy"' "a healthy session after the breach must still be reported"
  assert_contains "$CTX_OUT" '"label":"this session"' "this session must still be reported"
  pass "fm-context.sh: a breach fails the run without truncating the report"
}

# --- refusals ----------------------------------------------------------------

test_bad_invocations_refuse_with_exit_2() {
  local world
  world=$(ctx_world refusals)

  ctx_run "$world" --nonsense
  expect_code 2 "$CTX_RC" "an unknown option must exit 2"
  assert_contains "$CTX_ERR" "unknown option: --nonsense" "an unknown option must name itself on stderr"

  ctx_run "$world" --window
  expect_code 2 "$CTX_RC" "--window with no value must exit 2"
  assert_contains "$CTX_ERR" "--window needs a value" "--window must say what it is missing"

  ctx_run "$world" --threshold
  expect_code 2 "$CTX_RC" "--threshold with no value must exit 2"
  assert_contains "$CTX_ERR" "--threshold needs a value" "--threshold must say what it is missing"

  ctx_run "$world" --window 0
  expect_code 2 "$CTX_RC" "a zero window must exit 2 rather than dividing by it"
  assert_contains "$CTX_ERR" "--window must be a positive integer" "a zero window must say why"

  ctx_run "$world" --window not-a-number
  expect_code 2 "$CTX_RC" "a non-numeric window must exit 2"
  assert_contains "$CTX_ERR" "--window must be a positive integer" "a non-numeric window must say why"
  pass "fm-context.sh: bad invocations exit 2 with a diagnostic, never a bogus report"
}

test_missing_jq_refuses_rather_than_reporting_nothing() {
  local world out rc
  world=$(ctx_world no-jq)
  mkdir -p "$world/emptybin"
  # Absolute interpreter path: the stripped PATH must hide jq from the script,
  # not hide bash from this test.
  out=$(PATH="$world/emptybin" CLAUDE_PROJECTS_ROOT="$world/transcripts" \
    FM_HOME="$world/home" "$BASH_BIN" "$CONTEXT" --json 2>&1)
  rc=$?
  expect_code 2 "$rc" "without jq the report must refuse, not print an empty table"
  assert_contains "$out" "jq is required" "the refusal must name the missing dependency"
  pass "fm-context.sh: a missing jq is a refusal, not a silently empty report"
}

test_help_prints_the_usage_contract() {
  local world
  world=$(ctx_world help)
  ctx_run "$world" --help
  expect_code 0 "$CTX_RC" "--help must exit 0"
  assert_contains "$CTX_OUT" "Usage: fm-context.sh" "--help must print the usage line"
  assert_contains "$CTX_OUT" "--threshold" "--help must document --threshold"
  assert_contains "$CTX_OUT" "--window" "--help must document --window"
  assert_contains "$CTX_OUT" "--json" "--help must document --json"
  pass "fm-context.sh: --help prints the usage contract"
}

test_usage_comes_from_the_last_assistant_record
test_records_without_usage_do_not_erase_the_figure
test_newest_transcript_wins_and_session_id_overrides_it
test_unmapped_directory_is_not_read
test_no_transcripts_is_not_a_failure
test_json_row_shape_and_arithmetic
test_table_prints_both_used_and_remaining
test_usage_beyond_the_window_clamps_remaining_to_zero
test_an_unreadable_transcript_does_not_take_down_the_report
test_crew_tasks_are_reported_from_their_recorded_worktree
test_task_ids_narrow_the_report_to_the_crew
test_threshold_fails_only_below_the_boundary
test_default_threshold_never_fails
test_threshold_reports_every_session_before_failing
test_bad_invocations_refuse_with_exit_2
test_missing_jq_refuses_rather_than_reporting_nothing
test_help_prints_the_usage_contract
