#!/usr/bin/env bash
# Opt-in credentialed Codex regression for the native queue doorbell.
#
# This is manual/live evidence, not portable CI coverage. It launches a real
# interactive Codex TUI in an isolated tmux server, obtains the exact thread UUID
# from that TUI's native CODEX_THREAD_ID tool environment, and uses only
# `codex queue` for the two subsequent idle/busy deliveries. No terminal input
# is injected. Project SessionStart hooks are deliberately not part of this
# transport proof: Codex 0.150.1 does not load them for this interactive path.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex queue continuity regression"
  exit 0
fi

CODEX_BIN=$(command -v codex 2>/dev/null || true)
TMUX_BIN=$(command -v tmux 2>/dev/null || true)

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

[ -n "$CODEX_BIN" ] || fail "codex not found"
[ -n "$TMUX_BIN" ] || fail "tmux not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
"$CODEX_BIN" queue --help 2>&1 | grep -Fq -- '--thread' || fail "installed Codex has no queue --thread capability"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-queue-live.XXXXXX") || fail "could not create live-test directory"
PROJECT="$LAB/project"
THREAD_FILE="$PROJECT/.codex/live-thread"
INITIAL_MARKER="$PROJECT/.codex/initial-done"
IDLE_MARKER="$PROJECT/.codex/idle-done"
BUSY_MARKER="$LAB/busy-started"
BUSY_FIRST_DONE="$LAB/busy-first-done"
BUSY_SECOND_DONE="$LAB/busy-second-done"
ORDER_LOG="$LAB/order.log"
TUI_OUTPUT="$LAB/tui-output.log"
SOCKET="fm-codex-queue-live-$$"
SESSION="fm-codex-queue-live"
CODEX_VERSION=$("$CODEX_BIN" --version)
TRUST_CONFIG="projects={\"$PROJECT\"={trust_level=\"trusted\"}}"

cleanup() {
  "$TMUX_BIN" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT

wait_for_path() { # <path> <timeout-seconds>
  local path=$1 timeout=$2 started now
  started=$(date +%s)
  while [ ! -e "$path" ]; do
    "$TMUX_BIN" -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null \
      || fail "Codex TUI exited before creating $path"
    now=$(date +%s)
    [ $((now - started)) -lt "$timeout" ] || fail "timed out waiting for $path"
    sleep 0.2
  done
}

mkdir -p "$PROJECT/.codex"
git -C "$PROJECT" init -q
# shellcheck disable=SC2016 # The model, not this shell, expands CODEX_THREAD_ID.
initial_prompt='Run exactly `printf '\''%s\n'\'' "$CODEX_THREAD_ID" > .codex/live-thread; touch .codex/initial-done` in the shell, then reply with exactly INITIAL_DONE.'
launch_cmd=$(printf 'exec %q --no-alt-screen --dangerously-bypass-approvals-and-sandbox -c %q -c %q %q 2>%q' \
  "$CODEX_BIN" 'model_reasoning_effort="low"' "$TRUST_CONFIG" "$initial_prompt" "$TUI_OUTPUT")
"$TMUX_BIN" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" "$launch_cmd" \
  || fail "could not launch isolated Codex TUI"

wait_for_path "$INITIAL_MARKER" 120
THREAD=$(sed -n '1p' "$THREAD_FILE" 2>/dev/null) || fail "initial turn did not expose CODEX_THREAD_ID"
printf '%s\n' "$THREAD" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
  || fail "the native tool environment returned an invalid thread UUID: $THREAD"

# shellcheck disable=SC2016 # Backticks are literal model instructions.
"$CODEX_BIN" queue -C "$PROJECT" --thread "$THREAD" --message 'Run exactly `touch .codex/idle-done` in the shell, then reply with exactly QUEUE_IDLE_DONE.' \
  > "$LAB/idle-queue.out" 2>&1 || fail "idle codex queue failed: $(cat "$LAB/idle-queue.out")"
wait_for_path "$IDLE_MARKER" 120

busy_prompt=$(printf 'Run exactly `printf '\''first-start\\n'\'' >> %q; touch %q; sleep 12; printf '\''first-end\\n'\'' >> %q; touch %q` in the shell, then reply with exactly BUSY_FIRST_DONE.' "$ORDER_LOG" "$BUSY_MARKER" "$ORDER_LOG" "$BUSY_FIRST_DONE")
"$CODEX_BIN" queue -C "$PROJECT" --thread "$THREAD" --message "$busy_prompt" \
  > "$LAB/busy-first-queue.out" 2>&1 || fail "first busy codex queue failed: $(cat "$LAB/busy-first-queue.out")"
wait_for_path "$BUSY_MARKER" 120
if [ -e "$BUSY_FIRST_DONE" ]; then
  fail "busy first turn completed before the serialization probe was queued"
fi
busy_second_prompt=$(printf 'After the current work, run exactly `printf '\''second\\n'\'' >> %q; touch %q` in the shell, then reply with exactly BUSY_SECOND_DONE.' "$ORDER_LOG" "$BUSY_SECOND_DONE")
"$CODEX_BIN" queue -C "$PROJECT" --thread "$THREAD" --message "$busy_second_prompt" \
  > "$LAB/busy-second-queue.out" 2>&1 || fail "second busy codex queue failed: $(cat "$LAB/busy-second-queue.out")"
wait_for_path "$BUSY_FIRST_DONE" 120
wait_for_path "$BUSY_SECOND_DONE" 120

order=$(cat "$ORDER_LOG" 2>/dev/null || true)
[ "$order" = $'first-start\nfirst-end\nsecond' ] \
  || fail "busy queue did not serialize after the active turn: $order"

printf 'ok - %s live E2E used the native CODEX_THREAD_ID, woke an idle TUI, and serialized a busy queue turn without terminal keystrokes\n' \
  "$CODEX_VERSION"
