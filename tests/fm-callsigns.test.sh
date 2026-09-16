#!/usr/bin/env bash
# Deterministic behavior tests for private task references, names, and the table.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB="$ROOT/bin/fm-callsigns-lib.sh"
TASKS="$ROOT/bin/fm-tasks.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-callsigns-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok: $1"; }

make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

sync() { FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" bash -c '. "$1"; fm_callsigns_sync "$2"' _ "$LIB" "$2"; }
lookup() { FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" bash -c '. "$1"; fm_callsign_resolve "$2"' _ "$LIB" "$2"; }

home=$(make_home allocation)
cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] alpha-task - Calm Rows (repo: sample)
- [ ] beta-task - Crew Inbox (repo: sample)
## Queued
- [ ] gamma-task - Ready Queue (repo: sample)
## Done
EOF
sync "$home" 10 || fail "initial sync failed"
file="$home/state/task-callsigns.tsv"
grep -q $'^alpha-task\tt1\tcalm-rows\t10\t$' "$file" || fail "title default or t1 allocation wrong"
grep -q $'^beta-task\tt2\tcrew-inbox\t10\t$' "$file" || fail "t2 allocation wrong"
grep -q $'^gamma-task\tt3\tready-queue\t10\t$' "$file" || fail "t3 allocation wrong"
old=$(cat "$file")
sync "$home" 11 || fail "repeat sync failed"
[ "$old" = "$(cat "$file")" ] || fail "repeat sync changed persisted assignments"
[ "$(lookup "$home" t2)" = beta-task ] || fail "reference resolution failed"
[ "$(lookup "$home" calm-rows)" = alpha-task ] || fail "human name resolution failed"
pass "allocation, persistence, and reference/name resolution"

cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] beta-task - Crew Inbox (repo: sample)
## Queued
- [ ] gamma-task - Ready Queue (repo: sample)
- [ ] delta-task - New Task (repo: sample)
## Done
EOF
sync "$home" 20 || fail "reconciliation sync failed"
[ "$(lookup "$home" t1)" = delta-task ] || fail "oldest retired reference was not recycled first"
[ "$(lookup "$home" t2)" = beta-task ] || fail "active reference changed during recycling"
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" name t1 fresh-name >/dev/null || fail "explicit name assignment failed"
grep -q $'^delta-task\tt1\tfresh-name\t20\t$' "$file" || fail "explicit name was not persisted"
pass "recycling and independently editable names"

home2=$(make_home ambiguity)
cat > "$home2/data/backlog.md" <<'EOF'
## Queued
- [ ] one-task - Same Task (repo: sample)
- [ ] two-task - Same Task (repo: sample)
## Done
EOF
sync "$home2" 30 || fail "ambiguity sync failed"
if lookup "$home2" same-task >/dev/null 2>&1; then fail "ambiguous human name resolved"; fi
if FM_HOME="$home2" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" name t1 same-task >/dev/null 2>&1; then fail "duplicate explicit name accepted"; fi
pass "ambiguity is refused"

home3=$(make_home statuses)
cat > "$home3/data/backlog.md" <<'EOF'
## In flight
- [ ] active-task - Active Task (repo: sample)
- [ ] waiting-task - Waiting Task (repo: sample) (hold: external wait) (hold-kind: external)
## Queued
- [ ] blocked-task - Blocked Task (repo: sample) blocked-by: active-task
- [ ] input-task - Needs Input (repo: sample) (hold: captain input needs a decision about production behavior and careful rollout sequencing) (hold-kind: captain)
## Done
- [x] done-task - Done Task (repo: sample) (done 2026-01-01)
EOF
sync "$home3" 40 || fail "status sync failed"
json_wide=$(FM_HOME="$home3" FM_ROOT_OVERRIDE="$ROOT" COLUMNS=120 "$TASKS" --json) || fail "JSON command failed"
json_narrow=$(FM_HOME="$home3" FM_ROOT_OVERRIDE="$ROOT" COLUMNS=40 "$TASKS" --json) || fail "narrow JSON command failed"
[ "$json_wide" = "$json_narrow" ] || fail "terminal width changed JSON output"
expected='[
  {"id":"active-task","ref":"t1","name":"active-task","status":"waiting","outcome":"waiting"},
  {"id":"waiting-task","ref":"t2","name":"waiting-task","status":"waiting","outcome":"waiting"},
  {"id":"blocked-task","ref":"t3","name":"blocked-task","status":"blocked","outcome":"waiting on active-task"},
  {"id":"input-task","ref":"t4","name":"needs-input","status":"needs-you","outcome":"captain input needs a decision about production behavior and careful rollout sequencing"},
  {"id":"done-task","ref":"t5","name":"done-task","status":"done","outcome":"completed"}
]'
[ "$(printf '%s' "$json_wide" | jq -Sc .)" = "$(printf '%s' "$expected" | jq -Sc .)" ] \
  || fail "status normalization or JSON contract changed: $json_wide"
pass "status normalization and JSON output remain unchanged"

table=$(FM_HOME="$home3" FM_ROOT_OVERRIDE="$ROOT" COLUMNS=80 "$TASKS" --table) || fail "table command failed"
printf '%s\n' "$table" | grep -q '^┌.*┬.*┐$' || fail "top border missing"
printf '%s\n' "$table" | grep -q '^├.*┼.*┤$' || fail "header border missing"
printf '%s\n' "$table" | grep -q '^└.*┴.*┘$' || fail "bottom border missing"
printf '%s\n' "$table" | grep -q 'captain input needs a decision' || fail "wrapped outcome first line missing"
printf '%s\n' "$table" | grep -q 'about production behavior and' || fail "wrapped outcome continuation missing"
printf '%s\n' "$table" | grep -q 'careful rollout sequencing' || fail "wrapped outcome final line missing"
printf '%s\n' "$table" | grep -q '^| Ref |' && fail "Markdown table source leaked"
printf '%s\n' "$table" | jq -Rsc '
  split("\n") | map(select(length > 0))
  | length > 4 and all(.[]; length == 80)
' >/dev/null || fail "wide table columns are not aligned to 80 cells"
pass "bordered table aligns columns and wraps current outcomes"

narrow=$(FM_HOME="$home3" FM_ROOT_OVERRIDE="$ROOT" COLUMNS=40 "$TASKS" --table) || fail "narrow table command failed"
printf '%s\n' "$narrow" | jq -Rsc '
  split("\n") | map(select(length > 0))
  | length > 4 and all(.[]; length == 40)
' >/dev/null || fail "narrow table exceeded or underfilled its 40-cell width"
printf '%s\n' "$narrow" | grep -q '│ Current ' || fail "narrow header was not wrapped inside its cell"
pass "narrow tables stay aligned within the available width"

home4=$(make_home empty)
: > "$home4/data/backlog.md"
empty=$(FM_HOME="$home4" FM_ROOT_OVERRIDE="$ROOT" COLUMNS=50 "$TASKS" --table) || fail "empty table command failed"
printf '%s\n' "$empty" | jq -Rsc '
  split("\n") | map(select(length > 0))
  | length == 4 and all(.[]; length == 50)
' >/dev/null || fail "empty table did not keep its bordered header"
printf '%s\n' "$empty" | grep -q '│ Ref ' || fail "empty table header missing"
pass "empty output remains a proper bordered table"
