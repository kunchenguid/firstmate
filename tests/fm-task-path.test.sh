#!/usr/bin/env bash
# Behavior tests for the single owner of per-task artifact paths.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-path-lib.sh disable=SC1091
. "$ROOT/bin/fm-task-path-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-path)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA" "$DATA/global" "$DATA/task-a" "$DATA/task-b"
: > "$DATA/task-a/report.md"
: > "$DATA/task-b/contributions.json"

assert_equals "${DATA}/task-a" "$(fm_task_dir "$DATA" task-a)" \
  "task directories use the existing data/<id> layout"
assert_equals "${DATA}/task-a/brief.md" "$(fm_task_path "$DATA" task-a brief.md)" \
  "artifact paths are rooted in the task directory"
assert_equals "data/task-a/report.md" "$(fm_task_relpath task-a report.md)" \
  "stored report paths use the existing relative spelling"

paths=$(fm_task_artifact_paths "$DATA" report.md)
assert_equals "${DATA}/task-a/report.md" "$paths" \
  "artifact inventory ignores non-task directories and absent artifacts"

if fm_task_dir "$DATA" ../escape >/dev/null 2>&1; then
  fail "path owner accepted a traversal task id"
fi
if fm_task_path "$DATA" task-a ../escape >/dev/null 2>&1; then
  fail "path owner accepted a traversal artifact path"
fi

pass "per-task artifact paths have one validated owner"
