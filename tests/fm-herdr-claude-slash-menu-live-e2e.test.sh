#!/usr/bin/env bash
# Live Herdr Claude slash-command menu guard (live-harness-optin family).
#
# Claude's classic renderer opens its completion menu for a typed `/exit`
# BELOW the composer, sized to about half the pane, so on a tall pane the
# payload proof's 20-row tail starts at the composer row and cannot select it.
# A fixture cannot prove how real Claude lays that menu out. This guard
# launches real Claude Code in an isolated Herdr lab with the classic renderer
# forced by a project setting, proves the menu really hides the composer from
# the 20-row tail while the widened proof read still shows it, and requires
# the real control-plane exit to stop an idle agent and a busy one. It fails
# naming the harness and version rather than degrading quietly.
# The busy case submits a prompt, so the guard is opt-in.
#
# Run explicitly with FM_HERDR_SLASH_MENU_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Claude slash-command menu" entry.
# Every Herdr call, including adapter and control-plane calls, is routed
# through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SLASH_MENU_LIVE herdr jq claude python3

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SLASH_MENU_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-slash-menu-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-slash-menu-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
PROJECT="$TMP_ROOT/project"
LAB_HOME="$TMP_ROOT/home"
TASK=slashmenu
mkdir -p "$FAKEBIN" "$PROJECT/.claude" "$LAB_HOME/state" "$LAB_HOME/data" "$LAB_HOME/config"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

# A project setting outranks the user's own, so this forces the classic
# renderer even on a host whose Claude defaults to fullscreen, where the menu
# is drawn above the composer and never reaches the proof's blind spot.
printf '{"tui":"default"}\n' > "$PROJECT/.claude/settings.json"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$PROJECT" --label fm-slashmenu --no-focus) \
  || fail "could not create the isolated slash-menu workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
WORKSPACE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.workspace_id') \
  || fail "workspace create did not return a workspace id"
TAB=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.tab_id') \
  || fail "workspace create did not return a tab id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# The menu takes about half the pane, so it only hides the composer from the
# 20-row tail on a pane of roughly 36 rows or more. A shorter lab pane would
# pass without exercising anything.
ROWS=$(lab pane get "$PANE" | jq -er '.result.pane.scroll.viewport_rows') \
  || fail "could not read the lab pane's viewport height"
[ "$ROWS" -ge 36 ] \
  || fail "the lab pane is only $ROWS rows, too short for the menu to hide the composer from the 20-row tail"

cat > "$LAB_HOME/state/$TASK.meta" <<EOF
window=$TARGET
endpoint_task_id=$TASK
worktree=$PROJECT
project=$PROJECT
harness=claude
kind=secondmate
mode=secondmate
yolo=off
tasktmp=
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE
herdr_tab_id=$TAB
herdr_pane_id=$PANE
home=$LAB_HOME
projects=
EOF

launch_claude() {
  lab pane run "$PANE" "env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --model haiku" >/dev/null \
    || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"
}

wait_idle() {  # <what>
  local i=0 st
  while [ "$i" -lt 60 ]; do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in
      idle|done) return 0 ;;
      blocked)
        # A fresh project path stops on Claude's folder-trust prompt. It
        # preselects "No, exit", so move to "Yes" before confirming.
        case "$(lab pane read "$PANE" --source visible 2>/dev/null || true)" in
          *'Allow external CLAUDE.md file imports?'*) lab pane send-keys "$PANE" enter >/dev/null \
            || fail "could not disable external CLAUDE.md imports in the lab" ;;
          *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null \
            || fail "could not accept Claude's folder-trust prompt" ;;
        esac
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  fail "Claude Code ($VERSION) on $HERDR_VER never went idle $1; agent: $(lab agent get "$PANE" 2>&1); screen:
$(screen_tail)"
}

screen_tail() {
  lab pane read "$PANE" --source visible 2>/dev/null | grep -v '^[[:space:]]*$' | tail -12 || true
}

control() {  # <verb>
  FM_HOME="$LAB_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$LAB_HOME/state" \
    FM_DATA_OVERRIDE="$LAB_HOME/data" FM_CONFIG_OVERRIDE="$LAB_HOME/config" \
    "$ROOT/bin/fm-control.sh" "$TASK" "$1" 2>&1
}

# Claude can report idle while its startup hooks still run, and keystrokes
# typed in that window render late or not at all. Settle first, then type once
# and require exactly the typed command to render; never retype, because late
# keystrokes would then stack.
STARTUP_SETTLE=10

typed_exit_shown() {
  lab pane read "$PANE" --source visible 2>/dev/null | LC_ALL=C sed 's/\xC2\xA0/ /g' | grep -q -E '^❯ /exit *$'
}

type_exit() {
  local i=0
  lab pane send-text "$PANE" /exit >/dev/null || fail "could not type /exit into the lab pane"
  while [ "$i" -lt 30 ]; do
    sleep 0.5
    typed_exit_shown && return 0
    i=$((i + 1))
  done
  fail "Claude Code ($VERSION) on $HERDR_VER: typed /exit never rendered as the composer row; screen:
$(screen_tail)"
}

launch_claude
wait_idle "after launch"
sleep "$STARTUP_SETTLE"

# Prove the blind spot is real before relying on the fix: with `/exit` typed,
# the 20-row tail cannot select the composer, while the proof's widened read
# returns exactly the typed command.
type_exit
if tail_read=$(fm_backend_herdr_composer_content "$TARGET" 20) && [ "$tail_read" = /exit ]; then
  fail "Claude Code ($VERSION) on $HERDR_VER: the 20-row tail still shows the composer with the menu open, so this guard checks nothing; is the classic renderer active?"
fi
proof_read=$(fm_backend_herdr_proof_content "$TARGET" 20) \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the widened proof read could not select the composer on a $ROWS-row pane"
[ "$proof_read" = /exit ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the widened proof read returned '$proof_read', not /exit; screen:
$(screen_tail)"
i=0
while [ "$(fm_backend_herdr_composer_state "$TARGET")" != empty ]; do
  [ "$i" -lt 10 ] || fail "could not clear the typed /exit from the lab composer"
  lab pane send-keys "$PANE" ctrl+u >/dev/null
  i=$((i + 1))
  sleep 0.3
done
pass "live Claude slash menu: Claude Code ($VERSION) on $HERDR_VER hides the composer from the 20-row tail on a $ROWS-row pane, and the widened proof read shows /exit"

sleep 2
out=$(control exit) || fail "Claude Code ($VERSION) on $HERDR_VER: idle exit failed: $out"
case "$out" in
  stopped*) ;;
  *) fail "Claude Code ($VERSION) on $HERDR_VER: idle exit reported '$out', not stopped" ;;
esac
CHECKED=$((CHECKED + 1))
pass "live Claude slash menu: fm-control exit stops an idle classic-renderer Claude Code ($VERSION) on $HERDR_VER"

sleep 2
launch_claude
wait_idle "after relaunch"
sleep "$STARTUP_SETTLE"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" \
  "This is a lab latency check. Call the Bash tool once, in the foreground, with command: python3 -c 'import time; time.sleep(120)'  then reply ok." 3 0.4 0.4) \
  || fail "could not submit the busy-turn prompt to Claude Code ($VERSION)"
[ "$verdict" = empty ] || fail "Claude Code ($VERSION) on $HERDR_VER: the busy-turn prompt was not confirmed submitted, got '$verdict'; screen:
$(screen_tail)"
busy=0
i=0
while [ "$i" -lt 60 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  if [ "$st" = working ] && printf '%s' "$screen" | grep -F -q 'Bash(python3'; then
    busy=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$busy" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never reached the foreground tool call"
sleep 2
out=$(control exit) || fail "Claude Code ($VERSION) on $HERDR_VER: busy exit failed: $out"
case "$out" in
  stopped*) ;;
  *) fail "Claude Code ($VERSION) on $HERDR_VER: busy exit reported '$out', not stopped" ;;
esac
CHECKED=$((CHECKED + 1))
pass "live Claude slash menu: fm-control exit interrupts and stops a busy classic-renderer Claude Code ($VERSION) on $HERDR_VER"

[ "$CHECKED" -eq 2 ] || fail "FM_HERDR_SLASH_MENU_LIVE=1 checked $CHECKED of 2 exits"
