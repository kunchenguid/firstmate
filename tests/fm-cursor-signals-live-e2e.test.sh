#!/usr/bin/env bash
# Opt-in live guard for the cursor (Cursor Agent CLI) crewmate adapter.
# Exercises the installed, authenticated cursor-agent binary for the signals
# firstmate depends on: process identity, autonomy flags, positional brief,
# Ctrl+C interrupt, /exit, project stop-hook turn-end, and busy-hook open/close.
#
# Usage: FM_CURSOR_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-cursor-signals-live-e2e.test.sh
# Skips (exit 0) when the env gate is unset.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

if [ "${FM_CURSOR_SIGNALS_LIVE:-}" != 1 ]; then
  echo "skip: set FM_CURSOR_SIGNALS_LIVE=1 to run live cursor-agent signal checks"
  exit 0
fi

if ! command -v cursor-agent >/dev/null 2>&1; then
  fail "cursor-agent not installed; live cursor verification checked nothing"
fi

if ! command -v tmux >/dev/null 2>&1; then
  fail "tmux is required for the live cursor signal guard"
fi

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required to parse cursor hook JSON payloads"
fi

VERSION=$(cursor-agent --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || fail "cursor-agent --version produced no output"
echo "live cursor-agent version: $VERSION"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-cursor-live.XXXXXX")
SESSION="fm-cursor-live-$$"
cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

cd "$SCRATCH" || exit 1
git init -q
printf 'hi\n' > README.md
git add README.md
git commit -qm init
mkdir -p .cursor/hooks
PROBE_LOG="$SCRATCH/probe.log"
: > "$PROBE_LOG"
cat > .cursor/hooks/probe.sh <<EOF
#!/usr/bin/env bash
set -u
payload=\$(cat)
python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hook_event_name","?"), d.get("status","-"))' <<<"\$payload" >> $(printf '%q' "$PROBE_LOG") 2>/dev/null \\
  || printf '? -\\n' >> $(printf '%q' "$PROBE_LOG")
printf '{}\\n'
EOF
chmod 700 .cursor/hooks/probe.sh
cat > .cursor/hooks.json <<'JSON'
{
  "version": 1,
  "hooks": {
    "beforeSubmitPrompt": [{"command": ".cursor/hooks/probe.sh"}],
    "stop": [{"command": ".cursor/hooks/probe.sh"}],
    "sessionEnd": [{"command": ".cursor/hooks/probe.sh"}]
  }
}
JSON

tmux new-session -d -s "$SESSION" -c "$SCRATCH" -x 120 -y 36
tmux send-keys -t "$SESSION" \
  "cursor-agent --yolo --trust --model composer-2.5-fast 'Reply with exactly LIVEOK, then stop.'" \
  Enter

saw_ready=0
for _ in $(seq 1 40); do
  sleep 2
  # Match the agent reply row, not the prompt that contains the same token.
  if tmux capture-pane -t "$SESSION" -p | grep -E '^[[:space:]]*LIVEOK[[:space:]]*$' >/dev/null; then
    saw_ready=1
    break
  fi
done
[ "$saw_ready" = 1 ] || fail "cursor-agent never produced LIVEOK"$'\n'"$(tmux capture-pane -t "$SESSION" -p | tail -40)"

# Process identity: the documented wrapper preserves the exact cursor-agent
# argv0.  This is the guaranteed detection signal; the vendor does not promise
# a CURSOR_AGENT environment marker.
pane_pid=$(tmux display-message -t "$SESSION" -p '#{pane_pid}')
child=$(pgrep -P "$pane_pid" | head -1)
[ -n "$child" ] || fail "no child process under cursor pane"
comm=$(ps -o comm= -p "$child" | tr -d ' ')
args=$(ps -o args= -p "$child")
argv0=${args%% *}
identity=$(fm_harness_path_name "$comm" 2>/dev/null \
  || fm_harness_path_name "$argv0" 2>/dev/null || true)
fm_harness_process_matches "$comm" "$args" \
  || fail "foreground child was not a verified harness process (comm='$comm' argv0='$argv0')"
[ "$identity" = cursor-agent ] \
  || fail "foreground child was not Cursor (comm='$comm' argv0='$argv0')"

# Autonomy: --yolo on the live process argv (footer also shows Run Everything).
ps -p "$child" -o args= | grep -q -- '--yolo' \
  || fail "live cursor-agent argv missing --yolo"

# Hooks fired for the positional launch brief.  The reply is rendered before
# the stop hook runs, so wait on the hook's durable protocol output rather than
# treating the first visible response as a completed turn.
grep -q 'beforeSubmitPrompt' "$PROBE_LOG" \
  || fail "beforeSubmitPrompt never fired for positional launch"$'\n'"$(cat "$PROBE_LOG" 2>/dev/null)"
saw_stop=0
for _ in $(seq 1 15); do
  if grep -q 'stop completed' "$PROBE_LOG"; then
    saw_stop=1
    break
  fi
  sleep 1
done
[ "$saw_stop" = 1 ] \
  || fail "stop completed never fired after LIVEOK"$'\n'"$(cat "$PROBE_LOG" 2>/dev/null)"

# Interrupt path.
tmux send-keys -t "$SESSION" -l 'Run shell: sleep 90'
sleep 0.4
tmux send-keys -t "$SESSION" Enter
sleep 4
tmux capture-pane -t "$SESSION" -p | grep -qi 'ctrl+c to stop' \
  || fail "busy footer 'ctrl+c to stop' missing mid-turn"
tmux send-keys -t "$SESSION" C-c
sleep 2
tmux capture-pane -t "$SESSION" -p | grep -qi 'Cancelled' \
  || fail "Ctrl+C did not cancel the in-flight shell"$'\n'"$(tmux capture-pane -t "$SESSION" -p | tail -40)"
grep -Eq 'stop (aborted|error|completed)' "$PROBE_LOG" \
  || fail "stop hook did not fire after interrupt"$'\n'"$(cat "$PROBE_LOG" 2>/dev/null)"

# Exit path.
tmux send-keys -t "$SESSION" -l '/exit'
sleep 1.2
tmux send-keys -t "$SESSION" Enter
sleep 3
pgrep -P "$pane_pid" >/dev/null 2>&1 \
  && fail "cursor-agent still running after /exit"
grep -q 'sessionEnd' "$PROBE_LOG" \
  || fail "sessionEnd never fired after /exit"$'\n'"$(cat "$PROBE_LOG" 2>/dev/null)"

pass "live cursor-agent signals verified on $VERSION"
