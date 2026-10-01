#!/usr/bin/env bash
# tests/fm-send-inbox-claude-selector-live-e2e.test.sh - the live guard for a
# steer rung while Claude Code's agent selector shows a background subagent
# (issue #6131; live-harness-optin family).
#
# While a subagent is viewed, text submitted in the pane goes to that subagent,
# so a doorbell rung there used to report success and never reach main.
# bin/fm-task-inbox-lib.sh now walks the selector back to main first, reading
# the view through fm_composer_claude_agent_view in bin/fm-composer-lib.sh.
# Both read rendered Claude output and keys whose effect Claude defines, so per
# .agents/skills/firstmate-coding-guidelines this is proven against the real
# harness: Claude is launched idle in an isolated tmux server with
# FM_TASK_INBOX exported as bin/fm-spawn.sh does, asked to start one long
# background subagent, and driven into that subagent's view. The REAL
# bin/fm-send.sh then steers it, and main must both ACT on the instruction and
# ACKNOWLEDGE it with the mv into handled/. Any failure names the version.
#
# Run explicitly with FM_SEND_INBOX_SELECTOR_LIVE_E2E=1. It spends real model
# tokens on two short main turns and one subagent turn. An absent claude is
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

home="$LAB/home"
task="selector"
mkdir -p "$home/state"
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
printf '# claude (%s): the agent selector shows the subagent before the steer\n' "$VERSION"

acted="$LAB/acted"
printf 'window=%s\nkind=ship\nharness=claude\n' "$T" > "$home/state/$task.meta"
FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
  "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
  >/dev/null 2>&1 || die "fm-send refused the live steer"
[ "$(view)" = main ] || die "the steer left the selector on $(view) instead of main"

handled="$home/state/$task.inbox/handled/001.msg"
i=0
until [ -f "$handled" ] && [ -e "$acted" ]; do
  i=$((i + 1))
  [ "$i" -lt "$TIMEOUT" ] \
    || die "main did not honor the doorbell within ${TIMEOUT}s (acted=$([ -e "$acted" ] && echo yes || echo no) acked=$([ -f "$handled" ] && echo yes || echo no))"
  sleep 1
done
pass "claude ($VERSION): a steer rung while the agent selector showed a subagent reached main, which acted and acked"
