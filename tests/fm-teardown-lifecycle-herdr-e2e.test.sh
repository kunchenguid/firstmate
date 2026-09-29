#!/usr/bin/env bash
set -euo pipefail
# All backend calls pass through the operator-provided named-session helper.
# No ambient Herdr session, default socket, or direct lifecycle call is used.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_HERDR_LIFECYCLE_E2E herdr jq python3 tasks-axi
if [ -z "${FM_HERDR_LAB_HELPER:-}" ] || [ -z "${FM_HERDR_LAB_TASK:-}" ]; then
  if [ "${FM_HERDR_LIFECYCLE_E2E:-${FM_LIVE:-0}}" = 1 ]; then
    fail 'set FM_HERDR_LAB_HELPER and FM_HERDR_LAB_TASK to the authorized isolated lab'
  fi
  echo 'skip: live: an explicitly authorized named Herdr lab helper is required'
  exit 0
fi
LAB_DIR=$(fm_test_tmproot fm-herdr-lifecycle)
mkdir -p "$LAB_DIR/home/data/t1" "$LAB_DIR/home/state" "$LAB_DIR/home/config"
export HERDR_LAB_HELPER="$FM_HERDR_LAB_HELPER"
export HERDR_LAB_SESSION
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "$FM_HERDR_LAB_TASK")
lab_cleanup() {
  local rc=$? cleanup_rc=0
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_rc=$?
  printf 'body_exit=%s cleanup_exit=%s\n' "$rc" "$cleanup_rc"
  test "$rc" = 0 && test "$cleanup_rc" = 0
}
trap lab_cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
call() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
cat > "$LAB_DIR/herdr-wrapper" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
[ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = "$HERDR_LAB_SESSION" ] || exit 98
exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]:0:$((n-2))}"
SH
chmod +x "$LAB_DIR/herdr-wrapper"
export FM_BACKEND_HERDR_BIN="$LAB_DIR/herdr-wrapper"
export FM_HOME="$LAB_DIR/home"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_HERDR_IDLE_SHELL_PROOF_POLLS=20
source "$ROOT/bin/fm-wake-lib.sh"
source "$ROOT/bin/backends/herdr.sh"
# Real backend behavior; synthetic task identities and no model processes.
call workspace create --label anchor --cwd "$ROOT" --focus > "$LAB_DIR/anchor.json"
anchor=$(jq -r '.result.workspace.workspace_id' "$LAB_DIR/anchor.json")
anchor_tab=$(jq -r '.result.tab.tab_id' "$LAB_DIR/anchor.json")
setup_task() {
  local id=$1 file=$2 gen=$3 path=$4 pane tab ws journal
  mkdir -p "$FM_HOME/data/$id"
  pane=$(jq -r '.result.pane.pane_id // .result.root_pane.pane_id' "$file")
  tab=$(jq -r '.result.tab.tab_id' "$file")
  ws=$(jq -r '.result.workspace.workspace_id // .result.tab.workspace_id' "$file")
  journal="$FM_HOME/state/$id.herdr-presentation"
  printf 'version=1\ntask_id=%s\nprojection_id=abcdefghijklmnopqrstuv\n' "$id" > "$journal"
  fm_backend_herdr_projection_journal_write_v2 "$journal" "$id" abcdefghijklmnopqrstuv "$FM_HOME" "$HERDR_LAB_SESSION" "$ws" "$tab" "$pane" "$anchor" anchor "$(fm_backend_herdr_projection_workspace_label "$id" abcdefghijklmnopqrstuv)" "fm-$id"
  fm_backend_herdr_projection_bind_execution "$journal" "$id" "$gen"
  cat > "$FM_HOME/state/$id.meta" <<EOF
backend=herdr
window=$HERDR_LAB_SESSION:$pane
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
worktree=$path
project=$ROOT
endpoint_task_id=$id
harness=codex
kind=ship
spawn_gen=$gen
EOF
  printf 'synthetic accepted task\n' > "$FM_HOME/data/$id/brief.md"
  printf 'retained final report\n' > "$FM_HOME/data/$id/report.md"
  python3 "$ROOT/bin/fm-task-lifecycle.py" init "$id" > "$LAB_DIR/initial.json"
  jq '.disposition="accepted" | .assessment.remaining_gap=""' "$LAB_DIR/initial.json" > "$LAB_DIR/accepted.json"
  chmod 600 "$LAB_DIR/accepted.json"
  "$ROOT/bin/fm-task-state.sh" reconcile "$id" --expected-revision 1 --record "$LAB_DIR/accepted.json" >/dev/null
}
call workspace create --label mixed --cwd "$ROOT" --no-focus > "$LAB_DIR/mixed.json"
mixed=$(jq -r '.result.workspace.workspace_id' "$LAB_DIR/mixed.json")
sibling=$(jq -r '.result.root_pane.pane_id' "$LAB_DIR/mixed.json")
call pane send-text "$sibling" 'sleep 300' >/dev/null
call pane send-keys "$sibling" Enter >/dev/null
sleep 1
call pane process-info --pane "$sibling" > "$LAB_DIR/sibling-before.json"
call tab create --workspace "$mixed" --label completed --cwd "$ROOT" --no-focus > "$LAB_DIR/completed.json"
setup_task mixed-task "$LAB_DIR/completed.json" s-mixed "$ROOT"
report_before=$(shasum -a 256 "$FM_HOME/data/mixed-task/report.md")
"$ROOT/bin/fm-teardown.sh" mixed-task --endpoint-only --expect-spawn-gen s-mixed
call pane process-info --pane "$sibling" > "$LAB_DIR/sibling-after.json"
diff -u "$LAB_DIR/sibling-before.json" "$LAB_DIR/sibling-after.json"
call workspace get "$mixed" >/dev/null
jq -e '.phases.agent_exit.state=="confirmed" and .phases.workspace_remove.reason_code=="mixed-workspace"' "$FM_HOME/state/mixed-task.cleanup.json"
test "$report_before" = "$(shasum -a 256 "$FM_HOME/data/mixed-task/report.md")"
printf 'PASS mixed workspace and active sibling process preserved\n'

call tab create --workspace "$mixed" --label already-absent --cwd "$ROOT" --no-focus > "$LAB_DIR/already-absent.json"
setup_task already-absent "$LAB_DIR/already-absent.json" s-absent "$ROOT"
absent_pane=$(jq -r '.result.pane.pane_id // .result.root_pane.pane_id' "$LAB_DIR/already-absent.json")
call pane close "$absent_pane" >/dev/null
"$ROOT/bin/fm-teardown.sh" already-absent --endpoint-only --expect-spawn-gen s-absent
jq -e '.phases.agent_exit.state=="retained" and .phases.agent_exit.reason_code=="agent-state-unknown" and .phases.pane_close.state=="confirmed"' "$FM_HOME/state/already-absent.cleanup.json"
printf 'PASS absent pane retains an independent unknown agent-exit obligation\n'

call workspace create --label missing-directory --cwd "$ROOT" --no-focus > "$LAB_DIR/missing.json"
setup_task missing-task "$LAB_DIR/missing.json" s-missing "$LAB_DIR/never-existed"
"$ROOT/bin/fm-teardown.sh" missing-task --endpoint-only --expect-spawn-gen s-missing
jq -e '.phases.workspace_remove.state=="confirmed" and .phases.directory_return.state=="retained"' "$FM_HOME/state/missing-task.cleanup.json"
printf 'PASS missing directory does not prevent exact dedicated workspace removal\n'

# Shared and dirty directory guards are independent of exact pane authority.
mkdir -p "$LAB_DIR/shared-copy"
printf 'uncommitted payload\n' > "$LAB_DIR/shared-copy/keep.txt"
git -C "$LAB_DIR/shared-copy" init -q
shared_hash=$(shasum -a 256 "$LAB_DIR/shared-copy/keep.txt")
for variant in dirty shared; do
  call workspace create --label "$variant" --cwd "$ROOT" --no-focus > "$LAB_DIR/$variant.json"
  setup_task "$variant-task" "$LAB_DIR/$variant.json" "s-$variant" "$LAB_DIR/shared-copy"
  "$ROOT/bin/fm-teardown.sh" "$variant-task" --endpoint-only --expect-spawn-gen "s-$variant"
  jq -e --arg why "retained-$variant" '(.phases.directory_return.reason_code | startswith($why)) and .phases.workspace_remove.state=="confirmed"' "$FM_HOME/state/$variant-task.cleanup.json"
  test "$shared_hash" = "$(shasum -a 256 "$LAB_DIR/shared-copy/keep.txt")"
done
printf 'PASS dirty and shared copy retained byte-for-byte while dedicated workspaces disappear\n'

# A stale duplicate endpoint claim cannot grant either record ownership.
call workspace create --label duplicate --cwd "$ROOT" --no-focus > "$LAB_DIR/duplicate.json"
setup_task duplicate "$LAB_DIR/duplicate.json" s-duplicate "$LAB_DIR/shared-copy"
cp "$FM_HOME/state/duplicate.meta" "$FM_HOME/state/stale-duplicate.meta"
if "$ROOT/bin/fm-teardown.sh" duplicate --endpoint-only --expect-spawn-gen s-duplicate; then exit 85; fi
jq -e '.phases.pane_close.reason_code=="duplicate-endpoint-claim"' "$FM_HOME/state/duplicate.cleanup.json"
call pane get "$(jq -r '.result.root_pane.pane_id' "$LAB_DIR/duplicate.json")" >/dev/null
rm "$FM_HOME/state/stale-duplicate.meta"
# Corrupt launch identity remains a cleanup obligation, with no endpoint call.
printf 'foreign=unverified\n' >> "$FM_HOME/state/duplicate.herdr-presentation"
if "$ROOT/bin/fm-teardown.sh" duplicate --endpoint-only --expect-spawn-gen s-duplicate; then exit 86; fi
call pane get "$(jq -r '.result.root_pane.pane_id' "$LAB_DIR/duplicate.json")" >/dev/null
printf 'PASS duplicate metadata and corrupt journal preserve the actual endpoint\n'

call workspace create --label identity-guard --cwd "$ROOT" --no-focus > "$LAB_DIR/identity.json"
setup_task identity-task "$LAB_DIR/identity.json" s-identity "$ROOT"
pane=$(jq -r '.result.root_pane.pane_id' "$LAB_DIR/identity.json")
if "$ROOT/bin/fm-teardown.sh" identity-task --endpoint-only --expect-spawn-gen old; then exit 81; fi
call pane get "$pane" >/dev/null
# Active target is distinct from the active sibling: its own process refuses close.
call pane send-text "$pane" 'sleep 300' >/dev/null
call pane send-keys "$pane" Enter >/dev/null
sleep 1
if "$ROOT/bin/fm-teardown.sh" identity-task --endpoint-only --expect-spawn-gen s-identity; then exit 82; fi
call pane get "$pane" >/dev/null
call pane send-keys "$pane" ctrl+c >/dev/null
printf 'PASS stale generation and active target refuse without removing endpoint\n'

# A viewer gives focus the same meaning as a real user interaction.
"$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION"
setup_task focused-task "$LAB_DIR/anchor.json" s-focus "$ROOT"
if "$ROOT/bin/fm-teardown.sh" focused-task --endpoint-only --expect-spawn-gen s-focus; then exit 83; fi
call workspace list > "$LAB_DIR/focus-after.json"
jq -e --arg ws "$anchor" '.result.workspaces[] | select(.workspace_id==$ws) | .focused==true' "$LAB_DIR/focus-after.json"
printf 'PASS focused user workspace retained\n'

# Force a backlog write failure after actual endpoint close. Recovery invokes
# only the existing close marker, and keeps the resource metadata and report.
call workspace create --label interrupted --cwd "$ROOT" --no-focus > "$LAB_DIR/interrupted.json"
setup_task interrupted "$LAB_DIR/interrupted.json" s-interrupted "$ROOT"
pane=$(jq -r '.result.root_pane.pane_id' "$LAB_DIR/interrupted.json")
real_tasks=$(command -v tasks-axi)
printf 'backend = "markdown"\n' > "$FM_HOME/.tasks.toml"
"$real_tasks" add interrupted 'Synthetic accepted task' --file "$FM_HOME/data/backlog.md" --start >/dev/null
mkdir -p "$LAB_DIR/fail-bin"
cat > "$LAB_DIR/fail-bin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = done ]; then echo 'injected backlog write failure' >&2; exit 1; fi
exec '$real_tasks' "\$@"
EOF
chmod +x "$LAB_DIR/fail-bin/tasks-axi"
if PATH="$LAB_DIR/fail-bin:$PATH" "$ROOT/bin/fm-teardown.sh" interrupted --endpoint-only --expect-spawn-gen s-interrupted; then exit 84; fi
test -f "$FM_HOME/state/interrupted.backlog-close"
call pane list > "$LAB_DIR/interrupted-after.json"
jq -e --arg pane "$pane" '.result.panes | all(.pane_id!=$pane)' "$LAB_DIR/interrupted-after.json"
source "$ROOT/bin/fm-tasks-axi-lib.sh"
source "$ROOT/bin/fm-backlog-transition-lib.sh"
fm_backlog_close_marker_replay "$FM_HOME/state" "$FM_HOME/state/interrupted.backlog-close" "$FM_HOME/data"
test -f "$FM_HOME/state/interrupted.meta"
test ! -e "$FM_HOME/state/interrupted.backlog-close"
"$real_tasks" show interrupted --file "$FM_HOME/data/backlog.md" | grep 'state: done'
printf 'PASS interrupted endpoint cleanup replays bookkeeping only and retains task records\n'
