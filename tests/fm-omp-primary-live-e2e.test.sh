#!/usr/bin/env bash
# Opt-in credentialed omp (Oh My Pi) primary regression in an isolated lab
# checkout. It drives a real omp through its JSON-RPC stdio mode so no terminal
# multiplexer is needed, uses the captain's existing omp login without copying
# any credential, and defaults to the captain-approved openai-codex model.
#
# It proves, against the installed omp, everything the portable suite
# (tests/fm-omp-harness.test.sh) can only pin over a fake API:
#   1. both tracked .omp/extensions load by auto-discovery alone;
#   2. the session-start digest reaches model context before the first turn
#      and the session lock names the omp process (ancestry detection);
#   3. fm_watch_arm_omp starts a real watcher, an actionable close spawns a
#      ledger-linked successor, and the wake arrives as one follow-up turn;
#   4. with retries exhausted and the watcher gone, session_stop compels the
#      turn-end guard continuation and the model repairs through the tool.
set -u

if [ "${FM_OMP_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_LIVE_E2E=1 to run the isolated omp primary regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  if [ -f "${RPC_LOG:-}" ]; then
    printf '# rpc frame types seen:\n' >&2
    jq -r '[.type, (.toolName // .name // "")] | @tsv' "$RPC_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -40 >&2
    printf '# frames mentioning the arm tool:\n' >&2
    jq -c 'select(tostring | test("watcher: started|fm_watch_arm|fm-watch-arm")) | {type, toolName, role: (.message.role // null), head: (tostring | .[0:200])}' "$RPC_LOG" 2>/dev/null | head -20 >&2
    printf '# last stderr lines:\n' >&2
    tail -5 "${RPC_ERR:-/dev/null}" >&2
    if [ "${FM_OMP_LIVE_KEEP:-0}" = 1 ]; then
      printf '# lab kept at %s\n' "$LAB" >&2
      trap - EXIT
      exec 3>&- 2>/dev/null || true
      [ -z "$OMP_PID" ] || kill -TERM "$OMP_PID" 2>/dev/null || true
    fi
  fi
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v node >/dev/null 2>&1 || fail "node not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

OMP_VERSION=$(omp --version 2>/dev/null | head -1)
MODEL=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6-astra}
LAB="$ROOT/.omp-live-e2e.$$"
PROJECT="$LAB/project"
RPC_IN="$LAB/rpc.in"
RPC_LOG="$LAB/rpc.log"
RPC_ERR="$LAB/rpc.err"
OMP_PID=

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid_file watcher_pid arm_pid
  exec 3>&- 2>/dev/null || true
  if [ -n "$OMP_PID" ]; then
    kill -TERM "$OMP_PID" 2>/dev/null || true
  fi
  pid_file="$PROJECT/state/.watch.lock/pid"
  watcher_pid=$(cat "$pid_file" 2>/dev/null || true)
  arm_pid=
  [ -n "$watcher_pid" ] && arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  sleep 0.5
  rm -rf "$LAB"
}
trap cleanup EXIT

# --- lab checkout: the tracked tree plus this working tree's pending edits ----
mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT" || fail "could not clone the repository into the lab"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$ROOT/$path" ] || continue
  mkdir -p "$PROJECT/$(dirname "$path")"
  cp "$ROOT/$path" "$PROJECT/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"
[ -f "$PROJECT/.omp/extensions/fm-primary-omp-watch.ts" ] || fail "lab checkout is missing the omp watch extension"
[ -f "$PROJECT/.omp/extensions/fm-primary-turnend-guard.ts" ] || fail "lab checkout is missing the omp turn-end extension"

# --- rpc plumbing --------------------------------------------------------------
rpc_send() {  # <json-line>
  printf '%s\n' "$1" >&3
}

wait_for_log() {  # <fixed-string> <attempts>
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    grep -Fq -- "$expected" "$RPC_LOG" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_file() {  # <path> <attempts>
  local path=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -f "$path" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# Model-issued invocations of one extension tool, counted from the
# tool-execution frames rather than from text, because a tool result is echoed
# by several frame kinds. omp exposes extension tools to some models (verified:
# the openai-codex family on 18.1.11) through its virtual-file bridge, where the
# model invokes the tool by WRITING xd://<tool-name>; a direct call and a bridge
# write are the same invocation and are counted together.
tool_call_count() {  # <tool-name>
  local n
  n=$(jq -r --arg t "$1" 'select(.type == "tool_execution_start" and (.toolName == $t or (.toolName == "write" and (.args.path // "") == ("xd://" + $t)))) | .type' "$RPC_LOG" 2>/dev/null | grep -c . 2>/dev/null) || true
  printf '%s' "${n:-0}"
}

# Every assistant text delta from the rpc event stream, joined, since <line>.
assistant_text_since() {  # <line-number>
  tail -n +"$1" "$RPC_LOG" | jq -r 'select(.type == "message_update") | .assistantMessageEvent | select(.type == "text_delta") | .delta' 2>/dev/null | tr -d '\n'
}

agent_end_count() {
  local n
  n=$(jq -r 'select(.type == "agent_end") | .type' "$RPC_LOG" 2>/dev/null | grep -c . 2>/dev/null) || true
  printf '%s' "${n:-0}"
}

wait_for_agent_ends() {  # <count> <attempts>
  local want=$1 attempts=${2:-360} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ "$(agent_end_count)" -ge "$want" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

mkfifo "$RPC_IN" || fail "could not create the rpc fifo"
: > "$RPC_LOG"
(
  cd "$PROJECT" &&
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
      FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 \
      FM_WATCH_REARM_RETRY_LIMIT=0 FM_WATCH_REARM_RETRY_BASE_MS=50 FM_WATCH_REARM_RETRY_MAX_MS=100 \
      omp --mode rpc --no-session --cwd "$PROJECT" --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
        --model "$MODEL" --thinking low < "$RPC_IN" > "$RPC_LOG" 2> "$RPC_ERR"
) &
OMP_PID=$!
exec 3> "$RPC_IN"

wait_for_log '"type":"ready"' 240 || fail "omp $OMP_VERSION did not print its rpc ready frame: $(tail -5 "$RPC_ERR")"
wait_for_file "$PROJECT/state/.omp-turnend-extension-loaded" 60 || fail "omp $OMP_VERSION did not auto-discover the turn-end guard extension"
wait_for_file "$PROJECT/state/.omp-watch-extension-loaded" 60 || fail "omp $OMP_VERSION did not auto-discover the watch extension"
pass "omp $OMP_VERSION: both tracked .omp/extensions loaded by auto-discovery with no -e and no trust dialog"

# --- 1. session-start digest and lock identity ---------------------------------
rpc_send '{"id":"p1","type":"prompt","message":"From the Firstmate session-start digest already in your context, reply with the single line that begins with SESSION START - and nothing else. Do not run any tool."}'
wait_for_agent_ends 1 360 || fail "omp did not finish the first turn: $(tail -3 "$RPC_ERR")"
first=$(assistant_text_since 1)
case "$first" in
  *"SESSION START - $PROJECT"*) ;;
  *) fail "the session-start digest did not reach model context before the first turn; reply was: $first" ;;
esac
lock_pid=$(sed -n '1p' "$PROJECT/state/.lock" 2>/dev/null || true)
omp_real_pid=$(pgrep -P "$OMP_PID" -x omp 2>/dev/null | head -1 || true)
[ -n "$omp_real_pid" ] || omp_real_pid=$OMP_PID
[ "$lock_pid" = "$omp_real_pid" ] || fail "the session lock names pid '$lock_pid', not the omp process $omp_real_pid; ancestry detection failed"
[ -f "$PROJECT/state/.session-start-complete" ] || fail "session start did not record completion"
pass "omp $OMP_VERSION: before_agent_start delivered the digest into model context and the lock names the omp process"

# --- 2. watcher arm, successor, and wake delivery ------------------------------
: > "$PROJECT/state/omp-e2e.meta"
line_before=$(wc -l < "$RPC_LOG")
rpc_send '{"id":"p2","type":"prompt","message":"Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else. Never run bin/fm-watch-arm.sh through bash."}'
wait_for_log "watcher: started omp extension arm child 1" 360 || fail "omp did not render the initial watcher tool result: $(tail -3 "$RPC_ERR")"
wait_for_agent_ends 2 360 || fail "omp did not finish the arm turn"
watcher_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null || fail "no live watcher holds the lab home lock after fm_watch_arm_omp"
pass "omp $OMP_VERSION: fm_watch_arm_omp started a live watcher through the extension"

printf 'done: omp live e2e watcher fire\n' > "$PROJECT/state/omp-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$PROJECT/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$PROJECT/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "omp extension did not start and ledger-link a successor after the actionable close"
wait_for_log "FIRSTMATE WATCHER WAKE: signal:" 240 || fail "the actionable close was not delivered to main as a watcher follow-up"
wait_for_agent_ends 3 360 || fail "omp did not finish the wake turn"
arm_calls=$(tool_call_count fm_watch_arm_omp)
[ "$arm_calls" -eq 1 ] || fail "the model re-armed from memory instead of the extension (fm_watch_arm_omp call count $arm_calls)"
pass "omp $OMP_VERSION: an actionable close spawned a ledger-linked successor and woke main exactly once"

# --- 3. the compelled turn-end guard continuation -------------------------------
# With the extension's retry bound at zero, killing the watcher leaves the home
# unsupervised at the next turn end, so session_stop must compel the guard
# continuation and the model must repair through the tool.
successor_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$successor_pid" ] || fail "no successor watcher recorded before the guard probe"
arm_pid=$(ps -p "$successor_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
lab_pid_is_safe "$successor_pid" || fail "refusing to kill a watcher outside the lab ($successor_pid)"
kill -TERM "$successor_pid" 2>/dev/null || true
if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then kill -TERM "$arm_pid" 2>/dev/null || true; fi
sleep 2
rpc_send '{"id":"p3","type":"prompt","message":"Reply with exactly GUARD_PROBE and nothing else. Do not call any tool unless a later instruction in this turn tells you supervision is off."}'
wait_for_log "TURN WOULD END BLIND" 360 || fail "session_stop did not compel the turn-end guard continuation after the watcher was killed"
i=0
while [ "$i" -lt 360 ]; do
  [ "$(tool_call_count fm_watch_arm_omp)" -ge 2 ] && break
  sleep 0.5
  i=$((i + 1))
done
[ "$(tool_call_count fm_watch_arm_omp)" -ge 2 ] \
  || fail "the model did not repair supervision through fm_watch_arm_omp after the compelled continuation"
wait_for_agent_ends 4 360 || fail "omp did not settle after the guard repair"
repaired_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$repaired_pid" ] && kill -0 "$repaired_pid" 2>/dev/null || fail "no live watcher after the guard repair"
pass "omp $OMP_VERSION: session_stop compelled the guard continuation and the model repaired through fm_watch_arm_omp"

# --- shutdown: closing stdin disposes the session and exits 0 ------------------
exec 3>&-
i=0
while [ "$i" -lt 60 ]; do
  kill -0 "$OMP_PID" 2>/dev/null || break
  sleep 0.5
  i=$((i + 1))
done
kill -0 "$OMP_PID" 2>/dev/null && fail "omp did not exit after its rpc stdin closed"
OMP_PID=
note "omp $OMP_VERSION model=$MODEL: every live omp primary assertion passed"
