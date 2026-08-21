#!/usr/bin/env bash
# Real installed-Pi/Herdr regression for the Pi-to-AFK watcher ownership handoff.
# All Herdr lifecycle and task calls are isolated through fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_PI_AFK_HANDOFF_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_AFK_HANDOFF_LIVE_E2E=1 to run the real Pi AFK handoff regression"
  exit 0
fi

for tool in herdr jq pi; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=${HERDR_LAB_SESSION:-$("$LAB_HELPER" name fm-pi-afk-handoff-live-e2e)}
TMP_ROOT=$(fm_test_tmproot fm-pi-afk-handoff-live-e2e)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
PI_DIR="$TMP_ROOT/pi-agent"
FAKEBIN="$TMP_ROOT/fakebin"
CAPTURE="$TMP_ROOT/pi-prompts.jsonl"
ORIGINAL_PATH=$PATH
PRIMARY_PANE=
PRIMARY_TARGET=
DAEMON_STARTED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$DAEMON_STARTED" -eq 1 ]; then
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
      "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 || true
  fi
  "$LAB_HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT" "$PI_DIR" "$FAKEBIN"
printf '# Synthetic isolated Firstmate primary\n' > "$PROJECT/AGENTS.md"

CAPTURE_EXT="$TMP_ROOT/capture-extension.ts"
cat > "$CAPTURE_EXT" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";
export default function (pi: ExtensionAPI) {
  pi.registerProvider("fm-local", {
    name: "Firstmate local regression",
    baseUrl: "http://127.0.0.1:9/v1",
    apiKey: "local-regression-only",
    api: "openai-completions",
    models: [{
      id: "fm-local",
      name: "Firstmate local regression",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 8192,
      maxTokens: 256,
    }],
  });
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync(process.env.FM_PI_CAPTURE_PATH!, `${JSON.stringify({ prompt: event.prompt })}\n`);
    ctx.abort();
  });
}
TS

# Production backend calls inherit this shim; it accepts only this lab session
# and routes every operation through the helper so no ambient/default call can
# escape the test.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

cat > "$TMP_ROOT/daemon-entry" <<EOF
#!/usr/bin/env bash
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export HERDR_SESSION='$SESSION'
export FM_HOME='$HOME_DIR'
export FM_STATE_OVERRIDE='$STATE'
export FM_ROOT_OVERRIDE='$ROOT'
export FM_ESCALATE_BATCH_SECS=0
export FM_HOUSEKEEPING_TICK=1
export FM_POLL=1
export FM_SIGNAL_GRACE=0
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
export FM_STALE_ESCALATE_SECS=999999
exec '$ROOT/bin/fm-afk-start.sh'
EOF
chmod +x "$TMP_ROOT/daemon-entry"

PRIMARY_OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label pi-afk-handoff --no-focus)
PRIMARY_PANE=$(printf '%s' "$PRIMARY_OUT" | jq -r '.result.root_pane.pane_id')
PRIMARY_TARGET="$SESSION:$PRIMARY_PANE"
PI_CMD=$(printf 'printf "%%s\\n" "$$" > %q; exec env PI_CODING_AGENT_DIR=%q FM_HOME=%q FM_STATE_OVERRIDE=%q FM_ROOT_OVERRIDE=%q FM_PI_CAPTURE_PATH=%q FM_PI_AFK_HANDOFF_POLL_MS=20 FM_POLL=1 FM_SIGNAL_GRACE=0 pi --approve --model fm-local/fm-local --no-session --no-context-files --no-extensions -e %q -e %q' \
  "$STATE/.lock" "$PI_DIR" "$HOME_DIR" "$STATE" "$ROOT" "$CAPTURE" "$CAPTURE_EXT" "$ROOT/.pi/extensions/fm-primary-pi-watch.ts")
"$LAB_HELPER" run "$SESSION" pane run "$PRIMARY_PANE" "$PI_CMD" >/dev/null

wait_for_idle() {
  local stable=0 status _
  for _ in $(seq 1 240); do
    status=$("$LAB_HELPER" run "$SESSION" agent get "$PRIMARY_PANE" 2>/dev/null \
      | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done|blocked) stable=$((stable + 1)); [ "$stable" -ge 3 ] && return 0 ;;
      *) stable=0 ;;
    esac
    sleep 0.25
  done
  return 1
}

wait_for_file() {  # <path>
  local path=$1 _
  for _ in $(seq 1 240); do [ -s "$path" ] && return 0; sleep 0.05; done
  return 1
}

watcher_pid() {
  local pid
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

wait_for_watcher_change() {  # <old-pid>
  local old=$1 current _
  for _ in $(seq 1 240); do
    current=$(watcher_pid 2>/dev/null || true)
    if [ -n "$current" ] && [ "$current" != "$old" ]; then printf '%s\n' "$current"; return 0; fi
    sleep 0.05
  done
  return 1
}

wait_for_extension_watcher() {  # <old-pid> <pi-pid>
  local old=$1 pi_pid=$2 current parent grand stable=0 prior='' _
  for _ in $(seq 1 240); do
    current=$(watcher_pid 2>/dev/null || true)
    parent=$(ps -p "$current" -o ppid= 2>/dev/null | tr -d '[:space:]')
    grand=$(ps -p "$parent" -o ppid= 2>/dev/null | tr -d '[:space:]')
    if [ -n "$current" ] && [ "$current" != "$old" ] && [ "$grand" = "$pi_pid" ]; then
      if [ "$current" = "$prior" ]; then stable=$((stable + 1)); else stable=1; prior=$current; fi
      [ "$stable" -ge 3 ] && { printf '%s\n' "$current"; return 0; }
    else
      stable=0
      prior=
    fi
    sleep 0.05
  done
  return 1
}

wait_for_pid_dead() {  # <pid>
  local pid=$1 _
  for _ in $(seq 1 160); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

process_identity() {  # <pid>
  ps -p "$1" -o ppid=,lstart=,args= 2>/dev/null | sed 's/^[[:space:]]*//'
}

queued_signal_count() {
  [ -s "$STATE/.wake-queue" ] || { echo 0; return; }
  awk -F '\t' '$3 == "signal" { count++ } END { print count + 0 }' "$STATE/.wake-queue"
}

queue_cursor() {
  local cursor
  cursor=$(cat "$STATE/.subsuper-seen-wake-seq" 2>/dev/null || true)
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  printf '%s\n' "$cursor"
}

wait_for_capture_kind() {  # <kind> <count>
  local kind=$1 count=$2 seen _
  for _ in $(seq 1 240); do
    if [ -s "$CAPTURE" ]; then
      seen=$(jq -s --arg needle "FIRSTMATE_OP: v1 $kind:" '[.[] | select(.prompt | contains($needle))] | length' "$CAPTURE" 2>/dev/null) || seen=0
    else
      seen=0
    fi
    [ "$seen" -ge "$count" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_empty_composer() {
  local composer _
  for _ in $(seq 1 160); do
    composer=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" \
      bash -c '. "$1"; fm_backend_composer_state herdr "$2"' _ "$ROOT/bin/fm-backend.sh" "$PRIMARY_TARGET" 2>/dev/null || true)
    [ "$composer" = empty ] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_idle || fail "real Pi primary did not become stably idle"
wait_for_file "$STATE/.pi-watch-extension-loaded" || fail "real Pi did not load the production watcher extension"
"$LAB_HELPER" run "$SESSION" pane send-text "$PRIMARY_PANE" '/fm-watch-arm-pi' >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PRIMARY_PANE" enter >/dev/null
EXT_WATCHER=$(wait_for_watcher_change "") || fail "Pi extension did not acquire the initial watcher cycle"
wait_for_idle || fail "real Pi did not settle after the watcher command"
wait_for_empty_composer || fail "real Pi composer was not empty before AFK entry"
PI_PID=$(cat "$STATE/.lock")
EXT_ARM=$(ps -eo pid=,ppid=,args= | awk -v parent="$PI_PID" '$2 == parent && /fm-watch-arm\.sh/ { print $1; exit }')
[ -n "$EXT_ARM" ] || fail "could not identify the extension-owned arm child"
EXT_ARM_IDENTITY=$(process_identity "$EXT_ARM")
EXT_WATCHER_IDENTITY=$(cat "$STATE/.watch.lock/pid-identity")
pass "real Pi extension acquired an ordinary home-scoped watcher cycle"

PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" FM_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/fm-afk-launch.sh" start >/dev/null
DAEMON_STARTED=1
wait_for_file "$STATE/.supervise-daemon.pid" || fail "away daemon did not acquire its lifecycle"
AWAY_WATCHER=$(wait_for_watcher_change "$EXT_WATCHER") || fail "away daemon did not acquire the watcher after Pi yielded"
wait_for_pid_dead "$EXT_ARM" || [ "$(process_identity "$EXT_ARM")" != "$EXT_ARM_IDENTITY" ] \
  || fail "the exact Pi extension arm identity survived the AFK ownership handoff"
CURRENT_WATCHER_IDENTITY=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$EXT_WATCHER" 2>/dev/null || true)
[ "$CURRENT_WATCHER_IDENTITY" != "$EXT_WATCHER_IDENTITY" ] \
  || fail "the exact Pi extension watcher identity survived the AFK ownership handoff"
grep -F "arm_pid=$EXT_ARM" "$STATE/.watch-cycle-exits.log" | grep -F $'reason=arm-interrupted' >/dev/null \
  || fail "the exact arm did not record its signal-driven retirement"
pass "real Pi yielded its exact cycle and the away daemon acquired monitoring"

if [ -s "$CAPTURE" ]; then CAPTURE_BEFORE=$(wc -l < "$CAPTURE"); else CAPTURE_BEFORE=0; fi
printf 'working: routine heartbeat-equivalent progress\n' > "$STATE/pi-afk-live.status"
for _ in $(seq 1 240); do
  [ "$(queued_signal_count)" -ge 1 ] && break
  sleep 0.05
done
[ "$(queued_signal_count)" -ge 1 ] \
  || fail "away watcher did not durably queue the routine signal"
for _ in $(seq 1 240); do
  [ "$(queue_cursor)" -ge "$(awk -F '\t' '$3 == "signal" { seq=$2 } END { print seq + 0 }' "$STATE/.wake-queue")" ] && break
  sleep 0.05
done
ROUTINE_SEQ=$(awk -F '\t' '$3 == "signal" { seq=$2 } END { print seq + 0 }' "$STATE/.wake-queue")
[ "$(queue_cursor)" -ge "$ROUTINE_SEQ" ] \
  || fail "away daemon did not classify the routine queued wake"
sleep 1.1
if [ -s "$CAPTURE" ]; then CAPTURE_AFTER=$(wc -l < "$CAPTURE"); else CAPTURE_AFTER=0; fi
[ "$CAPTURE_AFTER" -eq "$CAPTURE_BEFORE" ] || fail "routine away progress created a Pi agent turn"
[ ! -s "$STATE/.subsuper-escalations" ] || fail "routine away progress was escalated"
pass "real away daemon absorbed routine progress without Pi model injection"

printf 'done: actionable AFK handoff result\n' >> "$STATE/pi-afk-live.status"
for _ in $(seq 1 240); do
  [ "$(queued_signal_count)" -ge 2 ] && break
  sleep 0.05
done
[ "$(queued_signal_count)" -ge 2 ] \
  || fail "away watcher did not durably queue the actionable signal"
wait_for_empty_composer || fail "real Pi composer was not empty for actionable away delivery"
wait_for_capture_kind away-supervisor 1 || {
  pane=$("$LAB_HELPER" run "$SESSION" pane read "$PRIMARY_PANE" --source recent --lines 120 2>/dev/null || true)
  fail "actionable away result did not reach Pi through the marked supervisor path; buffer=$(cat "$STATE/.subsuper-escalations" 2>/dev/null || true); daemon=$(tail -8 "$STATE/.supervise-daemon.log" 2>/dev/null || true); pane=$pane"
}
sleep 2
AWAY_COUNT=$(jq -s '[.[] | select(.prompt | contains("FIRSTMATE_OP: v1 away-supervisor:"))] | length' "$CAPTURE")
[ "$AWAY_COUNT" -eq 1 ] || fail "actionable away result was delivered $AWAY_COUNT times"
SIGNAL_COUNT=$(queued_signal_count)
# fm-watch intentionally retains both pre-grace and post-grace observations in
# the raw at-least-once queue. The daemon cursor must classify all four rows,
# while status-seen and drain dedupe ensure each logical update delivers once.
[ "$SIGNAL_COUNT" -eq 4 ] \
  || fail "the raw at-least-once queue did not retain both observations of each logical signal (count=$SIGNAL_COUNT)"
FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/handoff-drain.out" \
  || fail "handoff queue drain failed"
[ "$(grep -c $'\tsignal\t' "$TMP_ROOT/handoff-drain.out")" -eq 1 ] \
  || fail "the sole consumer did not apply its one-record-per-kind/key compaction"
[ ! -s "$STATE/.wake-queue" ] || fail "the sole consumer left handoff records queued"
pass "real actionable delivery stayed marked while the lossless queue drained to one logical signal"

FM_ROOT_OVERRIDE="$PROJECT" PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" "$ROOT/bin/fm-afk-return.sh" begin >/dev/null \
  || fail "away return did not complete"
DAEMON_STARTED=0
[ ! -e "$STATE/.afk" ] || fail "away return left the AFK marker active"
RESUMED_WATCHER=$(wait_for_extension_watcher "$AWAY_WATCHER" "$PI_PID") \
  || fail "loaded Pi extension did not resume monitoring automatically"

printf 'done: post-return supervision wake\n' > "$STATE/pi-afk-resumed.status"
for _ in $(seq 1 240); do [ "$(queued_signal_count)" -ge 1 ] && break; sleep 0.05; done
[ "$(queued_signal_count)" -ge 1 ] || fail "resumed Pi watcher did not durably queue the ordinary wake"
for _ in $(seq 1 240); do
  grep -F "arm_pid=$(ps -p "$RESUMED_WATCHER" -o ppid= | tr -d '[:space:]')" "$STATE/.watch-cycle-exits.log" 2>/dev/null \
    | grep -F $'reason=actionable-signal' | grep -E $'successor=started:[0-9]+' >/dev/null && break
  sleep 0.05
done
grep -F "arm_pid=$(ps -p "$RESUMED_WATCHER" -o ppid= | tr -d '[:space:]')" "$STATE/.watch-cycle-exits.log" 2>/dev/null \
  | grep -F $'reason=actionable-signal' | grep -E $'successor=started:[0-9]+' >/dev/null \
  || fail "resumed Pi cycle did not record its actionable close and automatic successor"
POST_RETURN_WATCHER=$(wait_for_extension_watcher "$RESUMED_WATCHER" "$PI_PID") \
  || fail "resumed Pi cycle did not establish its automatic successor"
pass "real return stopped away ownership and resumed extension monitoring without manual re-arm"

# One more complete transition proves idempotent convergence and no duplicate
# cycle on repeated entry/return.
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" FM_AFK_LAUNCH_ENTRY="$TMP_ROOT/daemon-entry" \
  "$ROOT/bin/fm-afk-launch.sh" start >/dev/null
DAEMON_STARTED=1
SECOND_AWAY=$(wait_for_watcher_change "$POST_RETURN_WATCHER") || fail "repeated AFK entry did not converge to daemon ownership"
FM_ROOT_OVERRIDE="$PROJECT" PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$PRIMARY_TARGET" "$ROOT/bin/fm-afk-return.sh" begin >/dev/null \
  || fail "repeated away return did not complete"
DAEMON_STARTED=0
SECOND_RESUMED=$(wait_for_extension_watcher "$SECOND_AWAY" "$PI_PID") \
  || fail "repeated return did not restore Pi ownership"
sleep 1
[ "$(watcher_pid)" = "$SECOND_RESUMED" ] || fail "repeated return launched a second concurrent watcher cycle"
pass "real repeated Pi AFK entry and return converged to one extension-owned cycle"
