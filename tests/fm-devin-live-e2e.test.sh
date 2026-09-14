#!/usr/bin/env bash
# Opt-in real Devin/Herdr guard: initial prompt, detection, native busy state,
# fm-send steer, double-Escape interrupt, exit and same-task fm-spawn relaunch.
# Usage: FM_DEVIN_LIVE=1 tests/fm-devin-live-e2e.test.sh
# Every Herdr call (including those made inside Firstmate scripts) is routed
# through the lab helper, and teardown verifies its default-session tripwire.
set -eu
if [ "${FM_DEVIN_LIVE:-0}" != 1 ]; then
  echo 'skip - set FM_DEVIN_LIVE=1 for credentialed Devin/Herdr verification'
  exit 0
fi
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-devin-lib.sh
. "$ROOT/bin/fm-devin-lib.sh"
BIN=$(fm_devin_resolve_binary) || fail 'Devin is absent; no live verification performed'
command -v herdr >/dev/null || fail 'Herdr is absent; no live verification performed'
VERSION=$("$BIN" --version)
MODEL=${FM_DEVIN_LIVE_MODEL:-swe-2-high}
fm_devin_preflight "$BIN" "$MODEL" dangerous || fail "$VERSION preflight failed"
BASE=$(fm_test_tmproot fm-devin-live)
export FM_HOME="$BASE/home" FM_HERDR_LAB_STATE_DIR="$BASE/tripwires"
export FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_PROJECTS_OVERRIDE=''
mkdir -p "$FM_HOME/state" "$FM_HOME/data/probe" "$FM_HOME/config" "$BASE/shim"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
touch "$FM_HOME/state/.last-watcher-beat"
fm_git_worktree "$BASE/project" "$BASE/work" smoke
printf '%s\n' '# Verification workspace' 'Execute only the smoke prompt; do not inspect other projects or run Firstmate supervision.' > "$BASE/work/AGENTS.md"
LIVE_PATH=$PATH
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name devin-harness-adapter-v1)
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ -n "${pane:-}" ]; then
    PATH="$LIVE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" > "$BASE/failure-pane.txt" 2>&1 || true
  fi
  PATH="$LIVE_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  if [ "$rc" -ne 0 ]; then
    echo "FAIL - $VERSION; evidence retained at $BASE" >&2
  else
    echo "ok - $VERSION live guard; evidence at $BASE"
  fi
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
export HERDR_SESSION="$HERDR_LAB_SESSION" FM_TEST_LAB_HELPER="$HERDR_LAB_HELPER"
export FM_TEST_LAB_SESSION="$HERDR_LAB_SESSION" FM_TEST_REAL_PATH="$PATH"
cat > "$BASE/shim/herdr" <<'SH'
#!/bin/bash
set -eu
args=() selected= after=0
while [ "$#" -gt 0 ]; do
  if [ "$1" = -- ] ; then after=1; fi
  if [ "$after" = 0 ] && [ "$1" = --session ]; then
    selected=$2; shift 2; continue
  fi
  args+=("$1"); shift
done
if [ -z "$selected" ]; then
  # The backend version check reads client metadata only. Even that read is
  # explicitly scoped to this lab instead of inspecting the default session.
  [ "${args[*]}" = 'status --json' ] || { echo 'unscoped Herdr call refused' >&2; exit 1; }
else
  [ "$selected" = "$FM_TEST_LAB_SESSION" ] || { echo 'foreign Herdr session refused' >&2; exit 1; }
fi
PATH="$FM_TEST_REAL_PATH" exec "$FM_TEST_LAB_HELPER" run "$FM_TEST_LAB_SESSION" "${args[@]}"
SH
chmod +x "$BASE/shim/herdr"
export PATH="$BASE/shim:$PATH"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
workspace=$(fm_backend_herdr_cli "$HERDR_LAB_SESSION" workspace create --cwd "$BASE/work" --label Devin-smoke --no-focus)
pane=$(printf '%s' "$workspace" | jq -er '.result.root_pane.pane_id')
ws=$(printf '%s' "$workspace" | jq -er '.result.workspace.workspace_id')
tab=$(printf '%s' "$workspace" | jq -er '.result.tab.tab_id')
target="$HERDR_LAB_SESSION:$pane"
cat > "$FM_HOME/state/probe.meta" <<EOF
harness=devin
endpoint_task_id=probe
kind=scout
backend=herdr
window=$target
worktree=$BASE/work
project=$BASE/project
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
model=$MODEL
effort=default
permission_mode=dangerous
x_request=devin-live-probe
EOF
printf 'Run bash %s/bin/fm-harness.sh > detected.txt, then reply exactly INITIAL_DONE. No other actions.\n' "$ROOT" > "$FM_HOME/data/probe/brief.md"
fm_devin_start "$target" "$BIN" "$FM_HOME/data/probe/brief.md" "$MODEL" dangerous
fm_backend_herdr_cli "$HERDR_LAB_SESSION" pane wait-output "$pane" --regex '^ INITIAL_DONE$' --timeout 90000 > "$BASE/initial.json"
[ "$(cat "$BASE/work/detected.txt")" = devin ] || fail "$VERSION tool detection failed"
fm_backend_herdr_cli "$HERDR_LAB_SESSION" agent wait "$pane" --until idle --timeout 15000 >/dev/null
[ "$(FM_COMPOSER_HARNESS=devin fm_backend_herdr_composer_state "$target")" = empty ] \
  || fail "$VERSION idle Devin composer was not recognized"
"$ROOT/bin/fm-send.sh" probe 'Run sleep 15, then reply STEER_DONE. Do nothing else.' > "$BASE/send.txt"
fm_backend_herdr_cli "$HERDR_LAB_SESSION" agent wait "$pane" --until working --timeout 15000 > "$BASE/busy.json"
"$ROOT/bin/fm-crew-state.sh" probe > "$BASE/crew-state.txt"
grep -q 'busy' "$BASE/crew-state.txt" || fail "$VERSION busy state was not visible to crew-state"
"$ROOT/bin/fm-control.sh" probe interrupt > "$BASE/interrupt.txt"
fm_backend_herdr_cli "$HERDR_LAB_SESSION" agent wait "$pane" --until idle --timeout 20000 > "$BASE/idle.json"
fm_backend_herdr_cli "$HERDR_LAB_SESSION" pane read "$pane" > "$BASE/interrupted.txt"
"$ROOT/bin/fm-send.sh" probe 'The previous request is cancelled. Run printf followup > followup.txt and finish. Do nothing else.' > "$BASE/followup-send.txt"
for _ in {1..90}; do
  [ ! -f "$BASE/work/followup.txt" ] || break
  sleep 1
done
[ "$(cat "$BASE/work/followup.txt" 2>/dev/null)" = followup ] || fail "$VERSION follow-up was not processed"
fm_backend_herdr_cli "$HERDR_LAB_SESSION" agent wait "$pane" --until idle --timeout 30000 > "$BASE/followup.json"
"$ROOT/bin/fm-control.sh" probe exit > "$BASE/exit.txt"
[ "$(fm_backend_herdr_agent_state "$target")" = dead ] || fail "$VERSION exit did not leave an agent-free pane"
# Run the complete same-task spawn path with an explicit permission override,
# then a same-harness relaunch that must retain it. No work is discarded.
printf '%s\n' 'Reply exactly RELAUNCH_DONE. Do not use tools.' > "$FM_HOME/data/probe/brief.md"
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" probe --relaunch --model "$MODEL" --permission-mode auto > "$BASE/relaunch.txt"
fm_backend_herdr_cli "$HERDR_LAB_SESSION" pane wait-output "$pane" --regex '^ RELAUNCH_DONE$' --timeout 90000 > "$BASE/relaunched.json"
test "$(grep -c '^permission_mode=auto$' "$FM_HOME/state/probe.meta")" -eq 1 || fail 'explicit permission override was not authoritative'
test "$(grep -c '^permission_mode=' "$FM_HOME/state/probe.meta")" -eq 1 || fail 'relaunch wrote duplicate permission metadata'
grep -q '^x_request=devin-live-probe$' "$FM_HOME/state/probe.meta" || fail 'relaunch discarded unrelated metadata'
"$ROOT/bin/fm-control.sh" probe exit > "$BASE/relaunch-exit.txt"
printf '%s\n' 'Reply exactly RETAINED_PERMISSION_DONE. Do not use tools.' > "$FM_HOME/data/probe/brief.md"
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" probe --relaunch --model "$MODEL" > "$BASE/retained-permission-relaunch.txt"
fm_backend_herdr_cli "$HERDR_LAB_SESSION" pane wait-output "$pane" --regex '^ RETAINED_PERMISSION_DONE$' --timeout 90000 > "$BASE/retained-permission.json"
test "$(grep -c '^permission_mode=auto$' "$FM_HOME/state/probe.meta")" -eq 1 || fail 'same-harness relaunch did not retain explicit permission mode'
test "$(grep -c '^permission_mode=' "$FM_HOME/state/probe.meta")" -eq 1 || fail 'retained permission metadata was duplicated'
grep -q '^x_request=devin-live-probe$' "$FM_HOME/state/probe.meta" || fail 'retained permission relaunch discarded unrelated metadata'
"$ROOT/bin/fm-control.sh" probe exit > "$BASE/retained-permission-exit.txt"
# Restore real PATH before helper teardown to avoid wrapping its internal calls.
export PATH="$FM_TEST_REAL_PATH"
