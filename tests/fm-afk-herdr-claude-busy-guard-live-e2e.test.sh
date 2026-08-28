#!/usr/bin/env bash
# Live Herdr+Claude regression for the away-mode native-background busy guard.
#
# This opt-in test uses the real Claude native `/afk` path, so the daemon's
# tracked background Bash remains visible to Herdr while Claude's foreground
# composer returns idle.
# It fails naming the Claude and Herdr versions instead of silently replacing
# the real harness with a fixture.
# Every Herdr operation, including adapter calls, is routed through the named
# lab helper and never through the captain's default session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AFK_LAUNCH="$ROOT/bin/fm-afk-launch.sh"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_AFK_HERDR_CLAUDE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AFK_HERDR_CLAUDE_LIVE=1 to run the live Herdr+Claude away-mode guard"
  exit 0
fi

for tool in herdr jq claude; do
  command -v "$tool" >/dev/null 2>&1 || fail "FM_AFK_HERDR_CLAUDE_LIVE=1 but $tool is not installed"
done
[ -x "$HERDR_LAB_HELPER" ] \
  || fail "FM_AFK_HERDR_CLAUDE_LIVE=1 but the Herdr lab helper is not executable at $HERDR_LAB_HELPER"

ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-afk-herdr-claude-busy-guard-f1) \
  || fail "could not generate the isolated Herdr lab session name"
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-afk-herdr-claude-guard.XXXXXX") \
  || fail "could not create the live-test temporary root"
STATE_DIR="$TMP_ROOT/state"
FAKEBIN="$TMP_ROOT/fakebin"
FM_HOME="$TMP_ROOT/home"
mkdir -p "$STATE_DIR" "$FAKEBIN" "$FM_HOME"

export HERDR_LAB_HELPER HERDR_LAB_SESSION
# The exact lab teardown trap is installed before provisioning as required by
# the Herdr isolation contract.
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

# The adapter appends the session flag before this wrapper sees the call.
# The wrapper strips and re-routes that call through the lab helper, so a
# missing or foreign session flag fails closed during the live test.
cat > "$FAKEBIN/herdr" <<SHIM
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ] || {
    echo "live-test wrapper refused foreign Herdr session" >&2
    exit 97
  }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "live-test wrapper requires trailing --session $HERDR_LAB_SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]}"
SHIM
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export FM_HOME FM_STATE_OVERRIDE="$STATE_DIR" FM_ROOT_OVERRIDE="$ROOT"
export HERDR_SESSION="$HERDR_LAB_SESSION"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"

lab() {
  env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

cleanup() {
  local status=$?
  trap - EXIT
  if [ -e "$STATE_DIR/.afk" ] || [ -e "$STATE_DIR/.afk-daemon-terminal" ] \
    || [ -e "$STATE_DIR/.supervise-daemon.lock" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      "$AFK_LAUNCH" stop >/dev/null 2>&1 || status=1
  fi
  if ! PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"; then
    status=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

WORKSPACE_JSON=$(lab workspace create --cwd "$ROOT" --label fm-afk-claude-guard --no-focus) \
  || fail "could not create the isolated Claude workspace"
PANE=$(printf '%s' "$WORKSPACE_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a root pane"
TARGET="$HERDR_LAB_SESSION:$PANE"
CLAUDE_BIN=$(command -v claude)
CLAUDE_VERSION=$(PATH="$ORIGINAL_PATH" "$CLAUDE_BIN" --version 2>/dev/null | head -1 || printf 'unknown')
HERDR_VERSION=$(lab status --json 2>/dev/null | jq -r '.client.version // "unknown"')

PROMPT_FILE="$TMP_ROOT/claude-prompt.txt"
CLAUDE_LAUNCHER="$TMP_ROOT/launch-claude.sh"
AWAY_ACK_TOKEN="FM_AFK_CLAUDE_GUARD_ACK_$$"
CLAUDE_TEST_SYSTEM_PROMPT="This is a live away-mode guard test. For an injected away-mode supervisor message, do not execute tools or investigate it; reply exactly $AWAY_ACK_TOKEN and nothing else. The explicit foreground-turn test instruction is an exception: when the user message asks you to use Bash for the exact sleep command and then reply with its token, execute that Bash command and wait before replying. When the test sends the literal /afk command, invoke the afk skill and perform that lifecycle action, then return to the idle composer without taking any other action."
printf '%s\n' 'Reply with the single word ready and stop.' > "$PROMPT_FILE"
# shellcheck disable=SC2016 # The generated launcher expands $(cat ...) when it runs.
printf -v CLAUDE_LAUNCHER_CONTENT \
  '#!/usr/bin/env bash\nset -euo pipefail\ncd %q\nexport PATH=%q\nexport FM_HOME=%q\nexport FM_STATE_OVERRIDE=%q\nexport FM_ROOT_OVERRIDE=%q\nexport HERDR_SESSION=%q\nexport FM_ESCALATE_BATCH_SECS=0\nexport FM_HOUSEKEEPING_TICK=1\nexport FM_POLL=1\nexport FM_SIGNAL_GRACE=1\nexport FM_HEARTBEAT=999999\nexport FM_CHECK_INTERVAL=999999\nexport FM_STALE_ESCALATE_SECS=999999\nexport FM_INJECT_CONFIRM_SLEEP=0.5\nexport FM_INJECT_CONFIRM_RETRIES=4\nexport CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false\nexec %q --dangerously-skip-permissions --append-system-prompt %q "$(cat %q)"\n' \
  "$ROOT" "$FAKEBIN:$ORIGINAL_PATH" "$FM_HOME" "$STATE_DIR" "$ROOT" \
  "$HERDR_LAB_SESSION" "$CLAUDE_BIN" "$CLAUDE_TEST_SYSTEM_PROMPT" "$PROMPT_FILE"
printf '%s' "$CLAUDE_LAUNCHER_CONTENT" > "$CLAUDE_LAUNCHER"
chmod +x "$CLAUDE_LAUNCHER"
lab pane run "$PANE" "$CLAUDE_LAUNCHER" >/dev/null \
  || fail "could not launch Claude Code ($CLAUDE_VERSION) in the isolated Herdr pane"

agent_status() {
  lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'
}

composer_state() {
  fm_backend_composer_state herdr "$TARGET" 2>/dev/null
}

rendered_claude_busy() {
  local capture
  capture=$(fm_backend_capture herdr "$TARGET" 40 2>/dev/null) || return 1
  printf '%s' "$capture" | grep -v '^[[:space:]]*$' | tail -12 \
    | fm_busy_lines_match claude
}

claude_pane_is_busy() {
  FM_DAEMON_PRIMARY_HARNESS=claude pane_is_busy "$TARGET" herdr
}

send_line() {
  lab pane send-text "$PANE" "$1" >/dev/null \
    && sleep 0.4 \
    && lab pane send-keys "$PANE" enter >/dev/null
}

wait_for_initial_idle() {
  local status composer stable=0 trust_accepted=0 screen
  for _ in $(seq 1 60); do
    status=$(agent_status)
    composer=$(composer_state)
    if [ "$trust_accepted" -eq 0 ]; then
      screen=$(screen_text)
      if printf '%s\n' "$screen" | grep -Fq 'Yes, I trust this folder'; then
        lab pane send-keys "$PANE" down >/dev/null \
          && lab pane send-keys "$PANE" enter >/dev/null \
          || return 1
        trust_accepted=1
        stable=0
        sleep 1
        continue
      fi
    fi
    case "$status" in
      idle|done|blocked)
        if [ "$composer" = empty ]; then
          stable=$((stable + 1))
          [ "$stable" -ge 3 ] && return 0
        else
          stable=0
        fi
        ;;
      *) stable=0 ;;
    esac
    sleep 1
  done
  return 1
}

wait_for_afk_daemon() {
  local pid record
  for _ in $(seq 1 60); do
    record=$(cat "$STATE_DIR/.afk-daemon-terminal" 2>/dev/null || true)
    pid=$(cat "$STATE_DIR/.supervise-daemon.pid" 2>/dev/null || true)
    if [ -f "$STATE_DIR/.afk" ] && [ "$record" = $'none\t-\tnative' ] \
      && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_idle_native_working() {
  local status composer busy
  for _ in $(seq 1 60); do
    status=$(agent_status)
    composer=$(composer_state)
    busy=1
    claude_pane_is_busy || busy=0
    if [ "$status" = working ] && [ "$composer" = empty ] && [ "$busy" -eq 0 ]; then
      return 0
    fi
    sleep 1
  done
  echo "away-idle diagnostics: status=$status composer=$composer rendered_busy=$busy" >&2
  echo "Claude pane:" >&2
  screen_text | tail -n 80 >&2
  return 1
}

screen_text() {
  lab pane read "$PANE" --source recent --lines 500 2>/dev/null || true
}

token_count() {
  local token=$1 screen
  screen=$(screen_text)
  printf '%s\n' "$screen" | grep -F -c "$token" || true
}

wait_for_single_delivery() {
  local token=$1 ack=$2 count ack_count composer screen
  for _ in $(seq 1 60); do
    screen=$(screen_text)
    count=$(printf '%s\n' "$screen" | grep -F -c "$token" || true)
    ack_count=$(printf '%s\n' "$screen" | grep -F -c "$ack" || true)
    composer=$(composer_state)
    if [ "$count" -eq 1 ] && [ "$ack_count" -eq 1 ] \
      && [ "$composer" = empty ] && [ ! -s "$STATE_DIR/.subsuper-escalations" ]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_rendered_busy() {
  local token=$1 screen status composer
  for _ in $(seq 1 30); do
    screen=$(screen_text)
    status=$(agent_status)
    composer=$(composer_state)
    if [ "$status" = working ] && [ "$composer" = empty ] \
      && printf '%s\n' "$screen" | grep -Fq "$token" \
      && rendered_claude_busy; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_human_pending() {
  local text=$1 screen
  for _ in $(seq 1 30); do
    screen=$(screen_text)
    if printf '%s\n' "$screen" | grep -Fq "$text" \
      && [ "$(composer_state)" = pending ]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

wait_for_foreground_done_with_pending() {
  local text=$1 human=$2 screen status composer busy
  for _ in $(seq 1 60); do
    screen=$(screen_text)
    status=$(agent_status)
    composer=$(composer_state)
    busy=1
    claude_pane_is_busy || busy=0
    if [ "$composer" = pending ] \
      && [ "$busy" -eq 0 ] \
      && [ "$(token_count "$text")" -ge 2 ] \
      && printf '%s\n' "$screen" | grep -Fq "$human"; then
      return 0
    fi
    sleep 1
  done
  status=$(agent_status)
  composer=$(composer_state)
  busy=1
  claude_pane_is_busy || busy=0
  echo "foreground-done diagnostics: status=$status composer=$composer rendered_busy=$busy" >&2
  echo "Claude pane:" >&2
  printf '%s\n' "$screen" | tail -n 80 >&2
  return 1
}

wait_for_log_subcause() {
  local subcause=$1
  for _ in $(seq 1 30); do
    if grep -Fq "subcause=$subcause" "$STATE_DIR/.supervise-daemon.log" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_log_native_state_working() {
  for _ in $(seq 1 30); do
    if grep -Fq 'native-state=working' "$STATE_DIR/.supervise-daemon.log" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! wait_for_initial_idle; then
  echo "initial Claude agent status: $(agent_status)" >&2
  echo "initial Claude pane capture:" >&2
  screen_text | tail -n 80 >&2
  fail "Claude Code ($CLAUDE_VERSION) on Herdr $HERDR_VERSION never became idle"
fi
send_line '/afk' \
  || fail "could not submit /afk through the real Claude pane"
if ! wait_for_afk_daemon; then
  echo "away-daemon diagnostics: status=$(agent_status) composer=$(composer_state)" >&2
  echo "Claude pane:" >&2
  screen_text | tail -n 80 >&2
  fail "the real Claude /afk path did not leave a live native daemon record"
fi
wait_for_idle_native_working \
  || fail "Herdr did not report working with an idle Claude composer after the foreground /afk turn"

ESCALATION_ONE="FM_AFK_CLAUDE_GUARD_ONE_$$"
printf 'done: %s https://example.test/afk-one\n' "$ESCALATION_ONE" > "$STATE_DIR/crew-one.status"
wait_for_single_delivery "$ESCALATION_ONE" "$AWAY_ACK_TOKEN" \
  || fail "native Herdr working plus rendered-idle Claude did not submit the first escalation exactly once"
sleep 3
if [ "$(token_count "$ESCALATION_ONE")" -ne 1 ] || [ "$(token_count "$AWAY_ACK_TOKEN")" -ne 1 ]; then
  echo "first-delivery diagnostics: token-count=$(token_count "$ESCALATION_ONE") ack-count=$(token_count "$AWAY_ACK_TOKEN") agent_status=$(agent_status) composer=$(composer_state)" >&2
  echo "daemon log:" >&2
  sed -n '1,$p' "$STATE_DIR/.supervise-daemon.log" >&2 2>/dev/null || true
  echo "Claude pane:" >&2
  screen_text | tail -n 80 >&2
  fail "the first escalation appeared more than once after the delivery settled"
fi
[ ! -s "$STATE_DIR/.subsuper-escalations" ] \
  || fail "the first escalation buffer did not clear after confirmed submission"
pass "real Herdr $HERDR_VERSION + Claude $CLAUDE_VERSION: native working with rendered-idle empty composer submits once"

FOREGROUND_TOKEN="FM_AFK_CLAUDE_GUARD_FOREGROUND_$$"
send_line "Use Bash to run python3 -c 'import time; time.sleep(12)' and then reply exactly $FOREGROUND_TOKEN and nothing else." \
  || fail "could not start a genuine foreground Claude turn"
wait_for_rendered_busy "$FOREGROUND_TOKEN" \
  || fail "the genuine Claude foreground turn never exposed its rendered active-turn signature"

ESCALATION_TWO="FM_AFK_CLAUDE_GUARD_TWO_$$"
printf 'done: %s https://example.test/afk-two\n' "$ESCALATION_TWO" > "$STATE_DIR/crew-two.status"
HUMAN_TEXT="bright-human-draft-$$"
lab pane send-text "$PANE" "$HUMAN_TEXT" >/dev/null \
  || fail "could not leave bright human text in the Claude composer"
wait_for_human_pending "$HUMAN_TEXT" \
  || fail "bright human text did not remain pending in the Claude composer"
wait_for_log_subcause rendered-busy \
  || fail "the active foreground deferral did not log subcause=rendered-busy"
wait_for_log_native_state_working \
  || fail "the rendered-busy deferral did not record native-state=working"
wait_for_foreground_done_with_pending "$FOREGROUND_TOKEN" "$HUMAN_TEXT" \
  || fail "after the foreground turn, Claude did not settle with pending human text and a rendered-idle pane"

[ "$(token_count "$ESCALATION_TWO")" -eq 0 ] \
  || fail "the second escalation was injected into the bright human composer"
if [ ! -s "$STATE_DIR/.subsuper-escalations" ]; then
  echo "second escalation buffer diagnostics:" >&2
  echo "agent_status=$(agent_status) composer=$(composer_state) rendered_busy=$(claude_pane_is_busy; echo $?)" >&2
  echo "daemon log:" >&2
  sed -n '1,$p' "$STATE_DIR/.supervise-daemon.log" >&2 2>/dev/null || true
  echo "Claude pane:" >&2
  screen_text | tail -n 80 >&2
  fail "the second escalation buffer was lost while the composer was pending"
fi
wait_for_log_subcause composer=pending \
  || fail "the pending-composer deferral did not log subcause=composer=pending"
screen=$(screen_text)
printf '%s\n' "$screen" | grep -Fq "$HUMAN_TEXT" \
  || fail "bright human text was modified or disappeared while the daemon deferred"
pass "real Herdr $HERDR_VERSION + Claude $CLAUDE_VERSION: rendered-busy and pending-composer deferrals preserve human text"

printf 'evidence: session=%s native=working rendered=idle composer=empty delivered_once=1 rendered-busy=1 native-state=working=1 composer=pending=1\n' \
  "$HERDR_LAB_SESSION"
