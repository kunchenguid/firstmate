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

make_fakebin() {
  local fake=$1
  mkdir -p "$fake"
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n' ;;
  list-windows) printf 'fm-local-ready\n' ;;
esac
SH
  cat > "$fake/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/tmux" "$fake/no-mistakes"
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
grep -q $'^alpha-task\tt1\tcalm-rows\t10\tgenerated\t$' "$file" || fail "title default or t1 allocation wrong"
grep -q $'^beta-task\tt2\tcrew-inbox\t10\tgenerated\t$' "$file" || fail "t2 allocation wrong"
grep -q $'^gamma-task\tt3\tready-queue\t10\tgenerated\t$' "$file" || fail "t3 allocation wrong"
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
if lookup "$home" t1 >/dev/null 2>&1; then fail "retired reference resolved during its cooldown"; fi
[ "$(lookup "$home" t4)" = delta-task ] || fail "cooling tombstone was not reserved during allocation"
[ "$(lookup "$home" t2)" = beta-task ] || fail "active reference changed during allocation"
FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" name t4 fresh-name >/dev/null || fail "explicit name assignment failed"
grep -q $'^delta-task\tt4\tfresh-name\t20\texplicit\t$' "$file" || fail "explicit name was not persisted"
if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" name t4 one >/dev/null 2>&1; then
  fail "one-token explicit shorthand was accepted"
fi
if FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" name t4 one-two-three-four-five >/dev/null 2>&1; then
  fail "description-length explicit name was accepted"
fi
cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] beta-task - Crew Inbox (repo: sample)
## Queued
- [ ] gamma-task - Ready Queue (repo: sample)
- [ ] delta-task - New Task (repo: sample)
- [ ] epsilon-task - Later Task (repo: sample)
## Done
EOF
sync "$home" 86420 || fail "post-cooldown reconciliation failed"
[ "$(lookup "$home" t1)" = epsilon-task ] || fail "oldest cooled reference was not recycled first"
pass "cooldown-safe recycling and independently editable concise names"

home2=$(make_home collisions)
cat > "$home2/data/backlog.md" <<'EOF'
## Queued
- [ ] one-task - Same Task (repo: sample)
- [ ] two-task - Same Task (repo: sample)
- [ ] three-task - Same Task (repo: sample)
- [ ] long-task - Implement Deterministic Collision Handling for Human Task Names (repo: sample)
## Done
EOF
sync "$home2" 30 || fail "collision sync failed"
file2="$home2/state/task-callsigns.tsv"
grep -q $'^one-task\tt1\tsame-task\t30\tgenerated\t$' "$file2" || fail "first collision name was not deterministic"
grep -q $'^two-task\tt2\tsame-task-2\t30\tgenerated\t$' "$file2" || fail "second collision suffix was not deterministic"
grep -q $'^three-task\tt3\tsame-task-3\t30\tgenerated\t$' "$file2" || fail "third collision suffix was not deterministic"
grep -q $'^long-task\tt4\tdeterministic-collision-handling\t30\tgenerated\t$' "$file2" \
  || fail "new task name was not reduced to a deterministic shorthand"
[ "$(lookup "$home2" same-task-2)" = two-task ] || fail "collision name did not resolve centrally"
if FM_HOME="$home2" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" name t2 same-task >/dev/null 2>&1; then fail "duplicate explicit name accepted"; fi
pass "generated collisions are deterministic and remain resolvable"

home_migration=$(make_home migration)
cat > "$home_migration/data/backlog.md" <<'EOF'
## In flight
- [ ] generated-task - Implement Deterministic Collision Handling for Human Task Names (repo: sample)
- [ ] explicit-task - Preserve This Existing Explicit Name (repo: sample)
## Done
EOF
printf 'version=1\n%s\n%s\n' \
  $'generated-task\tt7\timplement-deterministic-collision-handling-for-human-task-names\t5\t' \
  $'explicit-task\tt8\thand-picked-name\t5\t' \
  > "$home_migration/state/task-callsigns.tsv"
sync "$home_migration" 31 || fail "v1 migration failed"
migration_file="$home_migration/state/task-callsigns.tsv"
grep -q $'^version=2$' "$migration_file" || fail "callsign registry schema did not migrate"
grep -q $'^generated-task\tt7\tdeterministic-collision-handling\t5\tgenerated\t$' "$migration_file" \
  || fail "legacy generated name or reference did not migrate safely"
grep -q $'^explicit-task\tt8\thand-picked-name\t5\texplicit\t$' "$migration_file" \
  || fail "explicit v1 name or reference changed during migration"
pass "generated names migrate while canonical ids, references, and explicit names stay stable"

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
  {"id":"active-task","ref":"t1","name":"active-task","status":"unknown","outcome":"current state unavailable"},
  {"id":"waiting-task","ref":"t2","name":"waiting-task","status":"waiting","outcome":"external wait"},
  {"id":"blocked-task","ref":"t3","name":"blocked-task","status":"blocked","outcome":"waiting on active-task"},
  {"id":"input-task","ref":"t4","name":"needs-input","status":"needs-you","outcome":"captain input needs a decision about production behavior and careful rollout sequencing"},
  {"id":"done-task","ref":"t5","name":"done-task","status":"done","outcome":"Ready to close"}
]'
[ "$(printf '%s' "$json_wide" | jq -Sc .)" = "$(printf '%s' "$expected" | jq -Sc .)" ] \
  || fail "status normalization or JSON contract changed: $json_wide"
pass "status normalization reserves waiting for a stated external delay"

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

home_ready=$(make_home ready-local)
fakebin="$home_ready/fakebin"
make_fakebin "$fakebin"
mkdir -p "$home_ready/projects/local-ready"
cat > "$home_ready/data/backlog.md" <<'EOF'
## In flight
- [ ] local-ready - Finish Local Branch and Request Landing Approval (repo: sample)
## Queued
## Done
EOF
cat > "$home_ready/state/local-ready.meta" <<EOF
window=firstmate:fm-local-ready
worktree=$home_ready/projects/local-ready
project=sample
harness=claude
kind=ship
mode=local-only
EOF
ready_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home_ready/state" local-ready)
"$ROOT/bin/fm-busy-event.sh" apply "$home_ready/state" local-ready idle --gen "$ready_gen" \
  --source claude-hook --event stop
printf 'done: ready in branch fm/local-ready\n' > "$home_ready/state/local-ready.status"
ready_json=$(PATH="$fakebin:$PATH" FM_HOME="$home_ready" FM_ROOT_OVERRIDE="$ROOT" "$TASKS" --json) \
  || fail "ready local branch table failed"
printf '%s\n' "$ready_json" | jq -e '
  length == 1
    and .[0].status == "ready"
    and .[0].outcome == "ready in branch fm/local-ready; awaiting landing approval"
    and (.[0] | keys | sort) == ["id","name","outcome","ref","status"]
' >/dev/null || fail "completed local branch was not a useful ready row: $ready_json"
pass "completed local branches are ready while waiting remains an external-delay state"

home4=$(make_home empty)
: > "$home4/data/backlog.md"
empty=$(FM_HOME="$home4" FM_ROOT_OVERRIDE="$ROOT" COLUMNS=50 "$TASKS" --table) || fail "empty table command failed"
printf '%s\n' "$empty" | jq -Rsc '
  split("\n") | map(select(length > 0))
  | length == 4 and all(.[]; length == 50)
' >/dev/null || fail "empty table did not keep its bordered header"
printf '%s\n' "$empty" | grep -q '│ Ref ' || fail "empty table header missing"
pass "empty output remains a proper bordered table"
