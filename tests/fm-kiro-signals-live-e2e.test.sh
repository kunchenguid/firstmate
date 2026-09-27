#!/usr/bin/env bash
# Opt-in real-process kiro-cli crewmate signals e2e.
#
# Exercises the verified crewmate path end to end against a REAL kiro-cli in a
# dedicated tmux socket: fm-spawn composes and launches the interactive TUI, the
# per-task KIRO_HOME stop-hook wiring touches state/<id>.turn-ended when the
# real agent finishes its first turn, the rendered-tail busy classifier reads the
# live pane, a trusted V3 turn reads, runs shell, and replaces file content
# with no approval dialog, fm-control interrupt/exit drive the pane, and
# fm-teardown removes every artifact. It submits a prompt, so it spends credits
# and is opt-in; it capability-skips when kiro-cli or tmux is absent unless
# explicitly requested.
#
# Detection is asserted against the real process ancestry via
# tests/fm-harness-liveness-drift-live-e2e.test.sh's model: ask fm-harness.sh
# from the live pane's own process, not from a fake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIRO_LIVE_E2E tmux kiro-cli

REAL_TMUX=$(command -v tmux) || fail "tmux not found"
KIRO_BIN=$(command -v kiro-cli) || fail "kiro-cli not found"
# Guard against the Electron IDE being first on PATH under the name kiro-cli.
case "$("$KIRO_BIN" --version 2>/dev/null)" in
  "kiro-cli "*) : ;;
  *) fail "resolved kiro-cli is not the Kiro CLI (got '$("$KIRO_BIN" --version 2>/dev/null)')" ;;
esac

LAB=$(fm_test_tmproot fm-kiro-live)
SESSION="kiro-live-e2e"
ID="kiro-live-$$"
LOGIN_HOME=${FM_KIRO_LIVE_LOGIN_HOME:-$HOME}
PROJ="$LAB/project"; WT="$LAB/wt"; FMHOME="$LAB/fmhome"
mkdir -p "$FMHOME/data/$ID" "$FMHOME/state" "$FMHOME/config" "$FMHOME/projects"

fm_git_worktree "$PROJ" "$WT" "wt-kiro-live"

cat > "$FMHOME/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Reply with exactly the single word LIVEOK and then stop. Do not use any tools.

## Firstmate spec
This is an isolated live regression test of the kiro-cli crewmate adapter.
EOF
printf 'kiro-cli\n' > "$FMHOME/config/crew-harness"
touch "$FMHOME/state/.last-watcher-beat"

# A dedicated tmux socket the real backend addresses through $TMUX. fm-spawn's
# tmux backend uses ambient tmux, so run the whole spawn inside a server bound
# to this lab's socket by launching a controlling session on it and driving
# fm-spawn from a pane there is heavier than needed; instead point fm-spawn at a
# private socket by exporting TMUX to a session we create here.
SOCK="$LAB/tmux.sock"
env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" new-session -d -s "$SESSION" -x 200 -y 50 'sleep 3600' \
  || fail "could not start the dedicated tmux session"

cleanup() {
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null || true
}
trap 'cleanup' EXIT

# Drive fm-spawn from inside a pane bound to the dedicated socket, so its
# tmux backend resolves this server. The pane inherits the socket through the
# tmux -S environment.
TMUX_ENV="$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" display-message -p '#{socket_path}')"
[ -n "$TMUX_ENV" ] || fail "could not resolve the dedicated socket path"

spawn_env() {
  # V3 authentication belongs to the operator's login HOME, not KIRO_HOME.
  # Replacing HOME with an empty fixture directory parks the TUI on its browser
  # sign-in prompt forever; the real production spawn preserves HOME while the
  # explicit KIRO_HOME/FM_* overrides below isolate all task state.
  env -u TMUX -u TMUX_PANE \
    HOME="$LOGIN_HOME" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$FMHOME" \
    FM_STATE_OVERRIDE="$FMHOME/state" FM_DATA_OVERRIDE="$FMHOME/data" \
    FM_PROJECTS_OVERRIDE="$FMHOME/projects" FM_CONFIG_OVERRIDE="$FMHOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="$TMUX_ENV,$$,0" \
    "$@"
}

# Spawn the real crewmate. FM_KIRO_LIVE_MODEL selects a concrete model when
# Kiro's default `auto` routing is saturated ("experiencing high traffic"), the
# same --model fm-spawn carries for a production task; unset keeps the default.
if ! spawn_env "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --harness kiro-cli \
    --mode no-mistakes --yolo off --effort low \
    ${FM_KIRO_LIVE_MODEL:+--model "$FM_KIRO_LIVE_MODEL"} > "$LAB/spawn.out" 2>&1; then
  cat "$LAB/spawn.out" >&2
  META="$FMHOME/state/$ID.meta"
  TARGET="$SESSION:fm-$ID"
  WT=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" display-message -p -t "$TARGET" '#{pane_current_path}' 2>/dev/null || true)
  KIRO_HOME_DIR="$FMHOME/state/$ID.kiro-home"
  if [ -f "$META" ]; then
    TARGET=$(sed -n 's/^window=//p' "$META")
    WT=$(sed -n 's/^worktree=//p' "$META")
    printf '# failed-spawn meta:\n' >&2
    cat "$META" >&2
  fi
  printf '# failed-spawn target=%s worktree=%s\n' "$TARGET" "$WT" >&2
  printf '# failed-spawn viewport:\n' >&2
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -100 -t "$TARGET" 2>/dev/null >&2 || true
  pane_facts=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" display-message -p -t "$TARGET" \
    '#{pane_pid} #{pane_current_command} dead=#{pane_dead} status=#{pane_dead_status}' 2>/dev/null || true)
  printf '# failed-spawn pane=%s\n' "$pane_facts" >&2
  pane_pid=${pane_facts%% *}
  if [ -n "$pane_pid" ]; then
    printf '# failed-spawn descendants:\n' >&2
    current=$pane_pid; depth=0
    while [ "$depth" -lt 8 ] && [ -n "$current" ]; do
      ps -o pid=,ppid=,comm=,args= -p "$current" >&2 2>/dev/null || break
      current=$(pgrep -P "$current" | head -1 || true)
      depth=$((depth + 1))
    done
  fi
  printf '# failed-spawn staged launch:\n' >&2
  for launch_dir in "/tmp/fm-$ID+"*; do
    [ -d "$launch_dir" ] || continue
    find "$launch_dir" -maxdepth 1 -type f -name 'launch.*.sh' -exec sed -n '1,4p' {} \; >&2 2>/dev/null || true
  done
  printf '# failed-spawn Kiro log/files:\n' >&2
  cat "$KIRO_HOME_DIR/chat.log" >&2 2>/dev/null || true
  find "$KIRO_HOME_DIR" -maxdepth 3 -type f -printf '%s %p\n' >&2 2>/dev/null | sort || true
  printf '# failed-spawn agent discovery:\n' >&2
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    (cd "$WT" && HOME="$LOGIN_HOME" KIRO_HOME="$KIRO_HOME_DIR" KIRO_DATA_DIR="$KIRO_HOME_DIR/data" \
      "$KIRO_BIN" agent list 2>&1) >&2 || true
    find "$WT/.kiro" -maxdepth 3 -type f -print -exec sed -n '1,120p' {} \; >&2 2>/dev/null || true
  fi
  printf '# failed-spawn isolated settings:\n' >&2
  cat "$KIRO_HOME_DIR/settings/cli.json" >&2 2>/dev/null || true
  fail "fm-spawn of a real kiro-cli crewmate failed"
fi
grep -q "spawned $ID harness=kiro-cli" "$LAB/spawn.out" || fail "spawn did not report a kiro-cli launch"

META="$FMHOME/state/$ID.meta"
[ -f "$META" ] || fail "no task record after spawn"
WT=$(sed -n 's/^worktree=//p' "$META")
[ -n "$WT" ] && [ -d "$WT" ] || fail "no live worktree recorded after spawn"
KIRO_HOME_DIR="$FMHOME/state/$ID.kiro-home"
PROJECT_AGENT="$WT/.kiro/agents/firstmate-kiro-$ID.json"
PROJECT_HOOK="$WT/.kiro/hooks/fm-firstmate-$ID.json"
[ -f "$PROJECT_AGENT" ] || fail "real V3 spawn did not install its project-scoped agent"
[ -f "$PROJECT_HOOK" ] || fail "real V3 spawn did not install its project-scoped hook"
grep -q '"chat.enableKnowledge": false' "$KIRO_HOME_DIR/settings/cli.json" \
  || fail "real V3 spawn did not disable Kiro knowledge in its isolated home"
jq -e '.excludedTools | index("knowledge") != null' "$PROJECT_AGENT" >/dev/null 2>&1 \
  || fail "real V3 project agent did not exclude the global knowledge tool"
TARGET=$(sed -n 's/^window=//p' "$META")
[ -n "$TARGET" ] || fail "no endpoint recorded"

# 1) Turn-end: the real stop hook touches state/<id>.turn-ended when the first
#    turn finishes.
i=0
while [ "$i" -lt "${FM_KIRO_LIVE_TIMEOUT:-180}" ] && [ ! -f "$FMHOME/state/$ID.turn-ended" ]; do
  sleep 1
  i=$((i + 1))
done
if [ ! -f "$FMHOME/state/$ID.turn-ended" ]; then
  TAIL=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -120 -t "$TARGET" 2>/dev/null || true)
  printf '%s\n' "$TAIL" >&2
  if printf '%s\n' "$TAIL" | grep -qiE 'experiencing high traffic|ThrottlingException|monthly usage limit'; then
    fail "live: the Kiro provider refused the first turn (capacity or quota); nothing about the adapter was exercised, retry later"
  fi
  fail "the kiro-cli stop hook never touched state/$ID.turn-ended within the timeout"
fi
pass "live: kiro-cli stop hook touched state/<id>.turn-ended at turn end"

# 2) Detection: ask fm-harness.sh from the live pane's own foreground process,
#    which must resolve kiro-cli by ancestry.
PANE_PID=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" display-message -p -t "$TARGET" '#{pane_pid}')
LEAF=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$PANE_PID" 2>/dev/null | head -1 || true)
case "$LEAF" in
  *kiro-cli) pass "live: fm-harness.sh resolves the live pane's process tree as kiro-cli ($LEAF)" ;;
  *) fail "live: fm-harness.sh did not resolve kiro-cli from the live pane (got '$LEAF')" ;;
esac

# 3) Semantic busy state: the completed first turn is idle even if stale rendered
#    busy text remains in scrollback. A second steer opens busy through
#    UserPromptSubmit, publishes native progress around a real tool call, and
#    closes idle through Stop. The steer uses the production durable inbox and
#    doorbell, so the worker acknowledgement is covered too.
TAIL=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -t "$TARGET" 2>/dev/null || true)
case "$TAIL" in
  *"firstmate-kiro-$ID"*) pass "live: V3 selected the generated project-scoped Firstmate agent" ;;
  *) fail "live: V3 pane did not name the generated project agent (possible silent fallback); tail was:"$'\n'"$TAIL" ;;
esac
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
semantic=$(fm_busy_classify_meta "$META" "$ID" "$FMHOME/state" "$TAIL")
[ "$semantic" = 'idle kiro-hook' ]   || fail "the completed first turn must classify idle kiro-hook, got '$semantic'"
case "$TAIL" in
  *"ask a question or describe a task"*) pass "live: idle V3 composer is steerable" ;;
  *) fail "live: completed V3 turn did not expose its idle composer; tail was:"$'\n'"$TAIL" ;;
esac

rm -f "$FMHOME/state/$ID.turn-ended" "$FMHOME/state/$ID.progress"
spawn_env "$ROOT/bin/fm-send.sh" "$ID"   "Use the shell tool exactly once to run sleep 8, then reply with exactly SEMANTICOK."   > "$LAB/semantic-send.out" 2>&1   || { cat "$LAB/semantic-send.out" >&2; fail "semantic-turn steer failed"; }
i=0; semantic=
SLOW_POLLS=$(( ${FM_KIRO_LIVE_TIMEOUT:-180} * 5 ))
while [ "$i" -lt "$SLOW_POLLS" ]; do
  semantic=$(fm_busy_classify_meta "$META" "$ID" "$FMHOME/state")
  [ "$semantic" = 'busy kiro-hook' ] && break
  sleep 0.2
  i=$((i + 1))
done
[ "$semantic" = 'busy kiro-hook' ] \
  || { env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -120 -t "$TARGET" >&2 2>/dev/null || true; fail "UserPromptSubmit never opened busy kiro-hook (last '$semantic')"; }
i=0
while [ "$i" -lt "$SLOW_POLLS" ] && [ ! -f "$FMHOME/state/$ID.progress" ]; do
  sleep 0.2
  i=$((i + 1))
done
[ -f "$FMHOME/state/$ID.progress" ] \
  || { env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -120 -t "$TARGET" >&2 2>/dev/null || true; fail "PreToolUse/PostToolUse never published native progress"; }
i=0
while [ "$i" -lt "${FM_KIRO_LIVE_TIMEOUT:-180}" ] && [ ! -f "$FMHOME/state/$ID.turn-ended" ]; do
  sleep 1
  i=$((i + 1))
done
if [ ! -f "$FMHOME/state/$ID.turn-ended" ]; then
  TAIL=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -120 -t "$TARGET" 2>/dev/null || true)
  printf '%s\n' "$TAIL" >&2
  if printf '%s\n' "$TAIL" | grep -qiE 'experiencing high traffic|ThrottlingException|monthly usage limit'; then
    fail "live: the Kiro provider refused the semantic second turn (capacity or quota); retry later"
  fi
  fail "semantic second turn never reached Stop"
fi
semantic=$(fm_busy_classify_meta "$META" "$ID" "$FMHOME/state")
[ "$semantic" = 'idle kiro-hook' ]   || fail "Stop did not close the semantic second turn, got '$semantic'"
find "$FMHOME/state/$ID.inbox/handled" -type f -name '*.msg' -print -quit 2>/dev/null | grep -q .   || fail "the real Kiro worker did not acknowledge its durable steering record"
pass "live: Kiro hooks bracket a steered tool turn as busy/progress/idle"

# 3b) Trust: the V3 launch carries -a and the generated agent names concrete
#     tools, so a fresh worker reads, runs shell, and REPLACES file content
#     through fs_write with no approval dialog. Before this, an agent declaring
#     allowedTools ["*"] and a trust-less launch parked here on "Replace in
#     File requires approval" until a human answered, and the stalled pane was
#     escalated as a blocked worker.
KIRO_PID=$(pgrep -f -- "--agent firstmate-kiro-$ID" | head -1 || true)
[ -n "$KIRO_PID" ] || fail "live: no kiro-cli process selecting firstmate-kiro-$ID is running"
KIRO_ARGS=$(tr '\0' ' ' < "/proc/$KIRO_PID/cmdline" 2>/dev/null || true)
case " $KIRO_ARGS" in
  *' chat --v3 -a --agent '*) pass "live: the real V3 launch carries the trust flag" ;;
  *) fail "live: the real V3 launch did not carry 'chat --v3 -a --agent': '${KIRO_ARGS:0:200}'" ;;
esac
rm -f "$FMHOME/state/$ID.turn-ended"
spawn_env "$ROOT/bin/fm-send.sh" "$ID" \
  "Trust proof, four steps in order: 1) use the shell tool to run exactly: printf 'ALPHA\\n' > trust-proof.txt 2) use your file editing tool's replace (str_replace) operation, never the shell, to change ALPHA to OMEGA in trust-proof.txt 3) read trust-proof.txt back with your file reading tool 4) reply with exactly TRUSTOK." \
  > "$LAB/trust-send.out" 2>&1 || { cat "$LAB/trust-send.out" >&2; fail "trust-turn steer failed"; }
i=0
while [ "$i" -lt "${FM_KIRO_LIVE_TIMEOUT:-180}" ] && [ ! -f "$FMHOME/state/$ID.turn-ended" ]; do
  sleep 1
  i=$((i + 1))
done
TAIL=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -200 -t "$TARGET" 2>/dev/null || true)
if printf '%s\n' "$TAIL" | grep -qiE 'experiencing high traffic|ThrottlingException|monthly usage limit'; then
  printf '%s\n' "$TAIL" >&2
  fail "live: the Kiro provider refused the trust turn (capacity or quota), so trust was not exercised; retry later"
fi
if printf '%s\n' "$TAIL" | grep -qiE 'requires approval|Always allow|trust \[session\]'; then
  printf '%s\n' "$TAIL" >&2
  fail "live: the real V3 worker rendered a tool approval dialog"
fi
[ -f "$FMHOME/state/$ID.turn-ended" ] \
  || { printf '%s\n' "$TAIL" >&2; fail "live: the trust turn never reached Stop within the timeout (a parked approval dialog ends here)"; }
[ -f "$WT/trust-proof.txt" ] || fail "live: the shell tool did not create trust-proof.txt in the worktree"
grep -qx 'OMEGA' "$WT/trust-proof.txt" \
  || fail "live: fs_write replace did not land; trust-proof.txt holds '$(cat "$WT/trust-proof.txt")'"
case "$TAIL" in
  *TRUSTOK*) ;;
  *) printf '%s\n' "$TAIL" >&2; fail "live: the trust turn did not finish with TRUSTOK" ;;
esac
pass "live: a fresh V3 worker read, ran shell, and replaced file content with no approval dialog"

# 4) Control: interrupt (Escape) preserves the pane; exit (/quit) stops the agent.
spawn_env "$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.out" 2>&1 \
  || { cat "$LAB/interrupt.out" >&2; fail "fm-control interrupt failed"; }
env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" has-session -t "${TARGET%%:*}" 2>/dev/null \
  || fail "interrupt must preserve the pane, but the session is gone"
pass "live: fm-control interrupt (Escape) preserves the pane"

# fm-control exit types /quit only after the shared classifier proves the
# Kiro-attributed bright placeholder is the exact idle text. The fleet-wide
# ghost ceiling remains unchanged, so real pending text and another harness
# rendering the same phrase still defer.
spawn_env "$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.out" 2>&1 \
  || { cat "$LAB/exit.out" >&2; fail "fm-control exit did not accept the real idle Kiro placeholder"; }
pass "live: fm-control exit (/quit) stopped the agent from its bright idle placeholder"

# 5) Teardown removes every artifact (force-discard: this scratch task never lands).
spawn_env "$ROOT/bin/fm-teardown.sh" "$ID" --force > "$LAB/teardown.out" 2>&1 \
  || { cat "$LAB/teardown.out" >&2; fail "fm-teardown of the live kiro-cli task failed"; }
[ ! -d "$FMHOME/state/$ID.kiro-home" ] || fail "teardown left the per-task KIRO_HOME behind"
[ ! -f "$FMHOME/state/$ID.kiro-turnend-token" ] || fail "teardown left the turn-end token behind"
[ ! -f "$META" ] || fail "teardown left the task record behind"
pass "live: fm-teardown removed every kiro-cli artifact"

trap - EXIT
cleanup
echo "ok - kiro-cli live crewmate signals (turn-end, detection, busy/idle, control, teardown) passed"
