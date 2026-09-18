#!/usr/bin/env bash
# Upgrade and idempotence tests for task artifact migration.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIGRATE="$ROOT/bin/fm-task-data-migrate.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-data-migrate)
HOME_DIR="$TMP_ROOT/home"
DATA="$HOME_DIR/data"
STATE="$HOME_DIR/state"
mkdir -p "$DATA" "$STATE" "$HOME_DIR/config"

cat > "$DATA/backlog.md" <<'EOF'
## In flight
- [ ] active-scout - Active scout (kind: scout)
- [ ] active-ship - Active ship (kind: ship)
- [ ] mate-charter - Persistent mate (kind: secondmate)

## Queued
- [ ] held-report - Held report data/held-report/report.md (kind: scout) (hold: captain choice) (hold-kind: captain)

## Done
- [x] completed-report - Completed report data/completed-report/report.md (kind: scout) (reported 2026-01-01)
EOF

printf 'kind=scout\n' > "$STATE/active-scout.meta"
printf 'kind=ship\n' > "$STATE/active-ship.meta"
printf 'kind=secondmate\n' > "$STATE/mate-charter.meta"

mkdir -p "$DATA/active-scout" "$DATA/active-ship" "$DATA/mate-charter" \
  "$DATA/held-report" "$DATA/completed-report" "$DATA/tasks/interrupted" \
  "$DATA/interrupted" "$DATA/closed-tasks" "$DATA/task-lifecycle" \
  "$DATA/unknown" "$DATA/.malformed"
printf 'active scout\n' > "$DATA/active-scout/brief.md"
printf 'active ship\n' > "$DATA/active-ship/brief.md"
printf 'mate charter\n' > "$DATA/mate-charter/brief.md"
printf 'Write findings to data/held-report/report.md.\n' > "$DATA/held-report/brief.md"
printf 'held findings\n' > "$DATA/held-report/report.md"
printf 'completed findings\n' > "$DATA/completed-report/report.md"
printf 'interrupted brief\n' > "$DATA/tasks/interrupted/brief.md"
printf 'interrupted report\n' > "$DATA/interrupted/report.md"
printf 'do not move\n' > "$DATA/closed-tasks/report.md"
printf 'do not move\n' > "$DATA/task-lifecycle/report.md"
printf 'not a task artifact\n' > "$DATA/unknown/notes.txt"
printf 'not a valid task directory\n' > "$DATA/.malformed/report.md"

run_migrate() {
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" TASKS_AXI_BACKEND=markdown "$MIGRATE"
}

first=$(run_migrate)
assert_contains "$first" 'skip: ' 'migration inventories and reports skipped entries'
assert_present "$DATA/tasks/held-report/report.md" 'held report moved to canonical storage'
assert_present "$DATA/tasks/completed-report/report.md" 'completed report moved to canonical storage'
assert_present "$DATA/tasks/mate-charter/brief.md" 'secondmate charter moved to canonical storage'
assert_present "$DATA/tasks/interrupted/brief.md" 'interrupted destination retained its existing artifact'
assert_present "$DATA/tasks/interrupted/report.md" 'interrupted legacy artifact completed its merge'
assert_absent "$DATA/held-report" 'held legacy directory was removed'
assert_absent "$DATA/completed-report" 'completed legacy directory was removed'
assert_absent "$DATA/mate-charter" 'secondmate legacy directory was removed'
assert_absent "$DATA/interrupted" 'interrupted legacy directory was removed'
assert_present "$DATA/active-scout/brief.md" 'active scout was preserved for a later migration'
assert_present "$DATA/active-ship/brief.md" 'active ship was preserved for a later migration'
assert_present "$DATA/closed-tasks/report.md" 'closed-tasks was not treated as a task'
assert_present "$DATA/task-lifecycle/report.md" 'task-lifecycle was not treated as a task'
assert_present "$DATA/unknown/notes.txt" 'unknown directory was not moved merely because it is a directory'
assert_present "$DATA/.malformed/report.md" 'malformed directory was not moved'
assert_contains "$(cat "$DATA/tasks/held-report/brief.md")" 'data/tasks/held-report/report.md' \
  'migrated instructions point to the canonical report'
assert_contains "$(cat "$DATA/backlog.md")" 'data/tasks/held-report/report.md' \
  'held backlog report link was updated through tasks-axi'
assert_contains "$(cat "$DATA/backlog.md")" 'data/tasks/completed-report/report.md' \
  'completed backlog report link was updated through tasks-axi'
assert_not_contains "$(cat "$DATA/backlog.md")" 'data/held-report/report.md' \
  'legacy held report link was removed from the backlog'

second=$(run_migrate)
assert_not_contains "$second" '->' 'repeated migration has no moves or merges'
assert_present "$DATA/tasks/held-report/report.md" 'repeated migration preserves held report'
assert_present "$DATA/tasks/interrupted/report.md" 'repeated migration preserves interrupted recovery'

pass "task artifact migration inventories safely, preserves active work, updates links, and is idempotent"
