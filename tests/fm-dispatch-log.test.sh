#!/usr/bin/env bash
# tests/fm-dispatch-log.test.sh - behavior tests for the durable dispatch log
# query CLI (bin/fm-dispatch-log.sh: summary grouping/counting, --since/--until
# filtering, empty/missing-log handling, malformed-line tolerance, and usage
# errors), plus targeted tests on the real non-fatal append blocks documented in
# bin/fm-spawn.sh and bin/fm-teardown.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CLI="$ROOT/bin/fm-dispatch-log.sh"

make_home() {  # <name>
  local home
  home=$(fm_test_tmproot "fm-dispatch-log-$1")
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

write_log() {  # <home> <line>...
  local home=$1
  shift
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/data/dispatch-log.jsonl"
  done
}

spawn_line() {  # <id> <ts> <harness> <model> <effort> <kind> <repo> <mode> <backend> <yolo>
  printf '{"event":"spawn","ts":"%s","id":"%s","harness":"%s","model":"%s","effort":"%s","kind":"%s","repo":"%s","mode":"%s","backend":"%s","yolo":"%s"}' \
    "$2" "$1" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}

run() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$CLI" "$@"
}

# --- summary grouping and counting -------------------------------------------

test_summary_groups_by_model_default_and_prints_total() {
  local home out
  home=$(make_home grouping)
  write_log "$home" \
    "$(spawn_line a1 2026-07-01T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    "$(spawn_line a2 2026-07-02T10:00:00Z claude opus xhigh scout /x/foo no-mistakes tmux off)" \
    "$(spawn_line a3 2026-07-03T10:00:00Z codex gpt medium ship /x/bar no-mistakes tmux on)" \
    "$(spawn_line a4 2026-07-04T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)"
  out=$(run "$home" summary)
  assert_contains "$out" "sonnet: 2" "sonnet must be counted twice"
  assert_contains "$out" "opus: 1" "opus must be counted once"
  assert_contains "$out" "gpt: 1" "gpt must be counted once"
  assert_contains "$out" "total: 4" "total must sum every spawn event"
  pass "summary groups by model by default and prints a pre-computed total"
}

test_summary_group_by_other_fields() {
  local home out
  home=$(make_home other-fields)
  write_log "$home" \
    "$(spawn_line a1 2026-07-01T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    "$(spawn_line a2 2026-07-02T10:00:00Z codex gpt medium scout /x/bar no-mistakes tmux on)"
  out=$(run "$home" summary --group-by harness)
  assert_contains "$out" "claude: 1" "harness group-by must count claude"
  assert_contains "$out" "codex: 1" "harness group-by must count codex"
  out=$(run "$home" summary --group-by kind)
  assert_contains "$out" "ship: 1" "kind group-by must count ship"
  assert_contains "$out" "scout: 1" "kind group-by must count scout"
  out=$(run "$home" summary --group-by repo)
  assert_contains "$out" "/x/foo: 1" "repo group-by must count /x/foo"
  assert_contains "$out" "/x/bar: 1" "repo group-by must count /x/bar"
  out=$(run "$home" summary --group-by effort)
  assert_contains "$out" "high: 1" "effort group-by must count high"
  assert_contains "$out" "medium: 1" "effort group-by must count medium"
  pass "summary --group-by supports harness, kind, repo, and effort"
}

test_group_by_repo_buckets_blank_value_as_unknown() {
  local home out
  home=$(make_home blank-repo)
  write_log "$home" \
    "$(spawn_line a1 2026-07-01T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    "$(spawn_line a2 2026-07-02T10:00:00Z claude sonnet high secondmate "" no-mistakes tmux off)"
  out=$(run "$home" summary --group-by repo)
  assert_contains "$out" "/x/foo: 1" "a real repo path must still be counted under its own key"
  assert_contains "$out" "unknown: 1" "a blank repo (e.g. a secondmate spawn) must bucket as unknown"
  pass "summary --group-by repo buckets a blank value as unknown rather than a literal empty key"
}

test_teardown_events_are_join_only_and_never_counted() {
  local home out
  home=$(make_home teardown-events)
  write_log "$home" \
    "$(spawn_line a1 2026-07-01T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    '{"event":"teardown","ts":"2026-07-01T11:00:00Z","id":"a1"}'
  out=$(run "$home" summary)
  assert_contains "$out" "total: 1" "a teardown event must never be counted toward the total"
  pass "teardown events are join-only and never counted in the summary"
}

# --- date filtering -----------------------------------------------------------

test_since_until_date_filtering_is_inclusive() {
  local home out
  home=$(make_home date-filter)
  write_log "$home" \
    "$(spawn_line a1 2026-06-30T23:59:59Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    "$(spawn_line a2 2026-07-01T00:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    "$(spawn_line a3 2026-07-15T12:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    "$(spawn_line a4 2026-07-31T23:59:59Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    "$(spawn_line a5 2026-08-01T00:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)"
  out=$(run "$home" summary --since 2026-07-01 --until 2026-07-31)
  assert_contains "$out" "total: 3" "since/until bounds must be inclusive on both ends"
  pass "--since/--until date filtering is inclusive on both boundary dates"
}

test_date_filter_with_no_matches_is_a_definitive_zero_not_blank() {
  local home out
  home=$(make_home no-match)
  write_log "$home" \
    "$(spawn_line a1 2026-07-01T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)"
  out=$(run "$home" summary --since 2030-01-01)
  assert_contains "$out" "total: 0" "a filter matching nothing must print a definitive total: 0"
  pass "a date filter matching nothing prints a definitive total: 0, not blank output"
}

# --- empty / missing log ------------------------------------------------------

test_missing_log_file_is_a_valid_empty_state_not_an_error() {
  local home out rc
  home=$(fm_test_tmproot fm-dispatch-log-missing)
  out=$(run "$home" summary)
  rc=$?
  expect_code 0 "$rc" "a missing dispatch log must not be an error"
  assert_contains "$out" "total: 0" "a missing log must still print a definitive total: 0"
  assert_contains "$out" "no dispatch log yet" "a missing log must explain itself, not just print zero silently"
  pass "a missing dispatch-log.jsonl is a valid empty-fleet state, not an error"
}

test_empty_log_file_present_is_also_zero() {
  local home out
  home=$(make_home empty-file)
  : > "$home/data/dispatch-log.jsonl"
  out=$(run "$home" summary)
  assert_contains "$out" "total: 0" "a present-but-empty log must summarize to zero"
  pass "an existing empty log summarizes to a definitive zero"
}

test_unreadable_log_errors_loudly_instead_of_silent_zero() {
  local home rc err
  home=$(make_home unreadable)
  write_log "$home" "$(spawn_line a1 2026-07-01T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)"
  if [ "$(id -u)" = 0 ]; then
    echo "skip: running as root, permission bits do not restrict reads"
    return 0
  fi
  chmod 000 "$home/data/dispatch-log.jsonl"
  err=$(run "$home" summary 2>&1)
  rc=$?
  chmod 644 "$home/data/dispatch-log.jsonl"
  [ "$rc" -ne 0 ] || fail "an unreadable log must not silently report success"
  assert_contains "$err" "not readable" "an unreadable log must report a structured error, not a silent zero"
  pass "an existing but unreadable log errors loudly instead of silently reporting zero"
}

test_malformed_json_line_is_skipped_not_fatal() {
  local home out
  home=$(make_home malformed)
  write_log "$home" \
    "$(spawn_line a1 2026-07-01T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)" \
    'not valid json at all' \
    '{"event":"spawn","harness":"codex"' \
    "$(spawn_line a2 2026-07-02T10:00:00Z claude sonnet high ship /x/foo no-mistakes tmux off)"
  out=$(run "$home" summary)
  assert_contains "$out" "sonnet: 2" "malformed lines must be skipped, not counted or fatal"
  assert_contains "$out" "total: 2" "the total must reflect only the well-formed spawn lines"
  pass "a malformed JSON line is skipped rather than aborting the read"
}

# --- usage / bad input ---------------------------------------------------------

test_unknown_subcommand_errors() {
  local home rc
  home=$(make_home bad-subcommand)
  run "$home" bogus >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "an unknown subcommand must be a loud usage error"
  pass "an unknown subcommand is a loud usage error"
}

test_unknown_flag_errors() {
  local home rc
  home=$(make_home bad-flag)
  run "$home" summary --nope >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "an unknown flag must be a loud usage error"
  pass "an unknown flag is a loud usage error"
}

test_bad_group_by_value_errors() {
  local home rc
  home=$(make_home bad-groupby)
  run "$home" summary --group-by nonsense >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "an invalid --group-by value must be a loud usage error"
  pass "an invalid --group-by value is a loud usage error"
}

test_bad_date_format_errors() {
  local home rc
  home=$(make_home bad-date)
  run "$home" summary --since 07/01/2026 >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a malformed --since date must be a loud usage error"
  pass "a malformed --since/--until date is a loud usage error"
}

# --- the real append blocks in fm-spawn.sh / fm-teardown.sh --------------------
#
# A full spawn/teardown integration test is out of scope (would require mocking
# the whole backend/worktree pipeline); these instead eval the LITERAL append
# block from each script (extracted, not reimplemented) against stubbed
# variables, so a regression in the actual shipped code is caught.

extract_block() {  # <file>
  awk '
    /# Durable dispatch record \(bin\/fm-dispatch-log\.sh header owns the log format\)\./ {flag=1}
    flag {print}
    flag && /^} 2>\/dev\/null \|\| true$/ {exit}
  ' "$1"
}

test_spawn_append_block_produces_the_documented_json_shape() {
  local home block out
  home=$(make_home spawn-append)
  block=$(extract_block "$ROOT/bin/fm-spawn.sh")
  [ -n "$block" ] || fail "could not locate the dispatch-log append block in bin/fm-spawn.sh"
  # The variables and function below are consumed by the eval'd extracted
  # block, invisibly to shellcheck's static analysis.
  # shellcheck disable=SC2034,SC2329
  out=$(
    set -eu
    json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    DATA="$home/data"
    ID="spawn-shape"
    HARNESS="claude"
    MODEL="sonnet"
    EFFORT="high"
    KIND="ship"
    PROJ_ABS="/x/foo"
    MODE="no-mistakes"
    BACKEND="tmux"
    YOLO="off"
    eval "$block"
    cat "$DATA/dispatch-log.jsonl"
  )
  printf '%s' "$out" | jq -e '
    .event == "spawn" and .id == "spawn-shape" and .harness == "claude"
      and .model == "sonnet" and .effort == "high" and .kind == "ship"
      and .repo == "/x/foo" and .mode == "no-mistakes" and .backend == "tmux"
      and .yolo == "off" and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' >/dev/null || fail "the real fm-spawn.sh append block did not produce the documented JSON shape: $out"
  pass "the real fm-spawn.sh append block produces the documented spawn JSON shape"
}

test_spawn_append_block_blanks_repo_for_secondmate_kind() {
  local home block out
  home=$(make_home spawn-append-secondmate)
  block=$(extract_block "$ROOT/bin/fm-spawn.sh")
  [ -n "$block" ] || fail "could not locate the dispatch-log append block in bin/fm-spawn.sh"
  # PROJ_ABS is a secondmate's firstmate home for kind=secondmate, not a repo;
  # the append block must leave repo blank rather than logging the home path.
  # shellcheck disable=SC2034,SC2329
  out=$(
    set -eu
    json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    DATA="$home/data"
    ID="spawn-secondmate-shape"
    HARNESS="claude"
    MODEL="default"
    EFFORT="default"
    KIND="secondmate"
    PROJ_ABS="/home/sctru/.claude/secondmates/some-secondmate"
    MODE="secondmate"
    BACKEND="tmux"
    YOLO="off"
    eval "$block"
    cat "$DATA/dispatch-log.jsonl"
  )
  printf '%s' "$out" | jq -e '.repo == ""' >/dev/null \
    || fail "a kind=secondmate spawn must record a blank repo, not its firstmate home path: $out"
  pass "the real fm-spawn.sh append block blanks repo for a kind=secondmate spawn"
}

test_spawn_append_block_is_non_fatal_when_data_is_unwritable() {
  local home block rc parent out_file
  home=$(make_home spawn-nonfatal)
  parent="$home/readonly-parent"
  mkdir -p "$parent"
  if [ "$(id -u)" = 0 ]; then
    echo "skip: running as root, permission bits do not restrict writes"
    return 0
  fi
  chmod 555 "$parent"
  block=$(extract_block "$ROOT/bin/fm-spawn.sh")
  out_file=$(mktemp)
  bash -c '
    set -eu
    json_escape() { printf "%s" "$1" | sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g"; }
    DATA="'"$parent"'/data"
    ID="x"; HARNESS="claude"; MODEL="sonnet"; EFFORT="high"; KIND="ship"
    PROJ_ABS="/x/foo"; MODE="no-mistakes"; BACKEND="tmux"; YOLO="off"
    '"$block"'
    echo survived
  ' > "$out_file" 2>&1
  rc=$?
  chmod 755 "$parent"
  expect_code 0 "$rc" "a non-fatal append must never abort the caller under set -eu"
  assert_contains "$(cat "$out_file")" "survived" \
    "the script must reach the line after the append block even when data/ cannot be created"
  rm -f "$out_file"
  pass "the spawn append block is non-fatal under set -eu when data/ is unwritable"
}

test_teardown_append_block_produces_the_documented_json_shape() {
  local home block out
  home=$(make_home teardown-append)
  block=$(extract_block "$ROOT/bin/fm-teardown.sh")
  [ -n "$block" ] || fail "could not locate the dispatch-log append block in bin/fm-teardown.sh"
  # ID is consumed by the eval'd extracted block, invisibly to shellcheck.
  # shellcheck disable=SC2034
  out=$(
    set -eu
    DATA="$home/data"
    ID="teardown-shape"
    eval "$block"
    cat "$DATA/dispatch-log.jsonl"
  )
  printf '%s' "$out" | jq -e '
    .event == "teardown" and .id == "teardown-shape"
      and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and (keys | length) == 3
  ' >/dev/null || fail "the real fm-teardown.sh append block did not produce the documented minimal JSON shape: $out"
  pass "the real fm-teardown.sh append block produces the documented minimal teardown JSON shape"
}

test_summary_groups_by_model_default_and_prints_total
test_summary_group_by_other_fields
test_group_by_repo_buckets_blank_value_as_unknown
test_teardown_events_are_join_only_and_never_counted
test_since_until_date_filtering_is_inclusive
test_date_filter_with_no_matches_is_a_definitive_zero_not_blank
test_missing_log_file_is_a_valid_empty_state_not_an_error
test_empty_log_file_present_is_also_zero
test_unreadable_log_errors_loudly_instead_of_silent_zero
test_malformed_json_line_is_skipped_not_fatal
test_unknown_subcommand_errors
test_unknown_flag_errors
test_bad_group_by_value_errors
test_bad_date_format_errors
test_spawn_append_block_produces_the_documented_json_shape
test_spawn_append_block_blanks_repo_for_secondmate_kind
test_spawn_append_block_is_non_fatal_when_data_is_unwritable
test_teardown_append_block_produces_the_documented_json_shape

echo "# fm-dispatch-log.test.sh: all assertions passed"
