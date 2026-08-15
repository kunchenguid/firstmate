#!/usr/bin/env bash
# Behavioral contract for durable, honest task-metrics emission.
#
# The helper prepares a private recovery row before teardown destroys task
# inputs, commits that row exactly once afterward, and leaves fields null when
# the durable sources cannot attribute them mechanically.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

METRICS="$ROOT/bin/fm-task-metrics.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-metrics-tests)

# Keep every case hermetic: token attribution reads real harness stores under
# $HOME by default, so point each supported store at an absent path unless a case
# deliberately supplies its own fixture store.
export FM_CLAUDE_PROJECTS_ROOT="$TMP_ROOT/absent-claude-store"
export FM_CODEX_SESSIONS_ROOT="$TMP_ROOT/absent-codex-store"
export FM_PI_SESSIONS_ROOT="$TMP_ROOT/absent-pi-store"

make_case() {
  local dir="$TMP_ROOT/$1" fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/project" "$fakebin"
  git -C "$dir/project" init -q
  git -C "$dir/project" checkout -q -b fm/metric-task
  git -C "$dir/project" remote add origin https://github.com/example/widgets.git
  git -C "$dir/project" commit -q --allow-empty -m baseline
  printf '%s\n' "$dir"
}

write_meta() {
  local dir=$1 mode=${2:-no-mistakes}
  fm_write_meta "$dir/home/state/metric-task.meta" \
    "window=fleet:metric-task" \
    "endpoint_task_id=metric-task" \
    "worktree=$dir/project" \
    "project=$dir/project" \
    "harness=codex" \
    "kind=ship" \
    "mode=$mode" \
    "yolo=off" \
    "model=gpt-test" \
    "effort=high" \
    "dispatched_at=2026-08-13T20:00:00Z" \
    "pr=https://github.com/example/widgets/pull/17"
}

write_no_mistakes_db() {
  local dir=$1 sha
  local db="$dir/no-mistakes.sqlite"
  sha=$(git -C "$dir/project" rev-parse HEAD)
  python3 - "$db" "$dir/project" "$sha" <<'PY'
import sqlite3
import sys

db, project, sha = sys.argv[1:]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL, upstream_url TEXT);
CREATE TABLE runs (
  id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
  status TEXT NOT NULL, pr_url TEXT, last_pushed_sha TEXT, created_at INTEGER NOT NULL
);
CREATE TABLE step_results (
  id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, status TEXT NOT NULL
);
CREATE TABLE step_rounds (
  id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL,
  trigger_type TEXT NOT NULL
);
""")
con.execute("INSERT INTO repos VALUES (?, ?, ?)", ("repo-1", project, "https://github.com/example/widgets.git"))
con.executemany(
    "INSERT INTO runs VALUES (?, 'repo-1', 'fm/metric-task', ?, ?, ?, ?)",
    [
        ("run-1", "failed", None, sha, 10),
        ("run-2", "completed", "https://github.com/example/widgets/pull/17", sha, 20),
    ],
)
con.executemany(
    "INSERT INTO step_results VALUES (?, ?, ?, 'completed')",
    [
        ("review-1", "run-1", "review"),
        ("test-2", "run-2", "test"),
        ("document-2", "run-2", "document"),
    ],
)
con.executemany(
    "INSERT INTO step_rounds VALUES (?, ?, 2, 'auto_fix')",
    [
        ("round-review", "review-1"),
        ("round-test", "test-2"),
        ("round-doc", "document-2"),
    ],
)
con.commit()
PY
  printf '%s\n' "$db"
}

write_gh_axi() {
  local dir=$1
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    cat <<'OUT'
pull_request:
  number: 17
  title: "Metrics fixture"
  state: closed
  author: example
  draft: no
  merged: yes
  checks: "2 passed, 0 failed, 2 total"
OUT
    ;;
  "run list")
    exit 97
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi"
}

# The durable terminal observation bin/fm-classify-lib.sh writes when supervision
# first sees a task's done/failed report.
write_terminal_record() {
  local dir=$1 observed=$2
  printf '%s\n' \
    "observed_at=$observed" \
    'verb=done' \
    'events=1' \
    'status_size=14' \
    'source=supervision-observation' \
    > "$dir/home/state/metric-task.terminal-at"
}

# One claude transcript in a fixture store: session directory, working directory,
# first-record timestamp, and per-assistant usage, exactly as the harness writes.
write_claude_store() {
  local dir=$1 started=$2 cwd=$3 store
  store="$dir/claude-store/-fixture-project"
  mkdir -p "$store"
  {
    printf '{"timestamp":"%s","cwd":"%s","type":"user"}\n' "$started" "$cwd"
    printf '{"timestamp":"%s","cwd":"%s","message":{"usage":' "$started" "$cwd"
    printf '{"input_tokens":1200,"cache_creation_input_tokens":300,'
    printf '"cache_read_input_tokens":40000,"output_tokens":2500}}}\n'
  } > "$store/session-a.jsonl"
  printf '%s\n' "$dir/claude-store"
}

assert_row_contract() {
  local file=$1
  python3 - "$file" <<'PY' || fail "row contract assertions failed"
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert len(rows) == 1, rows
row = rows[0]
assert row["task"] == "metric-task", row
assert row["repo"] == "example/widgets", row
assert row["kind"] == "ship", row
assert row["mode"] == "no-mistakes", row
assert row["yolo"] is False, row
assert row["harness"] == "codex", row
assert row["model"] == "gpt-test", row
assert row["effort"] == "high", row
assert row["dispatched_at"] == "2026-08-13T20:00:00Z", row
assert row["done_at"] is None, row
assert row["wall_clock_min"] is None, row
assert row["blocked_min"] is None, row
assert row["pipeline_runs"] == 2, row
assert row["fix_rounds"] == 2, row
assert row["decisions_raised"] == 3, row
assert row["ci_green_first_push"] is None, row
assert row["outcome"] == "merged", row
assert row["pr"] == "https://github.com/example/widgets/pull/17", row
assert row["merged"] is True, row
for key in (
    "attribution", "corrections_required", "self_corrections",
    "tokens_consumed", "firstmate_interventions", "captain_interventions",
):
    assert row[key] is None, (key, row)
PY
}

test_prepare_commit_and_idempotency() {
  local dir db metrics receipt
  dir=$(make_case prepare-commit)
  write_meta "$dir"
  printf '%s\n' \
    'working: implementation started' \
    'needs-decision [key=one]: pick one' \
    'blocked [key=two]: credentials needed' \
    'resolved [key=two]: supplied' \
    'needs-decision: pick three' \
    'done: PR ready' > "$dir/home/state/metric-task.status"
  db=$(write_no_mistakes_db "$dir")
  write_gh_axi "$dir"
  metrics="$dir/home/data/task-metrics.jsonl"
  receipt="$dir/home/state/metric-task.task-metrics-row"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_NM_STATE_DB_OVERRIDE="$db" "$METRICS" prepare metric-task \
    || fail "prepare failed"
  assert_present "$receipt" "prepare did not publish the recovery row"
  assert_absent "$metrics" "prepare appended before teardown reached its commit point"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_NM_STATE_DB_OVERRIDE="$db" "$METRICS" commit metric-task \
    || fail "commit failed"
  assert_absent "$receipt" "commit left the recovery row behind"
  assert_row_contract "$metrics"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_NM_STATE_DB_OVERRIDE="$db" "$METRICS" emit metric-task \
    || fail "idempotent emit failed"
  assert_row_contract "$metrics"
  pass "task metrics: prepares before destruction, commits exactly once, and derives only durable fields"
}

test_missing_pipeline_records_stay_null() {
  local dir metrics
  dir=$(make_case missing-pipeline)
  write_meta "$dir"
  printf 'done: complete\n' > "$dir/home/state/metric-task.status"
  write_gh_axi "$dir"
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_NM_STATE_DB_OVERRIDE="$dir/absent.sqlite" "$METRICS" emit metric-task \
    || fail "emit should preserve unknown pipeline fields as null"
  python3 - "$metrics" <<'PY' || fail "null-field assertions failed"
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert row["pipeline_runs"] is None, row
assert row["fix_rounds"] is None, row
assert row["ci_green_first_push"] is None, row
assert row["tokens_consumed"] is None, row
PY
  pass "task metrics: unavailable pipeline attribution stays null instead of becoming a guess"
}

test_corrupt_destination_refuses_without_losing_receipt() {
  local dir receipt metrics
  dir=$(make_case corrupt-destination)
  write_meta "$dir" direct-PR
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_gh_axi "$dir"
  receipt="$dir/home/state/metric-task.task-metrics-row"
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$METRICS" prepare metric-task \
    || fail "prepare failed"
  printf 'not-json\n' > "$metrics"
  if PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$METRICS" commit metric-task \
      > "$dir/stdout" 2> "$dir/stderr"; then
    fail "commit accepted a corrupt append-only destination"
  fi
  assert_present "$receipt" "failed commit discarded its retryable receipt"
  [ "$(cat "$metrics")" = not-json ] || fail "failed commit changed the corrupt destination"
  pass "task metrics: corrupt output blocks completion and preserves the retry receipt"
}

test_orchestrator_is_recorded_apart_from_the_worker_with_handoffs() {
  local dir metrics
  dir=$(make_case orchestrator-identity)
  write_meta "$dir"
  printf '%s\n' 'orchestrator=claude' 'orchestrator_handoffs=codex,unknown' \
    >> "$dir/home/state/metric-task.meta"
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_gh_axi "$dir"
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$METRICS" emit metric-task \
    || fail "emit failed"
  python3 - "$metrics" <<'PY' || fail "orchestrator assertions failed"
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert row["orchestrator"] == "claude", row
assert row["harness"] == "codex", row
assert row["orchestrator_handoffs"] == ["codex", None], row
PY
  pass "task metrics: the dispatching orchestrator is recorded apart from the worker, with an undetectable relauncher kept visible as null"
}

test_absent_orchestrator_capture_stays_null() {
  local dir metrics
  dir=$(make_case orchestrator-absent)
  write_meta "$dir"
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_gh_axi "$dir"
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$METRICS" emit metric-task \
    || fail "emit failed"
  python3 - "$metrics" <<'PY' || fail "absent-orchestrator assertions failed"
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert row["orchestrator"] is None, row
assert row["orchestrator_handoffs"] is None, row
PY
  pass "task metrics: a task with no orchestrator capture reports null rather than a default"
}

test_wall_clock_comes_from_the_terminal_observation() {
  local dir metrics
  dir=$(make_case wall-clock)
  write_meta "$dir"
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_terminal_record "$dir" 2026-08-13T20:42:30Z
  write_gh_axi "$dir"
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$METRICS" emit metric-task \
    || fail "emit failed"
  python3 - "$metrics" <<'PY' || fail "wall-clock assertions failed"
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert row["done_at"] == "2026-08-13T20:42:30Z", row
assert row["done_at_source"] == "supervision-observation", row
assert row["wall_clock_min"] == 42.5, row
PY
  pass "task metrics: wall clock is derived from the durable terminal observation and names that provenance"
}

test_completion_before_dispatch_drops_the_duration() {
  local dir metrics
  dir=$(make_case wall-clock-contradictory)
  write_meta "$dir"
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_terminal_record "$dir" 2026-08-13T19:00:00Z
  write_gh_axi "$dir"
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$METRICS" emit metric-task \
    || fail "emit failed"
  python3 - "$metrics" <<'PY' || fail "contradictory-duration assertions failed"
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert row["done_at"] == "2026-08-13T19:00:00Z", row
assert row["wall_clock_min"] is None, row
PY
  pass "task metrics: a completion recorded before its dispatch keeps both timestamps and drops the impossible duration"
}

test_worker_token_burn_is_read_from_the_harness_store() {
  local dir metrics store
  dir=$(make_case token-attribution)
  write_meta "$dir"
  printf 'harness=claude\n' >> "$dir/home/state/metric-task.meta"
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_terminal_record "$dir" 2026-08-13T20:42:30Z
  write_gh_axi "$dir"
  store=$(write_claude_store "$dir" 2026-08-13T20:05:00Z "$dir/project")
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_CLAUDE_PROJECTS_ROOT="$store" "$METRICS" emit metric-task \
    || fail "emit failed"
  python3 - "$metrics" <<'PY' || fail "token assertions failed"
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert row["tokens_consumed"] == 44000, row
assert row["token_source"] == "claude-transcript", row
assert row["token_sessions"] == 1, row
assert row["token_input"] == 1500, row
assert row["token_cached_input"] == 40000, row
assert row["token_output"] == 2500, row
assert row["token_note"] is None, row
PY
  pass "task metrics: the worker's token burn is read from its own harness store with the source and components recorded"
}

test_a_session_outside_the_dispatch_window_is_not_attributed() {
  local dir metrics store
  dir=$(make_case token-window)
  write_meta "$dir"
  printf 'harness=claude\n' >> "$dir/home/state/metric-task.meta"
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_terminal_record "$dir" 2026-08-13T20:42:30Z
  write_gh_axi "$dir"
  # Started before this task was dispatched, so it belongs to the previous holder
  # of that worktree path.
  store=$(write_claude_store "$dir" 2026-08-13T18:00:00Z "$dir/project")
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_CLAUDE_PROJECTS_ROOT="$store" "$METRICS" emit metric-task \
    || fail "emit failed"
  python3 - "$metrics" <<'PY' || fail "token window assertions failed"
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert row["tokens_consumed"] is None, row
assert row["token_source"] is None, row
assert "within its dispatch window" in row["token_note"], row
PY
  pass "task metrics: a session that started before the task was dispatched is not attributed to it"
}

test_a_provider_without_token_records_says_so_precisely() {
  local dir metrics
  dir=$(make_case token-unsupported)
  write_meta "$dir"
  printf 'harness=cursor\n' >> "$dir/home/state/metric-task.meta"
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_terminal_record "$dir" 2026-08-13T20:42:30Z
  write_gh_axi "$dir"
  metrics="$dir/home/data/task-metrics.jsonl"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$METRICS" emit metric-task \
    || fail "emit failed"
  python3 - "$metrics" <<'PY' || fail "unsupported-provider assertions failed"
import json
import sys
row = json.loads(open(sys.argv[1], encoding="utf-8").readline())
assert row["tokens_consumed"] is None, row
assert row["token_note"] == (
    "no verified durable per-session token record for harness cursor"
), row
PY
  pass "task metrics: a provider with no durable per-session token record names itself in the null explanation"
}

test_a_dispatched_task_with_no_row_is_detectable() {
  local dir out
  dir=$(make_case audit-gap)
  write_meta "$dir"
  printf '%s\n' 'orchestrator=claude' >> "$dir/home/state/metric-task.meta"
  FM_HOME="$dir/home" "$METRICS" dispatch metric-task >/dev/null \
    || fail "dispatch ledger append failed"
  FM_HOME="$dir/home" "$METRICS" dispatch metric-task >/dev/null \
    || fail "repeated dispatch failed"
  [ "$(wc -l < "$dir/home/data/task-metrics-dispatches.jsonl")" -eq 1 ] \
    || fail "dispatch ledger duplicated one task"

  out=$(FM_HOME="$dir/home" "$METRICS" audit) || fail "audit failed"
  case "$out" in
    *"under way"*) ;;
    *) fail "audit did not treat a task still holding its record as under way" ;;
  esac
  case "$out" in
    *"gap: metric-task"*) fail "audit reported a live task as a missing row" ;;
  esac

  # Completion by some path that never emitted a row: the task's records are gone
  # and no row exists.
  rm -f "$dir/home/state/metric-task.meta"
  out=$(FM_HOME="$dir/home" "$METRICS" audit) || fail "audit failed after completion"
  case "$out" in
    *"gap: metric-task completed with no metrics row (dispatched 2026-08-13T20:00:00Z)"*) ;;
    *) fail "audit did not report the missing row: $out" ;;
  esac
  pass "task metrics: a task that completed without emitting a row is reported as a gap against the dispatch ledger"
}

test_a_prepared_but_uncommitted_row_is_reported_as_retryable() {
  local dir out
  dir=$(make_case audit-pending)
  write_meta "$dir"
  printf 'done: PR ready\n' > "$dir/home/state/metric-task.status"
  write_gh_axi "$dir"
  FM_HOME="$dir/home" "$METRICS" dispatch metric-task >/dev/null || fail "dispatch failed"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$METRICS" prepare metric-task >/dev/null \
    || fail "prepare failed"
  rm -f "$dir/home/state/metric-task.meta"

  out=$(FM_HOME="$dir/home" "$METRICS" audit) || fail "audit failed"
  case "$out" in
    *"pending: metric-task prepared row not committed"*) ;;
    *) fail "audit conflated a retryable prepared row with a lost one: $out" ;;
  esac
  case "$out" in
    *"gap: metric-task"*) fail "audit reported a retryable prepared row as a gap" ;;
  esac
  pass "task metrics: a prepared row awaiting its commit is reported as retryable rather than as a lost row"
}

test_prepare_commit_and_idempotency
test_missing_pipeline_records_stay_null
test_corrupt_destination_refuses_without_losing_receipt
test_orchestrator_is_recorded_apart_from_the_worker_with_handoffs
test_absent_orchestrator_capture_stays_null
test_wall_clock_comes_from_the_terminal_observation
test_completion_before_dispatch_drops_the_duration
test_worker_token_burn_is_read_from_the_harness_store
test_a_session_outside_the_dispatch_window_is_not_attributed
test_a_provider_without_token_records_says_so_precisely
test_a_dispatched_task_with_no_row_is_detectable
test_a_prepared_but_uncommitted_row_is_reported_as_retryable
