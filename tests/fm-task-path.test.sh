#!/usr/bin/env bash
# Behavior tests for the single owner of per-task artifact paths.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-path-lib.sh disable=SC1091
. "$ROOT/bin/fm-task-path-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-path)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA/tasks/task-a" "$DATA/task-b" "$DATA/global" "$DATA/closed-tasks" \
  "$DATA/task-lifecycle" "$DATA/unknown"
: > "$DATA/tasks/task-a/report.md"
: > "$DATA/task-b/contributions.json"
: > "$DATA/task-b/brief.md"

assert_equals "${DATA}/tasks/task-a" "$(fm_task_dir "$DATA" task-a)" \
  "new task directories use data/tasks/<id>"
assert_equals "${DATA}/tasks/task-a/brief.md" "$(fm_task_path "$DATA" task-a brief.md)" \
  "new artifact paths are rooted in the canonical task directory"
assert_equals "${DATA}/task-b/brief.md" "$(fm_task_read_path "$DATA" task-b brief.md)" \
  "reads fall back to the legacy task directory"
assert_equals "data/tasks/task-a/report.md" "$(fm_task_relpath task-a report.md)" \
  "stored report paths use the canonical relative spelling"
assert_equals "data/task-b/report.md" "$(fm_task_legacy_relpath task-b report.md)" \
  "the legacy relative spelling remains available to migration"

paths=$(fm_task_artifact_paths "$DATA" report.md)
assert_equals "${DATA}/tasks/task-a/report.md" "$paths" \
  "artifact inventory prefers canonical paths and ignores non-task directories"

if fm_task_dir "$DATA" ../escape >/dev/null 2>&1; then
  fail "path owner accepted a traversal task id"
fi
if fm_task_path "$DATA" task-a ../escape >/dev/null 2>&1; then
  fail "path owner accepted a traversal artifact path"
fi

pass "per-task artifact paths have one validated owner with bounded legacy reads"
