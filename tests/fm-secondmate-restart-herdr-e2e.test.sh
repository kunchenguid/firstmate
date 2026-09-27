#!/usr/bin/env bash
# Real Pi/Herdr secondmate restart, with deterministic token-free persist replies.
# The public restart must recover a closing pane while the public watcher defers.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_SECONDMATE_RESTART_HERDR_E2E herdr jq pi
RUN=$(fm_test_tmproot fm-secondmate-restart-herdr)
mkdir -p "$RUN"
RUN=$(cd "$RUN" && pwd -P)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-secondmate-restart-strands-closed-pane)
HERDR_ORIGINAL_PATH=$PATH
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
export FM_RESTART_LAB_ROOT="$ROOT" FM_RESTART_LAB_DIR="$RUN"
cleanup() {
  local rc=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
export HERDR_SESSION="$HERDR_LAB_SESSION"
mkdir -p "$RUN/bin" "$RUN/root" "$RUN/home/"{state,data,config} "$RUN/mate/"{state,data,bin,.pi/extensions} "$RUN/pi"
ln -s "$ROOT/bin" "$RUN/root/bin"
printf 'pi\n' > "$RUN/home/config/secondmate-harness"
printf 'herdr\n' > "$RUN/home/config/backend"
printf 'labmate\n' > "$RUN/mate/.fm-secondmate-home"
printf '# Empty isolated lifecycle lab\n' > "$RUN/mate/AGENTS.md"
printf '# Lab charter\n' > "$RUN/mate/data/charter.md"
for name in fm-primary-turnend-guard fm-primary-pi-watch; do printf 'export default function () {}\n' > "$RUN/mate/.pi/extensions/$name.ts"; done
git -C "$RUN/mate" init -q
git -C "$RUN/mate" add AGENTS.md
git -C "$RUN/mate" -c user.name=Lab -c user.email=lab@example.invalid commit -qm initial
cat > "$RUN/input.ts" <<EOF
import * as fs from 'node:fs';
export default function (pi: any) {
  pi.on('project_trust', () => ({trusted:'yes', remember:false}));
  pi.on('input', () => {
    const dir = '$RUN/home/state/labmate.inbox';
    if (fs.existsSync(dir)) for (const file of fs.readdirSync(dir).filter(f => f.endsWith('.msg'))) {
      const text = fs.readFileSync(dir+'/'+file,'utf8');
      const corr = text.match(/corr=([0-9a-f]{16})/);
      if(corr) fs.appendFileSync('$RUN/home/state/labmate.status', 'done: corr='+corr[1]+' lab has no open work\\n');
    }
    return {action:'handled'};
  });
}
EOF
PI_REAL=$(command -v pi)
cat > "$RUN/bin/pi" <<EOF
#!/bin/bash
export PI_CODING_AGENT_DIR='$RUN/pi'
exec '$PI_REAL' --no-context-files --no-session -e '$RUN/input.ts' "\$@"
EOF
chmod +x "$RUN/bin/pi"
cat > "$RUN/bin/herdr" <<'EOF'
#!/bin/bash
set -eu
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ "$2" = "$HERDR_LAB_SESSION" ]; shift 2 ;;
    --session=*) exit 9 ;;
    *) args+=("$1"); shift ;;
  esac
done
# Pause the replacement at tab creation, when fm-spawn owns its spawn guard.
# A real watcher must skip this in-progress restart rather than collide on it.
if [ "${args[0]:-} ${args[1]:-}" = 'tab create' ] \
  && mkdir "$FM_RESTART_LAB_DIR/watcher-started" 2>/dev/null; then
  FM_POLL=1 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=1 \
    "$FM_RESTART_LAB_ROOT/bin/fm-watch.sh" > "$FM_RESTART_LAB_DIR/watch.out" 2> "$FM_RESTART_LAB_DIR/watch.err" &
  watcher=$!
  for _ in $(seq 1 100); do
    [ ! -e "$FM_HOME/state/.secondmate-liveness-tick" ] || break
    sleep 0.1
  done
  sleep 2
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
EOF
chmod +x "$RUN/bin/herdr"
CREATE=$(lab workspace create --cwd "$RUN/mate" --label labmate --no-focus)
PANE=$(printf '%s' "$CREATE" | jq -r '.result.root_pane.pane_id')
WS=$(printf '%s' "$CREATE" | jq -r '.result.workspace.workspace_id')
TAB=$(lab pane get "$PANE" | jq -r '.result.pane.tab_id')
cat > "$RUN/home/state/labmate.meta" <<EOF
window=$HERDR_LAB_SESSION:$PANE
endpoint_task_id=labmate
worktree=$RUN/mate
home=$RUN/mate
project=$RUN/mate
kind=secondmate
mode=secondmate
yolo=off
harness=pi
model=default
effort=default
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
lab pane run "$PANE" "exec '$RUN/bin/pi'" >/dev/null
for _ in $(seq 1 100); do
  status=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty') || status=
  [ "$status" != idle ] || break
  sleep 0.2
done
[ "$status" = idle ] || fail "real Pi did not become idle in the lab pane"
printf 'lab=%s run=%s initial=%s\n' "$HERDR_LAB_SESSION" "$RUN" "$status"
export PATH="$RUN/bin:$PATH" FM_HOME="$RUN/home" FM_ROOT_OVERRIDE="$RUN/root"
export FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1
export FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 FM_CONTROL_LAUNCH_WAIT=30 FM_SECONDMATE_PERSIST_WAIT=30 FM_SECONDMATE_PERSIST_POLL=1
set +e
"$ROOT/bin/fm-secondmate-restart.sh" labmate > "$RUN/result" 2>&1
rc=$?
set -e
cat "$RUN/result"
[ "$rc" -eq 0 ] || fail "public restart failed (exit $rc)"
grep -F 'summary: 1 of 1 restarted, 0 nudged, 0 unreached' "$RUN/result" >/dev/null \
  || fail "restart did not report success"
grep -Fx 'exit_result=endpoint-gone' "$RUN/home/state/labmate.control-relaunch" >/dev/null \
  || fail "lab did not exercise a closed pane"
NEW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$RUN/home/state/labmate.meta")
[ "$NEW_PANE" != "$PANE" ] || fail "restart did not replace the old pane"
grep -Fx "herdr_session=$HERDR_LAB_SESSION" "$RUN/home/state/labmate.meta" >/dev/null \
  || fail "restart changed the recorded Herdr session"
NEW_WS=$(sed -n 's/^herdr_workspace_id=//p' "$RUN/home/state/labmate.meta")
lab workspace list | jq -e --arg id "$NEW_WS" \
  '.result.workspaces[] | select(.workspace_id == $id and .label == "2ndmate-labmate")' >/dev/null \
  || fail "replacement did not use the secondmate home workspace"
[ -e "$RUN/home/state/.secondmate-liveness-tick" ] || fail "watcher never ticked during replacement"
[ ! -e "$RUN/home/state/.secondmate-relaunch-labmate" ] || fail "watcher attempted a competing spawn: $(cat "$RUN/watch.out" "$RUN/watch.err")"
[ ! -d "$RUN/home/state/.secondmate-liveness-labmate.lock" ] || fail "restart left its liveness lock held"
lab agent get "$NEW_PANE" | jq -e '.result.agent.agent_status' >/dev/null \
  || fail "replacement has no real agent registration"
lab status --json | jq -c '{client:.client,server:.server.running}'
printf 'Pi version: '
"$PI_REAL" --version
pass 'real Pi/Herdr restart replaces a closed pane; watcher defers without consuming a recovery attempt'
