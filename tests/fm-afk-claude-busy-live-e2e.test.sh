#!/usr/bin/env bash
# Real Claude busy/idle guard for the away-mode Herdr injection path.
# Prompt-submitting: opt-in after a Claude or Herdr upgrade.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fm_live_gate opt-in FM_AFK_CLAUDE_BUSY_LIVE herdr jq claude
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-afk-claude-busy)
ORIGINAL_PATH=$PATH
LAB_DIR=$(mktemp -d "$ROOT/.afk-claude-live.XXXXXX")
cleanup() {
  local rc=$? cleared=0 attempt=0
  trap - EXIT
  # The adapter shim rejects lifecycle calls; tear down with the original
  # Herdr PATH while retaining the helper's refuse-default tripwire.
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    if PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1; then
      cleared=1
      break
    fi
    sleep 2
  done
  if [ "$cleared" -ne 1 ]; then
    PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fi
  rm -rf "$LAB_DIR"
  exit "$rc"
}
trap cleanup EXIT
fail() { printf 'not ok - Claude Code %s on Herdr %s: %s\n' "$CLAUDE_VERSION" "$HERDR_VERSION" "$1" >&2; exit 1; }
CLAUDE_VERSION=$(claude --version | head -1)
HERDR_VERSION=$(herdr --version | head -1)
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'lab provisioning failed'
# The backend adapter calls Herdr with an explicit session. Route even these
# calls through the lab helper; any foreign or unscoped command is refused.
cat > "$LAB_DIR/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ] || exit 98
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$LAB_DIR/herdr"
export PATH="$LAB_DIR:$ORIGINAL_PATH"
lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
FM_DAEMON_PRIMARY_HARNESS=claude
export FM_DAEMON_PRIMARY_HARNESS
WS=$(lab workspace create --cwd "$ROOT" --label afkbusy --no-focus) || fail 'workspace create failed'
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id') || fail 'missing pane id'
TARGET="$HERDR_LAB_SESSION:$PANE"
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null || fail 'Claude launch failed'
ready=0
for i in $(seq 1 60); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*) ready=1; break ;;
    *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null || fail 'trust dialog failed' ;;
  esac
  sleep 1
done
[ "$ready" = 1 ] || fail 'idle composer not rendered'
# The first prompt after launch intermittently went unanswered within the
# background wait, so complete one round trip first. Enter repeats until the
# reply renders; on an empty composer it is a no-op.
lab pane send-text "$PANE" 'Reply with exactly WARM_READY and stop.' >/dev/null || fail 'warm-up prompt failed'
warm=0
for i in $(seq 1 90); do
  if [ $((i % 3)) = 1 ]; then lab pane send-keys "$PANE" enter >/dev/null || fail 'warm-up submit failed'; fi
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'⏺ WARM_READY'*'❯'*) warm=1; break ;; esac
  sleep 1
done
[ "$warm" = 1 ] || fail 'Claude never accepted a submitted prompt'
# shellcheck disable=SC2016
lab pane send-text "$PANE" 'Use the Bash tool to start a tracked background command `sleep 90` (run_in_background=true). Once started, reply exactly BACKGROUND_READY and stop. Do not wait for it.' >/dev/null || fail 'background prompt failed'
# Settle after typing before Enter, as the product's Herdr submit path does.
sleep 1
lab pane send-keys "$PANE" enter >/dev/null || fail 'background submit failed'
settled=0
for i in $(seq 1 75); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'⏺ BACKGROUND_READY'*'shell still running'*'❯'*)
      [ "$(lab agent get "$PANE" | jq -r '.result.agent.agent_status // empty')" != working ] && { settled=1; break; }
      ;;
  esac
  sleep 1
done
[ "$settled" = 1 ] || fail 'tracked background Bash task did not settle to an idle composer'
native=$(lab agent get "$PANE" | jq -r '.result.agent.agent_status // empty')
[ "$native" != working ] || fail 'native state stayed working after reply'
if pane_is_busy "$TARGET" herdr; then fail "idle background task judged busy (source=$PANE_BUSY_SOURCE native=$native)"; fi
# shellcheck disable=SC2016
lab pane send-text "$PANE" 'Run the Bash tool command `sleep 12` in the foreground, then reply exactly TURN_DONE.' >/dev/null || fail 'foreground prompt failed'
sleep 1
lab pane send-keys "$PANE" enter >/dev/null || fail 'foreground submit failed'
busy=0
for i in $(seq 1 14); do
  if pane_is_busy "$TARGET" herdr; then busy=1; break; fi
  sleep 1
done
[ "$busy" = 1 ] || fail 'mid-turn Claude never read busy from native or rendered evidence'
settled=0
for i in $(seq 1 50); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'⏺ TURN_DONE'*'❯'*)
    if ! pane_is_busy "$TARGET" herdr; then settled=1; break; fi ;;
  esac
  sleep 1
done
[ "$settled" = 1 ] || fail 'completed turn remained busy'
lab pane send-text "$PANE" 'Reply with exactly ACK and stop.' >/dev/null || fail 'one-line prompt failed'
sleep 1
lab pane send-keys "$PANE" enter >/dev/null || fail 'one-line submit failed'
settled=0
for i in $(seq 1 45); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'⏺ ACK'*'❯'*)
    if ! pane_is_busy "$TARGET" herdr; then settled=1; break; fi ;;
  esac
  sleep 1
done
[ "$settled" = 1 ] || fail 'idle one-line reply still judged busy'
# Exit the test agent and its tracked background task before lab teardown.
# Claude prompts for confirmation rather than stopping a live task on /exit.
lab pane send-text "$PANE" '/exit' >/dev/null || fail 'exit text failed'
sleep 1
lab pane send-keys "$PANE" enter >/dev/null || fail 'exit submit failed'
for i in $(seq 1 15); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'Background work is running'*) lab pane send-keys "$PANE" enter >/dev/null || fail 'exit confirmation failed'; break ;; esac
  sleep 1
done
exited=0
i=0
while [ "$i" -lt 25 ]; do
  if ! lab agent get "$PANE" >/dev/null 2>&1; then exited=1; break; fi
  i=$((i + 1))
  sleep 1
done
[ "$exited" = 1 ] || fail 'Claude did not exit after test'
printf 'ok - Claude Code %s on Herdr %s: background task and one-line reply idle, mid-turn busy\n' "$CLAUDE_VERSION" "$HERDR_VERSION"
