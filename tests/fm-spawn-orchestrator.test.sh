#!/usr/bin/env bash
# Behavior tests for the orchestrator identity and dispatch ledger bin/fm-spawn.sh
# records at dispatch.
#
# Every other identity field in a task's record describes the WORKER. The captain
# switches the runtime firstmate ITSELF runs on between providers as well, so
# without this capture an entire axis of the provider comparison is invisible -
# and invisible in rows that otherwise look complete (docs/task-metrics.md).
#
# These tests drive a real fm-spawn through metadata writing with a fake tmux
# pane and a real isolated git worktree, so they assert the durable record a
# dispatch leaves rather than the detection helper in isolation. The relaunch
# handoff chain is covered where relaunch itself is owned, in
# tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orchestrator)

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# A case with one ready ship brief, a real worktree, and a fake pane.
make_case() {  # <name> <task-id>
  local dir="$TMP_ROOT/$1" id=$2 fakebin
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/home/config" "$dir/home/projects"
  printf 'claude\n' > "$dir/home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$dir/home/data/$id/brief.md"
  fm_git_worktree "$dir/project" "$dir/wt" "task-$id"
  touch "$dir/home/state/.last-watcher-beat"
  printf '%s\n' "$dir|$fakebin"
}

read_case() {  # <record>
  IFS='|' read -r CASE_DIR FAKEBIN <<EOF
$1
EOF
}

run_spawn() {  # <case-dir> <fakebin> <args...>
  local dir=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$dir/wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

test_a_dispatch_records_the_runtime_firstmate_itself_was_on() {
  local rec id out
  id=orch-z1
  rec=$(make_case detected "$id")
  read_case "$rec"

  out=$(FM_ORCHESTRATOR_OVERRIDE=codex \
    run_spawn "$CASE_DIR" "$FAKEBIN" "$id" "$CASE_DIR/project") \
    || fail "spawn failed: $out"
  [ "$(meta_field "$CASE_DIR" "$id" orchestrator)" = codex ] \
    || fail "the dispatching orchestrator was not recorded"
  [ "$(meta_field "$CASE_DIR" "$id" harness)" = claude ] \
    || fail "the worker harness should be unaffected by the orchestrator capture"
  pass "spawn: a dispatch records the runtime firstmate itself was on, apart from the worker's"
}

test_an_undetectable_orchestrator_writes_no_line() {
  local rec id out
  id=orch-z2
  rec=$(make_case undetectable "$id")
  read_case "$rec"

  out=$(FM_ORCHESTRATOR_OVERRIDE=unknown \
    run_spawn "$CASE_DIR" "$FAKEBIN" "$id" "$CASE_DIR/project") \
    || fail "spawn failed: $out"
  assert_grep 'harness=claude' "$CASE_DIR/home/state/$id.meta" \
    "the dispatch did not write the task record these assertions read"
  ! grep -q '^orchestrator=' "$CASE_DIR/home/state/$id.meta" \
    || fail "an undetectable orchestrator was recorded as a value"
  pass "spawn: an undetectable orchestrator records nothing, so the metrics row reports null rather than a default"
}

test_a_dispatch_is_recorded_in_the_ledger_a_missing_row_is_audited_against() {
  local rec id out ledger
  id=orch-z3
  rec=$(make_case ledger "$id")
  read_case "$rec"
  ledger="$CASE_DIR/home/data/task-metrics-dispatches.jsonl"

  out=$(FM_ORCHESTRATOR_OVERRIDE=claude \
    run_spawn "$CASE_DIR" "$FAKEBIN" "$id" "$CASE_DIR/project") \
    || fail "spawn failed: $out"
  assert_present "$ledger" "the dispatch was not recorded in the ledger"
  python3 - "$ledger" "$id" <<'PY' || fail "ledger assertions failed"
import json
import sys

path, task = sys.argv[1:]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(rows) == 1, rows
row = rows[0]
assert row["task"] == task, row
assert row["kind"] == "ship", row
assert row["mode"] == "no-mistakes", row
assert row["harness"] == "claude", row
assert row["orchestrator"] == "claude", row
assert row["dispatched_at"].endswith("Z"), row
PY
  pass "spawn: a dispatch is recorded in the ledger a missing metrics row is audited against"
}

test_a_secondmate_home_is_not_recorded_as_dispatched_work() {
  local rec id out sm
  id=orch-z4
  rec=$(make_case secondmate "$id")
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$CASE_DIR/home" \
    FM_STATE_OVERRIDE="$CASE_DIR/home/state" FM_DATA_OVERRIDE="$CASE_DIR/home/data" \
    FM_PROJECTS_OVERRIDE="$CASE_DIR/home/projects" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE_DIR/wt" TMUX="fake,1,0" \
    FM_ORCHESTRATOR_OVERRIDE=claude PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$sm" --secondmate 2>&1) || fail "secondmate spawn failed: $out"
  assert_absent "$CASE_DIR/home/data/task-metrics-dispatches.jsonl" \
    "a persistent secondmate home was recorded as a dispatched work item"
  pass "spawn: a persistent secondmate home is not recorded as dispatched work"
}

test_a_dispatch_records_the_runtime_firstmate_itself_was_on
test_an_undetectable_orchestrator_writes_no_line
test_a_dispatch_is_recorded_in_the_ledger_a_missing_row_is_audited_against
test_a_secondmate_home_is_not_recorded_as_dispatched_work

echo "# all fm-spawn-orchestrator tests passed"
