#!/usr/bin/env bash
# Credentialed PiG primary verification in a named Herdr lab and throwaway FM_HOME.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PIG_PRIMARY_LIVE_E2E pig herdr jq tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CODE_ROOT=${FM_PIG_PRIMARY_LIVE_CODE_ROOT:-$ROOT}
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${FM_LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
MODEL=${FM_PIG_PRIMARY_LIVE_MODEL:-openai-codex/gpt-6-luna}
THINKING=${FM_PIG_PRIMARY_LIVE_THINKING:-medium}
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pig-primary-live.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$TASK_TMP/herdr-state"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-pig-primary-live-verify-v1)
FM_HOME=$("$LAB_HOME_HELPER" create "$TASK_TMP/fmhome")
RECOVERY_HOME=
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME")
PANE=
WORKSPACE=
TAB=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  local status=$?
  trap - EXIT
  "$HERDR_LAB_HELPER" viewer stop "$HERDR_LAB_SESSION" >/dev/null 2>&1 || status=1
  TMUX_TMPDIR="$LAB_TMUX_DIR" tmux kill-server >/dev/null 2>&1 || true
  if [ -n "$RECOVERY_HOME" ]; then
    "$LAB_HOME_HELPER" teardown "$RECOVERY_HOME" || status=1
  fi
  "$LAB_HOME_HELPER" teardown "$FM_HOME" || status=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TASK_TMP" || status=1
  exit "$status"
}
trap - EXIT

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the named Herdr lab"
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

created=$(lab workspace create --cwd "$ROOT" --label pig-primary-live --no-focus) \
  || fail "could not create the isolated PiG workspace"
PANE=$(printf '%s' "$created" | jq -er '.result.root_pane.pane_id') \
  || fail "could not read the PiG pane id"
WORKSPACE=$(printf '%s' "$created" | jq -er '.result.workspace.workspace_id') \
  || fail "could not read the PiG workspace id"
TAB=$(printf '%s' "$created" | jq -er '.result.root_pane.tab_id') \
  || fail "could not read the PiG tab id"

[ "$MODEL" = openai-codex/gpt-6-luna ] || fail "live PiG verification requires openai-codex/gpt-6-luna"
[ "$THINKING" = medium ] || fail "live PiG verification requires medium effort"
printf 'PiG live run model=%s effort=%s\n' "$MODEL" "$THINKING"
PIG_CMD=$(printf 'env FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_PIG_HARNESS=pig FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_WATCH_REARM_RETRY_BASE_MS=60000 FM_WATCH_REARM_RETRY_MAX_MS=60000 pig --approve --no-context-files --model %q --thinking %q -e .pi/extensions/fm-branch-supervision.ts' \
  "$FM_HOME" "$CODE_ROOT" "$MODEL" "$THINKING")
lab pane run "$PANE" "$PIG_CMD" >/dev/null || fail "could not start PiG in the isolated pane"
"$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not attach the isolated PiG TUI"

screen() { lab pane read "$PANE" --source recent --lines 400 2>/dev/null || true; }
agent_state() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' || true; }
submit() {
  lab pane send-text "$PANE" "$1" >/dev/null || return 1
  sleep 0.6
  lab pane send-keys "$PANE" Enter >/dev/null || return 1
}
wait_text() {
  local expected=$1 attempts=${2:-180} i=0 current flattened expected_flat
  expected_flat=$(printf '%s' "$expected" | tr -d '[:space:]')
  while [ "$i" -lt "$attempts" ]; do
    current=$(screen)
    flattened=$(printf '%s' "$current" | tr -d '[:space:]')
    if printf '%s\n' "$current" | grep -Fq "$expected" || printf '%s' "$flattened" | grep -Fq "$expected_flat"; then
      printf '%s' "$current"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  screen >&2
  return 1
}
wait_idle() {
  local attempts=${1:-180} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ "$(agent_state)" = idle ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_text '(openai-codex)' 120 >/dev/null || fail "PiG did not reach its TUI"
[ -f "$FM_HOME/state/.pi-watch-extension-loaded" ] \
  || fail "the Go extension did not load its watcher bridge"
wait_watch() {
  local attempts=${1:-60} i=0 pid
  while [ "$i" -lt "$attempts" ]; do
    pid=$(cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}
submit 'Read the injected Firstmate session-start heading and reply LIVE_DIGEST:<the exact FM_HOME path>. If absent, reply PIG_NO_DIGEST. Do not use tools.' \
  || fail "could not submit the startup prompt"
startup=$(wait_text "LIVE_DIGEST:$FM_HOME" 180) \
  || fail "PiG did not return the isolated-home token from its session-start digest"
wait_watch || fail "PiG did not automatically arm a live watcher at the first prompt"
submit '/ahoy' || fail "could not submit the direct /ahoy command"
ahoy=$(wait_text 'Firstmate command invoked: /ahoy' 120) \
  || fail "the direct PiG /ahoy callback did not reach the conversation"
wait_idle || fail "the direct /ahoy turn did not settle"
[ -f "$FM_HOME/state/.session-start-complete" ] \
  || fail "PiG did not run the session-start owner with FM_HOME separate from FM_ROOT_OVERRIDE"
startup_flat=$(printf '%s' "$startup" | tr -d '[:space:]')
expected_digest=$(printf 'LIVE_DIGEST:%s' "$FM_HOME" | tr -d '[:space:]')
printf '%s' "$startup_flat" | grep -Fq "$expected_digest" \
  || fail "PiG did not return the exact isolated-home token from the injected digest"
printf '%s\n' "$ahoy" | grep -Fq 'send_failed:' \
  && fail "the direct PiG /ahoy callback failed to deliver its model turn"
pass "PiG session start delivers the Firstmate digest from a throwaway FM_HOME"
if [ "${FM_PIG_PRIMARY_SESSION_START_ONLY:-0}" = 1 ]; then
  exit 0
fi
pass "PiG /ahoy runs directly in the TUI"

submit '/bearings' || fail "could not submit the direct /bearings command"
bearings=$(wait_text 'Recently Landed' 180) \
  || fail "the direct PiG /bearings command did not complete its data read"
wait_idle || fail "the direct /bearings turn did not settle"
printf '%s\n' "$bearings" | grep -Fq 'Charted Next' \
  || fail "the direct PiG /bearings output was incomplete"
pass "PiG /bearings reads and renders the live Firstmate fleet"

submit 'Use the bash tool to run exactly cd projects/example and then report the result. Do not run any other command.' \
  || fail "could not submit the persistent-cd guard probe"
cd_guard=$(wait_text 'persistent top-level directory change' 180) \
  || fail "PiG did not block a persistent primary-home directory change"
printf '%s\n' "$cd_guard" | grep -Fq 'Reach the target without moving the shell' \
  || fail "the cd-guard denial did not explain the safe alternative"
pass "PiG pre-tool guard blocks a persistent primary-home directory change"

submit 'Use the bash tool to run exactly timeout 1 bin/fm-watch.sh, then report its result. Do not use any Pi watcher tool.' \
  || fail "could not submit the pre-tool guard probe"
guard=$(wait_text 'watcher-direct' 180) \
  || fail "PiG did not block a wrapped direct watcher launch"
printf '%s\n' "$guard" | grep -Fq 'must not be run directly' \
  || fail "the pre-tool denial did not explain the direct-watcher restriction"
pass "PiG pre-tool guard blocks a wrapped direct watcher launch"

# A terminal status is the concrete wake fixture; the session-start-owned
# watcher cycle must deliver it without a manual arm or duplicate cycle.
printf 'done: PiG primary live notification LIVE_WAKE_1\n' > "$FM_HOME/state/pig-primary-live.status"
wake=$(wait_text 'LIVE_WAKE_1' 180) \
  || fail "the actionable watcher notification was not delivered to the main conversation"
printf '%s\n' "$wake" | grep -Eq 'signal:|Supervisor' \
  || fail "the delivered watcher message was not an actionable notification"
wait_idle || fail "the actionable wake turn did not settle"
wait_watch || fail "PiG did not retain a live watcher after wake delivery"
if screen | grep -Fq 'TURN WOULD END BLIND'; then
  fail "the turn-end guard reported a healthy watcher cycle as missing"
fi
pass "PiG delivers an actionable wake and the turn-end guard accepts healthy supervision"

# Register only this isolated pane so the lifecycle test goes through the
# public control plane and its verified Herdr postconditions.
printf 'kind=ship\nharness=pig\nbackend=herdr\nwindow=%s:%s\nendpoint_task_id=piglive\nworktree=%s\nproject=%s\nmode=direct-PR\nyolo=off\nmodel=%s\neffort=%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
  "$HERDR_LAB_SESSION" "$PANE" "$ROOT" "$ROOT" "$MODEL" "$THINKING" \
  "$HERDR_LAB_SESSION" "$WORKSPACE" "$TAB" "$PANE" > "$FM_HOME/state/piglive.meta"

submit 'Use the bash tool to run sleep 30 and then reply PIG_SLEEP_FINISHED.' \
  || fail "could not start the interrupt probe"
for _ in $(seq 1 60); do
  [ "$(agent_state)" = working ] && break
  sleep 0.2
done
[ "$(agent_state)" = working ] || fail "PiG did not enter a running turn for the interrupt probe"
interrupt=$(env FM_HOME="$FM_HOME" HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.2 FM_CONTROL_SETTLE_WAIT=1 "$ROOT/bin/fm-control.sh" piglive interrupt 2>&1) \
  || fail "fm-control could not interrupt the PiG turn: $interrupt"
printf '%s\n' "$interrupt" | grep -Fq 'interrupt-delivered piglive' \
  || fail "fm-control did not confirm the PiG interrupt: $interrupt"
[ "$(agent_state)" != dead ] || fail "the PiG interrupt stopped the agent instead of cancelling its turn"
pass "fm-control interrupt cancels a live PiG turn and preserves its pane"

if relaunch=$(env FM_HOME="$FM_HOME" HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.2 FM_CONTROL_SETTLE_WAIT=1 "$ROOT/bin/fm-control.sh" piglive relaunch \
  --model "$MODEL" --effort "$THINKING" --note "Verify the primary-only relaunch boundary; make no project changes." 2>&1); then
  fail "fm-control unexpectedly relaunched primary-only PiG as a ship worker: $relaunch"
fi
printf '%s\n' "$relaunch" | grep -Fq "not verified to run a ship task" \
  || fail "fm-control relaunch refusal did not explain the primary-only PiG boundary: $relaunch"
[ "$(agent_state)" != dead ] || fail "the refused PiG relaunch stopped the live lab agent"
pass "fm-control refuses PiG relaunch as primary-only and preserves the live lab agent"

exit_result=$(env FM_HOME="$FM_HOME" HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=20 "$ROOT/bin/fm-control.sh" piglive exit 2>&1) \
  || fail "fm-control could not exit PiG: $exit_result"
printf '%s\n' "$exit_result" | grep -Fq 'stopped piglive' \
  || fail "fm-control did not confirm the PiG exit: $exit_result"
pass "fm-control exit stops PiG while preserving the isolated Herdr pane"

# Use a second throwaway home for missing-watcher recovery so that this
# scenario cannot contaminate the clean-composer lifecycle assertions above.
RECOVERY_HOME=$("$LAB_HOME_HELPER" create "$TASK_TMP/recovery-home")
printf 'kind=ship\nharness=pig\nbackend=herdr\nwindow=%s:%s\nendpoint_task_id=piglive\nworktree=%s\nproject=%s\nmode=direct-PR\nyolo=off\nmodel=%s\neffort=%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
  "$HERDR_LAB_SESSION" "$PANE" "$ROOT" "$ROOT" "$MODEL" "$THINKING" \
  "$HERDR_LAB_SESSION" "$WORKSPACE" "$TAB" "$PANE" > "$RECOVERY_HOME/state/piglive.meta"
RECOVERY_PIG_CMD=$(printf 'env FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_PIG_HARNESS=pig FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_WATCH_REARM_RETRY_BASE_MS=60000 FM_WATCH_REARM_RETRY_MAX_MS=60000 pig --approve --no-context-files --model %q --thinking %q -e .pi/extensions/fm-branch-supervision.ts' \
  "$RECOVERY_HOME" "$CODE_ROOT" "$MODEL" "$THINKING")
lab pane run "$PANE" "$RECOVERY_PIG_CMD" >/dev/null \
  || fail "could not start PiG in the separate recovery home"
wait_text '(openai-codex)' 120 >/dev/null \
  || fail "fresh PiG process did not reach its TUI"
submit "Read the Firstmate session-start digest and reply RECOVERY_HOME:$RECOVERY_HOME. Do not use tools." \
  || fail "could not submit the recovery-home startup prompt"
wait_text "RECOVERY_HOME:$RECOVERY_HOME" 180 >/dev/null \
  || fail "the separate recovery home did not deliver its session-start digest"
wait_watch_in_recovery_home() {
  local attempts=60 i=0 pid
  while [ "$i" -lt "$attempts" ]; do
    pid=$(cat "$RECOVERY_HOME/state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}
if ! wait_watch_in_recovery_home; then
  printf 'recovery-home state after watcher startup timeout:\n' >&2
  ls -la "$RECOVERY_HOME/state" >&2 || true
  for record in "$RECOVERY_HOME/state/.lock" "$RECOVERY_HOME/state/.pi-watch-extension-loaded"; do
    if [ -f "$record" ]; then
      printf '%s: ' "$record" >&2
      tr '\n' ' ' < "$record" >&2
      printf '\n' >&2
    fi
  done
  screen >&2
  fail "separate recovery home did not automatically arm its watcher"
fi
stop=$(env FM_HOME="$RECOVERY_HOME" FM_ROOT_OVERRIDE="$CODE_ROOT" FM_POLL=1 \
  "$CODE_ROOT/bin/fm-watch-arm.sh" --stop 2>&1) \
  || fail "could not stop only the lab watcher for the turn-end recovery probe: $stop"
printf '%s\n' "$stop" | grep -Fq 'watcher: stopped pid=' \
  || fail "the lab watcher stop was not confirmed: $stop"
submit 'Reply exactly TURN_END_GUARD_PROBE. Do not use tools.' \
  || fail "could not submit the turn-end recovery probe"
wait_text 'TURN WOULD END BLIND' 90 >/dev/null \
  || fail "PiG turn-end guard did not inject a recovery prompt after the lab watcher stopped"
wait_idle || fail "PiG turn-end recovery prompt did not settle"
pass "PiG turn-end guard injects recovery when the lab watcher is missing"
printf 'ok - PiG primary live verification completed on %s\n' "$(pig --version | head -1)"
