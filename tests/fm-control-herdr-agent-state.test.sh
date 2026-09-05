#!/usr/bin/env bash
# Herdr lifecycle classification through the public control interface.
# The fake CLI supplies native registry/process JSON while real shell processes
# prove the stale-registration topology against the operating-system process table.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v cc >/dev/null 2>&1 || { echo "skip: cc not found (required by the process-topology fixture)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-control-herdr-agent-state)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
PROC="$TMP_ROOT/process"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hs" "$FAKEBIN" "$PROC/wt"
printf '# lifecycle fixture\n' > "$HOME_DIR/data/hs/brief.md"
: > "$TMP_ROOT/herdr.log"
mkfifo "$PROC/hold"
mkfifo "$PROC/live-hold"

cat > "$PROC/leaf.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" > "$1/leaf.pid"
IFS= read -r _ < "$1/hold"
SH
cat > "$PROC/live-leaf.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" > "$1/live-leaf.pid"
IFS= read -r _ < "$1/live-hold"
SH
cat > "$PROC/root.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" > "$1/root.pid"
"$1/treehouse" "$1/leaf.sh" "$1" &
wait
SH
cat > "$PROC/live-root.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" > "$1/live-root.pid"
"$1/treehouse" "$1/agent" "$1/live-leaf.sh" "$1" &
wait
SH
cat > "$PROC/active-root.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" > "$1/active-root.pid"
sleep 300 &
echo "$!" > "$1/active.pid"
wait
SH
cat > "$PROC/wrapper.c" <<'C'
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
  pid_t child;
  int status;
  if (argc < 2 || (child = fork()) < 0) return 1;
  if (child == 0) { execv(argv[1], argv + 1); return 1; }
  return waitpid(child, &status, 0) < 0 ? 1 : status;
}
C
cc "$PROC/wrapper.c" -o "$PROC/treehouse"
cc "$PROC/wrapper.c" -o "$PROC/agent"
chmod +x "$PROC/leaf.sh" "$PROC/live-leaf.sh" "$PROC/root.sh" \
  "$PROC/live-root.sh" "$PROC/active-root.sh" "$PROC/treehouse" "$PROC/agent"
bash "$PROC/root.sh" "$PROC" &
TREE_PID=$!
bash "$PROC/live-root.sh" "$PROC" &
LIVE_TREE_PID=$!
bash "$PROC/active-root.sh" "$PROC" 2>/dev/null &
ACTIVE_TREE_PID=$!

cleanup() {
  local leaf_pid live_leaf_pid active_pid
  leaf_pid=$(cat "$PROC/leaf.pid" 2>/dev/null || true)
  if [ -n "$leaf_pid" ] && kill -0 "$leaf_pid" 2>/dev/null; then
    printf 'release\n' > "$PROC/hold" 2>/dev/null || true
  else
    kill "$TREE_PID" 2>/dev/null || true
  fi
  live_leaf_pid=$(cat "$PROC/live-leaf.pid" 2>/dev/null || true)
  if [ -n "$live_leaf_pid" ] && kill -0 "$live_leaf_pid" 2>/dev/null; then
    printf 'release\n' > "$PROC/live-hold" 2>/dev/null || true
  else
    kill "$LIVE_TREE_PID" 2>/dev/null || true
  fi
  active_pid=$(cat "$PROC/active.pid" 2>/dev/null || true)
  [ -z "$active_pid" ] || kill "$active_pid" 2>/dev/null || true
  wait "$TREE_PID" 2>/dev/null || true
  wait "$LIVE_TREE_PID" 2>/dev/null || true
  wait "$ACTIVE_TREE_PID" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

attempt=0
while { [ ! -s "$PROC/root.pid" ] || [ ! -s "$PROC/leaf.pid" ] \
  || [ ! -s "$PROC/live-root.pid" ] || [ ! -s "$PROC/live-leaf.pid" ] \
  || [ ! -s "$PROC/active-root.pid" ] || [ ! -s "$PROC/active.pid" ]; } && [ "$attempt" -lt 100 ]; do
  sleep 0.02
  attempt=$((attempt + 1))
done
[ -s "$PROC/root.pid" ] && [ -s "$PROC/leaf.pid" ] && [ -s "$PROC/live-root.pid" ] \
  && [ -s "$PROC/live-leaf.pid" ] \
  && [ -s "$PROC/active-root.pid" ] && [ -s "$PROC/active.pid" ] \
  || fail "could not start the real idle-shell and active-process trees"
ROOT_PID=$(cat "$PROC/root.pid")
LEAF_PID=$(cat "$PROC/leaf.pid")
ACTIVE_ROOT_PID=$(cat "$PROC/active-root.pid")
ACTIVE_PID=$(cat "$PROC/active.pid")
LIVE_ROOT_PID=$(cat "$PROC/live-root.pid")
LIVE_LEAF_PID=$(cat "$PROC/live-leaf.pid")
AGENT_PID=$(ps -p "$LIVE_LEAF_PID" -o ppid= | tr -d '[:space:]')

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.8.2","protocol":19},"server":{"running":true}}\n'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  "agent get")
    printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n'
    ;;
  "pane process-info")
    case "$(cat "$FM_HERDR_MODE")" in
      stale)
        printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv0":"bash"}]}}}\n' \
          "$FM_HERDR_ROOT_PID" "$FM_HERDR_LEAF_PID" "$FM_HERDR_LEAF_PID"
        ;;
      alive)
        printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"sleep","argv0":"sleep"}]}}}\n' \
          "$FM_HERDR_ACTIVE_ROOT_PID" "$FM_HERDR_ACTIVE_PID" "$FM_HERDR_ACTIVE_PID"
        ;;
      live_agent_shell)
        printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv0":"bash"}]}}}\n' \
          "$FM_HERDR_LIVE_ROOT_PID" "$FM_HERDR_LIVE_LEAF_PID" "$FM_HERDR_LIVE_LEAF_PID"
        ;;
      ambiguous)
        printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_processes":[]}}}\n' \
          "$FM_HERDR_ROOT_PID"
        ;;
    esac
    ;;
  "pane send-keys") : ;;
  *) : ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

cat > "$HOME_DIR/state/hs.meta" <<EOF
window=fmtest:w1:p2
endpoint_task_id=hs
worktree=$PROC/wt
project=$PROC/wt
harness=pi
kind=ship
mode=local-only
yolo=off
model=gpt-5.6-sol
effort=low
backend=herdr
herdr_session=fmtest
herdr_workspace_id=w1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
EOF

run_control() {
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" HERDR_SESSION=fmtest \
    FM_HERDR_LOG="$TMP_ROOT/herdr.log" FM_HERDR_MODE="$TMP_ROOT/mode" \
    FM_HERDR_ROOT_PID="$ROOT_PID" FM_HERDR_LEAF_PID="$LEAF_PID" \
    FM_HERDR_ACTIVE_ROOT_PID="$ACTIVE_ROOT_PID" FM_HERDR_ACTIVE_PID="$ACTIVE_PID" \
    FM_HERDR_LIVE_ROOT_PID="$LIVE_ROOT_PID" FM_HERDR_AGENT_PID="$AGENT_PID" \
    FM_HERDR_LIVE_LEAF_PID="$LIVE_LEAF_PID" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.01 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

printf 'stale\n' > "$TMP_ROOT/mode"
: > "$TMP_ROOT/herdr.log"
out=$(run_control hs exit) || fail "a stale Pi registration over a real idle shell should be already stopped: $out"
assert_contains "$out" "already-stopped hs" "the public exit command did not recognize the post-Pi idle shell"
assert_not_contains "$(cat "$TMP_ROOT/herdr.log")" "pane send-keys" "an agent-free shell must receive no lifecycle input"
pass "fm-control herdr: a stale Pi registration over a real idle-shell process tree is already stopped"

printf 'alive\n' > "$TMP_ROOT/mode"
: > "$TMP_ROOT/herdr.log"
out=$(run_control hs interrupt) || fail "a registered agent with an active foreground process should remain live: $out"
assert_contains "$out" "interrupt-delivered hs" "the public interrupt command did not accept the proven-live shape"
assert_contains "$(cat "$TMP_ROOT/herdr.log")" "pane send-keys w1:p2 escape" "the proven-live agent did not receive its interrupt key"
pass "fm-control herdr: a registered agent with an active process remains live"

printf 'live_agent_shell\n' > "$TMP_ROOT/mode"
: > "$TMP_ROOT/herdr.log"
out=$(run_control hs interrupt) || fail "a live agent running a childless foreground shell should remain live: $out"
assert_contains "$out" "interrupt-delivered hs" "the live-agent foreground shell was mistaken for a stale registration"
assert_contains "$(cat "$TMP_ROOT/herdr.log")" "pane send-keys w1:p2 escape" "the live agent did not receive its interrupt key"
pass "fm-control herdr: an arbitrary intermediate agent prevents stale-registration override"

printf 'ambiguous\n' > "$TMP_ROOT/mode"
: > "$TMP_ROOT/herdr.log"
if out=$(run_control hs exit); then
  fail "ambiguous process evidence must refuse lifecycle input: $out"
fi
assert_contains "$out" "reads 'unreadable'" "the ambiguous-process refusal did not preserve the conservative verdict"
assert_not_contains "$(cat "$TMP_ROOT/herdr.log")" "pane send-keys" "ambiguous process evidence must receive no lifecycle input"
pass "fm-control herdr: ambiguous process evidence refuses instead of licensing a duplicate or lifecycle input"
