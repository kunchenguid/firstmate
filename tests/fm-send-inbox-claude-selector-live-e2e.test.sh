#!/usr/bin/env bash
# tests/fm-send-inbox-claude-selector-live-e2e.test.sh - the live guard for a
# steer rung while Claude Code's agent selector shows a background subagent
# (issue #6131; live-harness-optin family).
#
# Run explicitly with FM_SEND_INBOX_SELECTOR_LIVE_E2E=1. It spends real model
# tokens on one main turn and one subagent turn. An absent claude is
# reported and fails rather than passing vacuously. Tune the waits with
# FM_SEND_INBOX_SELECTOR_LIVE_TIMEOUT (seconds, default 240). Record the dated
# result in docs/verification/runtime-backends.md ("Claude agent selector").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_SELECTOR_LIVE_E2E tmux claude

unset NO_MISTAKES_GATE

SOCKET="fm-selector-live-$$"
SESSION="selectorlive"
WIN="claude"
T="$SESSION:$WIN"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-selector-live.XXXXXX")
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_SELECTOR_LIVE_TIMEOUT:-240}

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

# fm-send and every backend read reach tmux through bare `tmux` calls, so a
# PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_SELECTOR_INPUT_LOG:-}" ]; then
  case "\${1:-}" in send-keys) printf '%s\n' "\$*" >> "\$FM_SELECTOR_INPUT_LOG" ;; esac
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

# A login shell can resolve a different claude than this one, so the pane
# launches, and the result names, this exact binary.
CLAUDE_BIN=$(command -v claude)
VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION=version-unknown

die() {  # <message>
  printf 'not ok - claude (%s): %s\n' "$VERSION" "$1" >&2
  tmux -L "$SOCKET" capture-pane -p -t "$T" 2>/dev/null | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  exit 1
}

view() { fm_task_inbox_agent_view tmux "$T"; }

submit() {  # <text>
  tmux -L "$SOCKET" send-keys -t "$T" -l "$1"
  sleep 0.5
  tmux -L "$SOCKET" send-keys -t "$T" Enter
}

check_refusal() {
  local start=$1 seq=$2 target rc rec
  : > "$LAB/input.log"
  FM_SELECTOR_INPUT_LOG="$LAB/input.log" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-send.sh" "$task" "Firstmate live check: reply REFUSAL_GUARD_RECEIVED." \
    > "$LAB/send.out" 2> "$LAB/send.err" || die "fm-send failed to record the live steer"
  grep -q 'doorbell did not reach' "$LAB/send.err" || die "the $start ring was not reported undelivered"
  rec="$home/state/$task.inbox/$seq.msg"
  [ -f "$rec" ] && [ ! -e "$home/state/$task.inbox/handled/$seq.msg" ] \
    || die "the $start refusal did not retain the unhandled steer"
  [ ! -s "$LAB/input.log" ] || die "the $start ring sent terminal input"
  [ "$(view)" = "$start" ] || die "the $start ring changed the selector"
  for target in "$T" "$task"; do
    rc=0
    FM_SELECTOR_INPUT_LOG="$LAB/input.log" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
      "$ROOT/bin/fm-send.sh" "$target" /help > "$LAB/send.out" 2> "$LAB/send.err" || rc=$?
    [ "$rc" = 1 ] || die "the $start typed send to $target was not refused (exit $rc)"
    grep -q 'Claude agent-selector preflight failed' "$LAB/send.err" \
      || die "the $start typed send failed outside the selector preflight"
    [ ! -s "$LAB/input.log" ] || die "the $start typed send emitted terminal input"
    [ "$(view)" = "$start" ] || die "the $start typed send changed the selector"
  done
  pass "claude ($VERSION): $start refuses inbox rings and typed sends without terminal input"
}

home="$LAB/home"
task="selector"
mkdir -p "$home/state"
printf 'window=%s\nkind=ship\nharness=claude\n' "$T" > "$home/state/$task.meta"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -n "$WIN" -x 160 -y 50 -c "$ROOT" \
  -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 $(printf '%q' "$CLAUDE_BIN") --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" \
  || die "could not launch in the isolated tmux server"

i=0
until [ "$(fm_tmux_composer_state "$T")" = empty ]; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || die "the idle composer never classified empty"
  sleep 1
done

submit "Use the Agent tool with run_in_background=true to start ONE general-purpose subagent whose only job is to run this Bash command in the foreground with timeout 600000: python3 -c 'import time; time.sleep(540)' and then reply OK. Do not edit any files. After starting it, reply STARTED and end your turn without waiting for it."
i=0
until [ "$(view)" = main ]; do
  i=$((i + 1))
  [ "$i" -lt "$TIMEOUT" ] || die "no agent list with main viewed appeared after starting a background subagent"
  sleep 1
done

i=0
until [ "$(view)" = list-main-viewed ]; do
  i=$((i + 1))
  [ "$i" -le 4 ] || die "Down never focused the main entry (view $(view))"
  tmux -L "$SOCKET" send-keys -t "$T" Down
  sleep 1.5
done
check_refusal list-main-viewed 001

# Enter the subagent's view the way a person does: focus the list, move to the
# subagent, view it, then leave the list.
i=0
while [ "$(view)" != list-other ]; do
  i=$((i + 1))
  [ "$i" -le 4 ] || die "Down never moved the agent list cursor to the subagent (view $(view))"
  tmux -L "$SOCKET" send-keys -t "$T" Down
  sleep 1.5
done
tmux -L "$SOCKET" send-keys -t "$T" Enter
sleep 1.5
tmux -L "$SOCKET" send-keys -t "$T" Escape
sleep 1.5
[ "$(view)" = subagent ] || die "the pane did not settle in the subagent's view (view $(view))"
check_refusal subagent 002
