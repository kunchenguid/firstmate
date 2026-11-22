#!/usr/bin/env bash
# Live Claude doorbell submission on tmux and Herdr (live-harness-optin).
# The first ring uses each backend's ordered paste-and-Enter operation. The
# second ring submits a doorbell left in the real composer without retyping it.
# The third rings while Claude is running a timed shell command.
# Run with FM_TASK_INBOX_PASTE_LIVE_E2E=1. Both backends use isolated sessions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fm_live_gate opt-in FM_TASK_INBOX_PASTE_LIVE_E2E tmux herdr jq claude

LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
TMP_ROOT=$(fm_test_tmproot fm-task-inbox-paste-live)
FM_HOME="$TMP_ROOT/home"
FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/herdr-state"
export FM_HOME FM_HERDR_LAB_STATE_DIR
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name inbox-paste-live)
LAB_TMUX_DIR=
TMUX_SOCKET=
ORIGINAL_PATH=$PATH

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$TMUX_SOCKET" ] && [ -S "$TMUX_SOCKET" ]; then
    PATH="$ORIGINAL_PATH" tmux -S "$TMUX_SOCKET" kill-server || rc=1
  fi
  if [ -n "$LAB_TMUX_DIR" ]; then
    PATH="$ORIGINAL_PATH" "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  fi
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null || fail 'could not create lab home'
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME") || fail 'could not create private tmux directory'
TMUX_SOCKET="$LAB_TMUX_DIR/tmux-$(id -u)/fm-inbox-paste"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision isolated Herdr session'

SHIM="$TMP_ROOT/shim"
mkdir -p "$SHIM"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec env TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L fm-inbox-paste "\$@"
SH
cat > "$SHIM/herdr" <<SH
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -lt 2 ] || [ "\${args[\$((n-2))]}" != --session ] || [ "\${args[\$((n-1))]}" != "$HERDR_LAB_SESSION" ]; then
  echo 'refusing Herdr call outside the named lab session' >&2
  exit 97
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]:0:\$((n-2))}"
SH
chmod +x "$SHIM/tmux" "$SHIM/herdr"
PATH="$SHIM:$ORIGINAL_PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_source tmux || fail 'could not load tmux adapter'
fm_backend_source herdr || fail 'could not load Herdr adapter'
lab() { PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

CLAUDE_VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf unknown)
HERDR_VERSION=$(lab status --json | jq -r '.client.version // "unknown"')

wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 screen state i=0 trusted=0
  while [ "$i" -lt 90 ]; do
    screen=$(fm_backend_capture "$backend" "$target" 60 2>/dev/null || true)
    case "$screen" in
      *'Yes, I trust this folder'*)
        if [ "$trusted" -eq 0 ]; then
          trusted=1
          fm_backend_send_key "$backend" "$target" down >/dev/null 2>&1 || true
          fm_backend_send_key "$backend" "$target" Enter >/dev/null 2>&1 || true
        fi ;;
      *'bypass permissions on'*)
        state=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || true)
        [ "$state" = empty ] && return 0 ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  printf '%s\n' "$screen" | tail -20 >&2
  printf 'composer state: %s\n' "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || true)" >&2
  fail "Claude $CLAUDE_VERSION on $backend did not reach an empty composer"
}

wait_ack() {  # <backend> <record> <marker>
  local backend=$1 rec=$2 marker=$3 i=0
  while [ "$i" -lt 90 ]; do
    [ -f "${rec%/*}/handled/${rec##*/}" ] && [ -e "$marker" ] && return 0
    i=$((i + 1))
    sleep 1
  done
  fail "Claude $CLAUDE_VERSION on $backend did not act on and acknowledge ${rec##*/}"
}

exercise_backend() {  # <backend> <target> <task>
  local backend=$1 target=$2 task=$3 rec marker line state busy_marker i
  wait_ready "$backend" "$target"
  marker="$TMP_ROOT/acted-$task-first"
  rec=$(fm_task_inbox_write "$FM_HOME/state" "$task" "Run the shell command \`touch $marker\`, then move this message to handled/ as the doorbell instructed.") \
    || fail "$backend could not write the first inbox record"
  FM_COMPOSER_HARNESS=claude fm_task_inbox_ring "$backend" "$target" "$rec" \
    || fail "$backend could not ring the ordered doorbell"
  wait_ack "$backend" "$rec" "$marker"
  pass "Claude $CLAUDE_VERSION on $backend: ordered doorbell submitted and acknowledged"

  wait_ready "$backend" "$target"
  marker="$TMP_ROOT/acted-$task-held"
  rec=$(fm_task_inbox_write "$FM_HOME/state" "$task" "Run the shell command \`touch $marker\`, then move this message to handled/ as the doorbell instructed.") \
    || fail "$backend could not write the held inbox record"
  line=$(fm_task_inbox_doorbell_line "$rec") || fail "$backend could not construct the held doorbell"
  case "$backend" in
    tmux) fm_backend_tmux_send_literal "$target" "$line" || fail 'tmux could not hold a doorbell' ;;
    herdr) fm_backend_herdr_send_literal "$target" "$line" || fail 'Herdr could not hold a doorbell' ;;
  esac
  state=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || true)
  [ "$state" = pending ] || fail "$backend did not show the held doorbell as pending ($state)"
  FM_COMPOSER_HARNESS=claude fm_task_inbox_ring "$backend" "$target" "$rec" \
    || fail "$backend could not submit the held doorbell"
  wait_ack "$backend" "$rec" "$marker"
  pass "Claude $CLAUDE_VERSION on $backend: held doorbell submitted without retyping"

  wait_ready "$backend" "$target"
  busy_marker="$TMP_ROOT/busy-$task"
  fm_backend_paste_submit "$backend" "$target" \
    "Run exactly this single shell command now: sh -c 'touch $busy_marker; sleep 15'. Reply only after it finishes." \
    || fail "$backend could not start the busy-turn probe"
  i=0
  while [ "$i" -lt 60 ] && [ ! -e "$busy_marker" ]; do
    i=$((i + 1))
    sleep 0.5
  done
  [ -e "$busy_marker" ] || fail "$backend never began the busy-turn shell command"
  marker="$TMP_ROOT/acted-$task-busy"
  rec=$(fm_task_inbox_write "$FM_HOME/state" "$task" "Run the shell command \`touch $marker\`, then move this message to handled/ as the doorbell instructed.") \
    || fail "$backend could not write the busy-turn inbox record"
  FM_COMPOSER_HARNESS=claude fm_task_inbox_ring "$backend" "$target" "$rec" \
    || fail "$backend could not ring while Claude was busy"
  wait_ack "$backend" "$rec" "$marker"
  pass "Claude $CLAUDE_VERSION on $backend: busy-turn doorbell submitted and acknowledged"
}

TMUX_SESSION=inbox-paste
TMUX_TARGET="$TMUX_SESSION:claude"
tmux -f /dev/null new-session -d -s "$TMUX_SESSION" -x 180 -y 48 -c "$ROOT" \
  || fail 'could not start isolated tmux server'
tmux new-window -d -t "$TMUX_SESSION:" -n claude -c "$ROOT" -- bash -lc \
  "export FM_TASK_INBOX=$(printf '%q' "$FM_HOME/state/tmux.inbox"); CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false exec claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" \
  || fail 'could not launch Claude in tmux'
exercise_backend tmux "$TMUX_TARGET" tmux

WS_JSON=$(lab workspace create --cwd "$ROOT" --label inbox-paste --no-focus) \
  || fail 'could not create Herdr lab workspace'
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail 'Herdr lab did not return a pane id'
HERDR_TARGET="$HERDR_LAB_SESSION:$PANE"
lab pane run "$PANE" \
  "FM_TASK_INBOX=$(printf '%q' "$FM_HOME/state/herdr.inbox") CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail 'could not launch Claude in Herdr'
exercise_backend herdr "$HERDR_TARGET" herdr
pass "Claude $CLAUDE_VERSION on Herdr $HERDR_VERSION: both backend regressions passed"
