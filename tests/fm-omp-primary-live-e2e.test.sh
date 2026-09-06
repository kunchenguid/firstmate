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
    grep -o '"type":"[a-z_]*"' "$RPC_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -30 >&2
    printf '# guard spy log:\n' >&2
    tail -12 "${GUARD_SPY_LOG:-/dev/null}" >&2 2>/dev/null
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
# The guard's beacon grace for this lab. The watcher beats every FM_POLL=1s, so
# a 20s grace is comfortably healthy in normal operation and lets stage 3 make
# the beacon stale by freezing the watcher for a bounded time instead of killing
# it: a killed watcher closes its arm child and the extension re-arms within
# milliseconds, which would keep the guard from ever firing.
GUARD_GRACE=20
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

# Every process the lab started names the lab path on its command line (omp
# itself, the session-start supervisor and its runner, the watcher and its arm
# child), so cleanup reaps by that path rather than by remembered pids: an omp
# rpc process that outlives its closed stdin, or a detached session-start
# worker, would otherwise survive the lab that created it.
lab_pids() {
  ps -axo pid=,command= | awk -v lab="$LAB" 'index($0, lab) { print $1 }'
}

reap_lab() {
  local pid
  for pid in $(lab_pids); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in $(lab_pids); do kill -KILL "$pid" 2>/dev/null || true; done
}

cleanup() {
  exec 3>&- 2>/dev/null || true
  if [ -n "$OMP_PID" ]; then
    kill -TERM "$OMP_PID" 2>/dev/null || true
  fi
  reap_lab
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
# A spy in front of the real turn-end guard: every invocation records the
# payload the extension sent and the exit code the real guard returned, which
# proves the compelled continuation (a payload with stop_hook_active true can
# only come from a stop omp raised for the continuation itself) independently of
# whether the rpc stream echoes additionalContext.
GUARD_SPY_LOG="$LAB/guard-spy.log"
mv "$PROJECT/bin/fm-turnend-guard.sh" "$PROJECT/bin/fm-turnend-guard.real.sh"
cat > "$PROJECT/bin/fm-turnend-guard.sh" <<SH
#!/usr/bin/env bash
payload=\$(cat)
printf '%s' "\$payload" | "\$(dirname "\$0")/fm-turnend-guard.real.sh" "\$@"
rc=\$?
printf 'rc=%s payload=%s\n' "\$rc" "\$payload" >> '$GUARD_SPY_LOG'
exit "\$rc"
SH
chmod +x "$PROJECT/bin/fm-turnend-guard.sh"
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
      FM_GUARD_GRACE="$GUARD_GRACE" \
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
rpc_send '{"id":"p2","type":"prompt","message":"Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else. Never run bin/fm-watch-arm.sh through bash."}'
wait_for_log "watcher: started omp extension arm child 1" 360 || fail "omp did not render the initial watcher tool result: $(tail -3 "$RPC_ERR")"
wait_for_agent_ends 2 360 || fail "omp did not finish the arm turn"
watcher_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
if [ -z "$watcher_pid" ] || ! kill -0 "$watcher_pid" 2>/dev/null; then
  fail "no live watcher holds the lab home lock after fm_watch_arm_omp"
fi
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
# Freeze the successor watcher (SIGSTOP) so its beacon goes stale past the lab
# grace while its arm child stays attached: the extension sees no close and
# schedules no retry, so the next turn end is genuinely unsupervised and
# session_stop must compel the guard continuation. The model's repair call then
# returns the extension's ownership no-op (it still owns the frozen arm), and
# thawing the watcher restores the same cycle.
successor_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$successor_pid" ] || fail "no successor watcher recorded before the guard probe"
lab_pid_is_safe "$successor_pid" || fail "refusing to freeze a watcher outside the lab ($successor_pid)"
kill -STOP "$successor_pid" 2>/dev/null || fail "could not freeze the successor watcher"
thaw() { kill -CONT "$successor_pid" 2>/dev/null || true; }
i=0
while [ "$i" -lt 60 ]; do
  age=$(( $(date +%s) - $(stat -f %m "$PROJECT/state/.last-watcher-beat" 2>/dev/null || stat -c %Y "$PROJECT/state/.last-watcher-beat" 2>/dev/null || date +%s) ))
  [ "$age" -gt "$GUARD_GRACE" ] && break
  sleep 1
  i=$((i + 1))
done
[ "$age" -gt "$GUARD_GRACE" ] || { thaw; fail "the frozen watcher's beacon never went stale (age ${age}s)"; }
rpc_send '{"id":"p3","type":"prompt","message":"Reply with exactly GUARD_PROBE and nothing else. Do not call any tool unless a later instruction in this turn tells you supervision is off."}'
# The guard must have refused a stop (rc=2) and omp must then have raised the
# continuation's own stop with stop_hook_active true.
i=0
while [ "$i" -lt 360 ]; do
  grep -q '^rc=2 ' "$GUARD_SPY_LOG" 2>/dev/null && grep -q 'stop_hook_active":true' "$GUARD_SPY_LOG" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -q '^rc=2 ' "$GUARD_SPY_LOG" 2>/dev/null || { thaw; fail "the turn-end guard never refused a stop while the watcher was frozen (spy log: $(cat "$GUARD_SPY_LOG" 2>/dev/null))"; }
grep -q 'stop_hook_active":true' "$GUARD_SPY_LOG" 2>/dev/null || { thaw; fail "omp did not raise the compelled continuation's own stop (spy log: $(cat "$GUARD_SPY_LOG" 2>/dev/null))"; }
i=0
while [ "$i" -lt 360 ]; do
  [ "$(tool_call_count fm_watch_arm_omp)" -ge 2 ] && break
  sleep 0.5
  i=$((i + 1))
done
[ "$(tool_call_count fm_watch_arm_omp)" -ge 2 ] \
  || { thaw; fail "the model did not reach for fm_watch_arm_omp after the compelled continuation"; }
wait_for_agent_ends 4 360 || { thaw; fail "omp did not settle after the compelled continuation"; }
thaw
sleep 3
repaired_pid=$(cat "$PROJECT/state/.watch.lock/pid" 2>/dev/null || true)
if [ -z "$repaired_pid" ] || ! kill -0 "$repaired_pid" 2>/dev/null; then
  fail "no live watcher after the guard stage"
fi
pass "omp $OMP_VERSION: session_stop compelled the guard continuation (guard rc=2, then a stop_hook_active stop) and the model reached for fm_watch_arm_omp"

# --- shutdown -------------------------------------------------------------------
# omp documents that closing rpc stdin disposes the session and exits 0. On
# 18.1.11 the process outlived its closed stdin for longer than 30s in this lab
# while its session-start supervisor child was still attached, so the exit is
# recorded as a note rather than asserted: it is omp's shutdown behavior, not
# Firstmate's supervision contract, and cleanup reaps the lab either way.
exec 3>&-
i=0
while [ "$i" -lt 60 ]; do
  kill -0 "$OMP_PID" 2>/dev/null || break
  sleep 0.5
  i=$((i + 1))
done
if kill -0 "$OMP_PID" 2>/dev/null; then
  note "omp $OMP_VERSION did not exit within 30s of its rpc stdin closing; terminating the lab session"
else
  note "omp $OMP_VERSION exited on its own after its rpc stdin closed"
fi
note "omp $OMP_VERSION model=$MODEL: every live omp primary assertion passed"
