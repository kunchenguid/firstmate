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

make_case() {
  local name=$1 dir="$TMP_ROOT/$1" fakebin
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
  local dir=$1 db="$dir/no-mistakes.sqlite" sha
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
    cat <<'OUT'
count: 2
runs[2]{id,title,status,conclusion,workflow,branch,event,created}:
  101,"portable tests",completed,success,CI,fm/metric-task,pull_request,1m ago
  102,"lint",completed,success,CI,fm/metric-task,pull_request,1m ago
OUT
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi"
}

assert_row_contract() {
  local file=$1
  python3 - "$file" <<'PY'
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
assert row["ci_green_first_push"] is True, row
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
  python3 - "$metrics" <<'PY'
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

test_prepare_commit_and_idempotency
test_missing_pipeline_records_stay_null
test_corrupt_destination_refuses_without_losing_receipt
