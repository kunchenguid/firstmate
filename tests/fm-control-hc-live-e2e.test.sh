#!/usr/bin/env bash
# Real omp exit and replacement through fm-control, with core task-name proof.
# Spends model tokens; every hc call is isolated in a disposable private core.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_HC_CONTROL_LIVE hc jq omp

LAB=$(mktemp -d /tmp/fmhc.XXXXXX)
ID="hclive$$"
mkdir -p "$LAB/home/state" "$LAB/home/data/$ID" "$LAB/config" "$LAB/data" "$LAB/cache"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET FM_ROOT_OVERRIDE
export HC_SESSION="fmhc$$" XDG_STATE_HOME="$LAB" XDG_RUNTIME_DIR="$LAB"
export XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data" XDG_CACHE_HOME="$LAB/cache"
export FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1
export FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=15 FM_CONTROL_LAUNCH_WAIT=30
cleanup() {
  if [ "${XDG_STATE_HOME:-}" = "$LAB" ] && [ "${HC_SESSION:-}" = "fmhc$$" ]; then
    hc server stop --json >/dev/null 2>&1 || true
  fi
  fm_test_remove_tree "/tmp/fm-$ID"
  fm_test_remove_tree "$LAB"
  fm_test_cleanup
}
trap cleanup EXIT
[ "$HC_SESSION" != default ] && [ "$XDG_RUNTIME_DIR" = "$LAB" ] || fail "private core isolation lost"

fm_git_worktree "$LAB/project" "$LAB/work" fm/hc-live
printf 'keep this local edit\n' > "$LAB/work/uncommitted"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc
hc --version
omp --version
hc server status --json >/dev/null
LABEL="fm-$ID"
ADDR=$(fm_backend_hc_create_task "$HC_SESSION" "$LABEL" "$LAB/work")
TARGET="$HC_SESSION:$ADDR"
NAME=$(hc get --json "$ADDR" | jq -r '.name')
[[ "$NAME" =~ ^[a-z0-9_-]{1,32}$ ]] || fail "invalid core task name: $NAME"
hc ls --json | jq -e --arg a "$ADDR" --arg n "$NAME" '.terminals[] | select(.address==$a and .name==$n)' >/dev/null || fail "task name absent from core listing"

cat > "$FM_HOME/data/$ID/brief.md" <<'BRIEF'
# Task
## Captain's intent
Reply exactly HC-CONTROL-READY. Do not inspect or change files, run commands, or start other agents.

## Firstmate spec
This is an isolated lifecycle check. Wait quietly after the reply.

Delivery contract: mode=no-mistakes
Ship branch: fm/hc-live
BRIEF
cat > "$FM_HOME/state/$ID.meta" <<EOF
window=$TARGET
endpoint_task_id=$ID
worktree=$LAB/work
project=$LAB/project
harness=omp
kind=ship
mode=no-mistakes
yolo=off
branch=fm/hc-live
model=default
effort=default
backend=hc
hc_session=$HC_SESSION
hc_terminal=$ADDR
spawn_gen=initial
EOF

fm_backend_hc_send_text_line "$TARGET" "OMP_SKIP_SETUP=1 omp --no-session --no-extensions --no-title --config '$ROOT/.omp/fm-worker-overlay.yml' --cwd '$LAB/work'" "$LABEL"
wait_empty() {
  local i state
  for i in $(seq 1 300); do
    state=$(fm_backend_agent_state hc "$TARGET" "$LABEL")
    if [ "$state" = alive ] && [ "$(fm_backend_composer_state hc "$TARGET" "$LABEL")" = empty ]; then return 0; fi
    sleep 0.2
  done
  hc read "$ADDR" >&2
  fail "omp did not reach a proven empty composer in hc"
}
# A first-run hint is intentionally not treated as proof of empty input.
hc wait "$ADDR" --output '❯' --timeout 10 --json >/dev/null || true
hc send --wait --json "$ADDR" 'Reply exactly HC-CONTROL-READY. No tools, file changes, or subagents.'
wait_empty
OLD_PID=$(hc get --json "$ADDR" | jq -r '.foreground.pid')
# A shell tool must never make its still-running parent agent read `dead`.
hc send --json "$ADDR" 'Use bash to run sleep 3, then reply HC-TOOL-FINISHED. Do not read or edit files.'
SAW_WORKING=0
SAW_TOOL=0
for _ in $(seq 1 300); do
  status=$(hc get --json "$ADDR" | jq -r '.status.state')
  assert_equals "$(fm_backend_agent_state hc "$TARGET" "$LABEL")" alive "a real omp turn must remain alive, including during its shell tool"
  if hc read "$ADDR" | grep -F '$ sleep 3' >/dev/null; then SAW_TOOL=1; fi
  case "$status" in
    working) SAW_WORKING=1 ;;
    done|idle) [ "$SAW_WORKING" != 1 ] || break ;;
  esac
  sleep 0.2
done
[ "$SAW_WORKING" = 1 ] && [ "$SAW_TOOL" = 1 ] || fail "busy shell-tool liveness was not exercised"
wait_empty
pass "hc control live: omp remains alive throughout a real shell-tool turn"
bash "$ROOT/bin/fm-control.sh" "$ID" exit
assert_equals "$(fm_backend_agent_state hc "$TARGET" "$LABEL")" dead "exit must leave a proven agent-free shell"
kill -0 "$OLD_PID" 2>/dev/null && fail "exit left the old omp process running"
bash "$ROOT/bin/fm-control.sh" "$ID" exit
pass "hc control live: omp exits to a shell and repeated exit is idempotent"

bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness omp --model default --effort high --note 'Reply exactly HC-REPLACED-READY, then wait quietly. Do not use tools.'
wait_empty
NEW_PID=$(hc get --json "$ADDR" | jq -r '.foreground.pid')
[ "$NEW_PID" != "$OLD_PID" ] || fail "relaunch did not replace the agent process"
assert_equals "$(fm_backend_agent_state hc "$TARGET" "$LABEL")" alive "replacement must be alive"
assert_equals "$(hc get --json "$ADDR" | jq -r '.name')" "$NAME" "replacement retains the same task name"
assert_equals "$(fm_meta_get "$FM_HOME/state/$ID.meta" window)" "$TARGET" "replacement retains the endpoint"
assert_equals "$(fm_meta_get "$FM_HOME/state/$ID.meta" hc_session)" "$HC_SESSION" "replacement publishes the session"
assert_equals "$(fm_meta_get "$FM_HOME/state/$ID.meta" hc_terminal)" "$ADDR" "replacement publishes the address"
assert_equals "$(fm_meta_get "$FM_HOME/state/$ID.meta" effort)" high "replacement honors effort"
assert_equals "$(cat "$LAB/work/uncommitted")" 'keep this local edit' "local work survives replacement"
printf '# name=%s old-pid=%s new-pid=%s\n' "$NAME" "$OLD_PID" "$NEW_PID"
pass "hc control live: replacement is alive in the same named terminal with local work preserved"

# Literal key input does not submit; plain capture cannot prove its styling,
# so either pending or unknown must refuse without submitting /quit.
hc keys --json "$ADDR" x >/dev/null
if bash "$ROOT/bin/fm-control.sh" "$ID" exit; then fail "pending composer input was overwritten"; fi
assert_equals "$(fm_backend_agent_state hc "$TARGET" "$LABEL")" alive "pending-input refusal preserves the agent"
hc keys --json "$ADDR" ctrl+u >/dev/null
wait_empty
bash "$ROOT/bin/fm-control.sh" "$ID" exit
fm_backend_kill hc "$TARGET" '' "$LABEL"
if bash "$ROOT/bin/fm-control.sh" "$ID" exit; then fail "missing endpoint was treated as proven absent"; fi
if bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note retry; then fail "missing endpoint was reclaimed without core identity"; fi
pass "hc control live: pending input and unprovable absence still refuse"
echo FM_TEST_COMPLETE
