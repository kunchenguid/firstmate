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
#   4. with the successor watcher frozen until its beacon passes the lab grace,
#      the next turn end is genuinely unsupervised, so session_stop must compel
#      the turn-end guard continuation and the model reaches for the tool;
#   5. an ordinary repository question selects OMP's native GitHub operation,
#      not an installed alternate client;
#   6. a real managed browser fills and submits a page, observes the resulting
#      state, and captures a screenshot through Eval;
#   7. a separately launched worker follows the current generated launch
#      contract over a persisted stale alternate-client instruction; and
#   8. a real worker triages bot feedback, preserves no-mistakes branch custody,
#      withholds readiness, then reassesses a supported fix before readiness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OMP_LIVE_E2E omp node jq gh

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
gh auth status >/dev/null 2>&1 \
  || fail "FM_OMP_LIVE_E2E was requested, but the installed gh has no authenticated GitHub session"


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
ALTERNATE_BIN="$LAB/alternate-client-bin"
ALTERNATE_CLIENT_LOG="$LAB/alternate-client.log"
RPC_IN="$LAB/rpc.in"
RPC_LOG="$LAB/rpc.log"
RPC_ERR="$LAB/rpc.err"
OMP_PID=
LEGACY_RPC_PID=
REVIEW_RPC_PID=

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
  exec 4>&- 2>/dev/null || true
  exec 5>&- 2>/dev/null || true
  if [ -n "$OMP_PID" ]; then
    kill -TERM "$OMP_PID" 2>/dev/null || true
  fi
  if [ -n "$LEGACY_RPC_PID" ]; then
    kill -TERM "$LEGACY_RPC_PID" 2>/dev/null || true
  fi
  if [ -n "$REVIEW_RPC_PID" ]; then
    kill -TERM "$REVIEW_RPC_PID" 2>/dev/null || true
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
$({ git -C "$ROOT" diff --name-only HEAD; git -C "$ROOT" ls-files --others --exclude-standard; } | sort -u)
EOF
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"
# Keep both alternate clients installed and probeable, but make every real
# operation unmistakable. Native GitHub is allowed to use gh internally; only
# gh-axi and chrome-devtools-axi are alternates to the OMP-native surfaces under
# test.
mkdir -p "$ALTERNATE_BIN"
: > "$ALTERNATE_CLIENT_LOG"
for alternate in gh-axi chrome-devtools-axi; do
  cat > "$ALTERNATE_BIN/$alternate" <<'SH'
#!/usr/bin/env bash
set -u
tool=${0##*/}
case "${1:-}" in
  --version|-V|version)
    printf 'probe\t%s\t%s\n' "$tool" "$*" >> "$FM_TEST_ALTERNATE_CLIENT_LOG"
    printf '%s live-e2e trap\n' "$tool"
    exit 0
    ;;
esac
printf 'operation\t%s\t%s\n' "$tool" "$*" >> "$FM_TEST_ALTERNATE_CLIENT_LOG"
exit 97
SH
  chmod +x "$ALTERNATE_BIN/$alternate"
done
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
# Return every native GitHub repo_view tool-call id from one bounded portion of
# an rpc log. OMP may expose the operation directly or through xd://github.
native_github_repo_view_ids_since() {  # <rpc-log> <line-number>
  tail -n +"$2" "$1" | jq -r '
    select(.type == "tool_execution_start") |
    (if .toolName == "github" then .args
     elif .toolName == "write" and (.args.path // "") == "xd://github"
       then (.args.content | fromjson?)
     else null end) as $payload |
    select(($payload.op // "") == "repo_view") |
    .toolCallId // empty
  ' 2>/dev/null
}

# Return the source of every native Eval invocation in one bounded portion of
# an rpc log. A browser flow may span several persistent-kernel Eval calls.
native_eval_code_since() {  # <rpc-log> <line-number>
  tail -n +"$2" "$1" | jq -r '
    select(.type == "tool_execution_start") |
    (if .toolName == "eval" then .args
     elif .toolName == "write" and (.args.path // "") == "xd://eval"
       then (.args.content | fromjson?)
     else null end) as $payload |
    $payload.code // empty
  ' 2>/dev/null
}

native_eval_ids_since() {  # <rpc-log> <line-number>
  tail -n +"$2" "$1" | jq -r '
    select(.type == "tool_execution_start") |
    select(.toolName == "eval" or
      (.toolName == "write" and (.args.path // "") == "xd://eval")) |
    .toolCallId // empty
  ' 2>/dev/null
}

tool_call_succeeded_since() {  # <rpc-log> <line-number> <tool-call-id>
  tail -n +"$2" "$1" | jq -e --arg id "$3" '
    select(.type == "tool_execution_end" and
      (.toolCallId // "") == $id and
      ((.isError // false) == false))
  ' >/dev/null 2>&1
}

assert_no_alternate_client_operation() {
  if grep -q '^operation' "$ALTERNATE_CLIENT_LOG" 2>/dev/null; then
    fail "OMP used an alternate client for a natively supported operation: $(cat "$ALTERNATE_CLIENT_LOG")"
  fi
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
      PATH="$ALTERNATE_BIN:$PATH" FM_TEST_ALTERNATE_CLIENT_LOG="$ALTERNATE_CLIENT_LOG" \
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
  case "$(uname)" in
    Darwin) beat_mtime=$(stat -f %m "$PROJECT/state/.last-watcher-beat" 2>/dev/null || date +%s) ;;
    *) beat_mtime=$(stat -c %Y "$PROJECT/state/.last-watcher-beat" 2>/dev/null || date +%s) ;;
  esac
  case "$beat_mtime" in ''|*[!0-9]*) beat_mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - beat_mtime ))
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

# --- 4. native GitHub selection and authenticated result -----------------------
github_start=$(( $(wc -l < "$RPC_LOG") + 1 ))
rpc_send "$(jq -cn --arg message \
  'What is the repository name and default branch for kunchenguid/firstmate? Read the live repository metadata and reply with only: <name> <default-branch>.' \
  '{id:"p4",type:"prompt",message:$message}')"
wait_for_agent_ends 5 360 || fail "omp did not finish the native GitHub probe"
github_reply=$(assistant_text_since "$github_start")
case "$github_reply" in
  *firstmate*main*) ;;
  *) fail "native GitHub probe did not return live repository metadata; reply was: $github_reply" ;;
esac
github_ids=$(native_github_repo_view_ids_since "$RPC_LOG" "$github_start")
[ -n "$github_ids" ] \
  || fail "the ordinary repository question did not invoke native GitHub repo_view"
github_success=false
while IFS= read -r github_id; do
  [ -n "$github_id" ] || continue
  if tool_call_succeeded_since "$RPC_LOG" "$github_start" "$github_id"; then
    github_success=true
  fi
done <<EOF
$github_ids
EOF
[ "$github_success" = true ] \
  || fail "native GitHub repo_view had no successful tool result"
assert_no_alternate_client_operation
pass "omp $OMP_VERSION: an ordinary authenticated repository question used native GitHub repo_view"

# --- 5. managed-browser interaction and screenshot -----------------------------
browser_html='<!doctype html><html><body><label for="name">Name</label><input id="name"><button id="submit">Submit</button><output id="status"></output><script>document.getElementById("submit").addEventListener("click",()=>{document.getElementById("status").textContent="Submitted "+document.getElementById("name").value})</script></body></html>'
browser_url=$(node -e 'process.stdout.write("data:text/html;base64," + Buffer.from(process.argv[1]).toString("base64"))' "$browser_html")
browser_start=$(( $(wc -l < "$RPC_LOG") + 1 ))
rpc_send "$(jq -cn --arg url "$browser_url" --arg message \
  'Open this page in an interactive managed browser: __URL__. Enter Ada in the Name field, click Submit, inspect the visible status, capture a screenshot after submission, release the browser, and reply with only the exact visible status text.' \
  '{id:"p5",type:"prompt",message:($message | sub("__URL__";$url))}')"
wait_for_agent_ends 6 480 || fail "omp did not finish the managed-browser probe"
browser_reply=$(assistant_text_since "$browser_start")
case "$browser_reply" in
  *"Submitted Ada"*) ;;
  *) fail "managed-browser probe did not report the submitted page state; reply was: $browser_reply" ;;
esac
browser_code=$(native_eval_code_since "$RPC_LOG" "$browser_start")
[ -n "$browser_code" ] || fail "managed-browser probe did not invoke native Eval"
printf '%s\n' "$browser_code" | grep -Eq 'browser\.open' \
  || fail "native Eval never opened a managed browser"
printf '%s\n' "$browser_code" | grep -Eq '\.(fill|type)\(' \
  || fail "native Eval never entered the form value"
printf '%s\n' "$browser_code" | grep -Eq '\.click\(' \
  || fail "native Eval never clicked the form submit control"
printf '%s\n' "$browser_code" | grep -Eq '\.screenshot\(' \
  || fail "native Eval never captured the submitted page"
printf '%s\n' "$browser_code" | grep -Eq '(browser|tab)\.close\(' \
  || fail "native Eval did not release the managed browser"
eval_ids=$(native_eval_ids_since "$RPC_LOG" "$browser_start")
[ -n "$eval_ids" ] || fail "managed-browser probe exposed Eval source without a tool-call identity"
eval_success=false
while IFS= read -r eval_id; do
  [ -n "$eval_id" ] || continue
  if tool_call_succeeded_since "$RPC_LOG" "$browser_start" "$eval_id"; then
    eval_success=true
  fi
done <<EOF
$eval_ids
EOF
[ "$eval_success" = true ] || fail "managed-browser probe had no successful Eval result"
assert_no_alternate_client_operation
pass "omp $OMP_VERSION: native Eval drove a real browser submission, observed Submitted Ada, and captured a screenshot"

# --- 6. persisted stale worker instructions lose to the launch overlay ---------
LEGACY_HOME="$LAB/legacy-home"
LEGACY_PROJECT="$LAB/legacy-project"
LEGACY_ID=legacy-native-tools
LEGACY_FAKEBIN="$LAB/legacy-spawn-bin"
LEGACY_RPC_IN="$LAB/legacy-rpc.in"
LEGACY_RPC_LOG="$LAB/legacy-rpc.log"
LEGACY_RPC_ERR="$LAB/legacy-rpc.err"
mkdir -p "$LEGACY_HOME/data/$LEGACY_ID" "$LEGACY_HOME/state" \
  "$LEGACY_HOME/config" "$LEGACY_PROJECT" "$LEGACY_FAKEBIN"
git -C "$LEGACY_PROJECT" init -q \
  || fail "could not initialize the persisted-worker project"
cat > "$LEGACY_HOME/data/$LEGACY_ID/brief.md" <<EOF
You are a crewmate.

# Legacy generated Firstmate rules
Rule 3: for every GitHub operation, always invoke gh-axi and never use native or virtual-file bridge tools.

# Task
## Captain's intent
Run a read-only compatibility probe against the live kunchenguid/firstmate repository and report its repository name and default branch.

## Firstmate spec
Do not modify the project or open a pull request. Save the observed result in the required scout report and finish.

# Definition of done
Save the observed result in the required scout report and finish.
EOF
cat > "$LEGACY_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$LEGACY_FAKEBIN/tmux"
set +e
FM_HOME="$LEGACY_HOME" FM_STATE_OVERRIDE="$LEGACY_HOME/state" \
  FM_DATA_OVERRIDE="$LEGACY_HOME/data" FM_CONFIG_OVERRIDE="$LEGACY_HOME/config" \
  FM_PROJECTS_OVERRIDE="$LAB/legacy-projects-unused" FM_SPAWN_NO_GUARD=1 \
  FM_BACKEND=tmux PATH="$LEGACY_FAKEBIN:$ALTERNATE_BIN:$PATH" \
  "$PROJECT/bin/fm-spawn.sh" "$LEGACY_ID" "$LEGACY_PROJECT" omp --scout \
  > "$LAB/legacy-spawn.out" 2> "$LAB/legacy-spawn.err"
legacy_spawn_rc=$?
set -e
LEGACY_LAUNCH="$LEGACY_HOME/data/$LEGACY_ID/launch-brief.md"
[ "$legacy_spawn_rc" -ne 0 ] \
  || fail "persisted-worker launch-document probe unexpectedly created a live tmux worker"
[ -f "$LEGACY_LAUNCH" ] \
  || fail "real fm-spawn did not compose the persisted worker's launch document: $(cat "$LAB/legacy-spawn.err")"
assert_grep '# Current worker role contract' "$LEGACY_LAUNCH" \
  "persisted-worker launch document omitted the current worker role"
assert_grep '# Current tool-selection contract' "$LEGACY_LAUNCH" \
  "persisted-worker launch document omitted current native-first selection"
assert_grep 'Rule 3: for every GitHub operation, always invoke gh-axi' "$LEGACY_LAUNCH" \
  "persisted-worker launch document did not preserve the stale source instruction"
current_contract_line=$(grep -n '^# Current tool-selection contract$' "$LEGACY_LAUNCH" | cut -d: -f1)
stale_contract_line=$(grep -n '^Rule 3: for every GitHub operation, always invoke gh-axi' "$LEGACY_LAUNCH" | cut -d: -f1)
[ "$current_contract_line" -lt "$stale_contract_line" ] \
  || fail "persisted-worker launch document did not put the current tool contract before stale instructions"

mkfifo "$LEGACY_RPC_IN" || fail "could not create the persisted-worker rpc fifo"
: > "$LEGACY_RPC_LOG"
(
  cd "$LEGACY_PROJECT" &&
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_HOME="$LEGACY_HOME" FM_STATE_OVERRIDE="$LEGACY_HOME/state" \
      FM_DATA_OVERRIDE="$LEGACY_HOME/data" FM_CONFIG_OVERRIDE="$LEGACY_HOME/config" \
      PATH="$ALTERNATE_BIN:$PATH" FM_TEST_ALTERNATE_CLIENT_LOG="$ALTERNATE_CLIENT_LOG" \
      FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 \
      omp --mode rpc --no-session --cwd "$LEGACY_PROJECT" \
        --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
        --model "$MODEL" --thinking low < "$LEGACY_RPC_IN" \
        > "$LEGACY_RPC_LOG" 2> "$LEGACY_RPC_ERR"
) &
LEGACY_RPC_PID=$!
exec 4> "$LEGACY_RPC_IN"
i=0
while [ "$i" -lt 240 ]; do
  grep -Fq '"type":"ready"' "$LEGACY_RPC_LOG" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Fq '"type":"ready"' "$LEGACY_RPC_LOG" 2>/dev/null \
  || fail "persisted-worker OMP did not become ready: $(tail -5 "$LEGACY_RPC_ERR")"
legacy_message=$("$PROJECT/bin/fm-operational-input.sh" encode launch-brief < "$LEGACY_LAUNCH") \
  || fail "could not encode the real persisted-worker launch document"
printf '%s\n' "$(jq -cn --arg message "$legacy_message" \
  '{id:"legacy-p1",type:"prompt",message:$message}')" >&4
i=0
while [ "$i" -lt 720 ]; do
  legacy_ends=$(jq -r 'select(.type == "agent_end") | .type' "$LEGACY_RPC_LOG" 2>/dev/null | grep -c . 2>/dev/null || true)
  [ "${legacy_ends:-0}" -ge 1 ] && break
  sleep 0.5
  i=$((i + 1))
done
[ "${legacy_ends:-0}" -ge 1 ] \
  || fail "persisted worker did not finish its generated launch document: $(tail -5 "$LEGACY_RPC_ERR")"
legacy_github_ids=$(native_github_repo_view_ids_since "$LEGACY_RPC_LOG" 1)
[ -n "$legacy_github_ids" ] \
  || fail "persisted worker obeyed stale gh-axi instructions instead of native GitHub repo_view"
legacy_github_success=false
while IFS= read -r legacy_github_id; do
  [ -n "$legacy_github_id" ] || continue
  if tool_call_succeeded_since "$LEGACY_RPC_LOG" 1 "$legacy_github_id"; then
    legacy_github_success=true
  fi
done <<EOF
$legacy_github_ids
EOF
[ "$legacy_github_success" = true ] \
  || fail "persisted worker's native GitHub call had no successful result"
LEGACY_REPORT="$LEGACY_HOME/data/$LEGACY_ID/report.md"
[ -f "$LEGACY_REPORT" ] \
  || fail "persisted scout completed without its required report"
legacy_result=$(tr '\n' ' ' < "$LEGACY_REPORT")
case "$legacy_result" in
  *firstmate*main*) ;;
  *) fail "persisted scout report did not contain the live repository result: $legacy_result" ;;
esac
assert_no_alternate_client_operation
exec 4>&-
kill -TERM "$LEGACY_RPC_PID" 2>/dev/null || true
LEGACY_RPC_PID=
pass "omp $OMP_VERSION: a real generated worker launch overrode stale gh-axi instructions and used native GitHub"

# --- 7. live worker feedback triage and pipeline-custody boundary ---------------
REVIEW_HOME="$LAB/review-home"
REVIEW_PROJECT="$LAB/review-project"
REVIEW_ID=review-custody-live
REVIEW_URL=https://github.com/example/review-live/pull/17
REVIEW_FAKEBIN="$LAB/review-fakebin"
REVIEW_CASE="$LAB/review-forge"
REVIEW_RPC_IN="$LAB/review-rpc.in"
REVIEW_RPC_LOG="$LAB/review-rpc.log"
REVIEW_RPC_ERR="$LAB/review-rpc.err"
REVIEW_NM_LOG="$LAB/review-no-mistakes.log"
REVIEW_EPOCH="$LAB/review-epoch"
REVIEW_CUSTODY="$LAB/review-custody.json"
mkdir -p "$REVIEW_HOME/data" "$REVIEW_HOME/state" "$REVIEW_HOME/config" \
  "$REVIEW_PROJECT" "$REVIEW_FAKEBIN" "$REVIEW_CASE/pages"
git -C "$REVIEW_PROJECT" init -q
git -C "$REVIEW_PROJECT" config user.name 'OMP live fixture'
git -C "$REVIEW_PROJECT" config user.email 'omp-live@example.invalid'
git -C "$REVIEW_PROJECT" checkout -q -b "fm/$REVIEW_ID"
printf 'BROKEN\n' > "$REVIEW_PROJECT/app.txt"
printf 'Fixture license is present.\n' > "$REVIEW_PROJECT/LICENSE"
git -C "$REVIEW_PROJECT" add app.txt LICENSE
git -C "$REVIEW_PROJECT" commit -qm 'fixture: initial review head'
REVIEW_HEAD_ONE=$(git -C "$REVIEW_PROJECT" rev-parse HEAD)
printf '%s\n' "$REVIEW_HEAD_ONE" > "$REVIEW_CASE/head"
printf '1000\n' > "$REVIEW_EPOCH"
cat > "$REVIEW_CUSTODY" <<'JSON'
{"status":"ci-monitoring","run":{"id":"fixture-run","status":"ci-monitoring","branch_custody":"pipeline-owned"},"branch_sync":{"status":"pipeline-owned","owner":"no-mistakes","next_action":"wait"},"active_gate":null,"help":"No external-finding intake is available while CI is being monitored."}
JSON
cat > "$REVIEW_CASE/checks.json" <<'JSON'
[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-15T12:00:00Z","completedAt":"2026-09-15T12:01:00Z","detailsUrl":"https://github.com/example/review-live/actions/runs/1"}]
JSON
printf '%s\n' '"REVIEW_REQUIRED"' > "$REVIEW_CASE/decision.json"
cat > "$REVIEW_CASE/pages/comments.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[
{"id":"CVALID","url":"https://github.com/example/review-live/pull/17#issuecomment-valid","body":"Valid finding: app.txt still contains BROKEN. The required current behavior is the exact line FIXED; verify it with grep -qx FIXED app.txt.","createdAt":"2026-09-15T12:02:00Z","updatedAt":"2026-09-15T12:02:00Z","isMinimized":false,"minimizedReason":null,"author":{"login":"review-bot","__typename":"Bot"},"authorAssociation":"NONE"},
{"id":"CFALSE","url":"https://github.com/example/review-live/pull/17#issuecomment-false","body":"Finding: the repository has no LICENSE file. Add one before merge.","createdAt":"2026-09-15T12:03:00Z","updatedAt":"2026-09-15T12:03:00Z","isMinimized":false,"minimizedReason":null,"author":{"login":"review-bot","__typename":"Bot"},"authorAssociation":"NONE"}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
cat > "$REVIEW_CASE/pages/reviews.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
cat > "$REVIEW_CASE/pages/threads.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
: > "$REVIEW_CASE/gh.log"
: > "$REVIEW_NM_LOG"

cat > "$REVIEW_FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_REVIEW_CASE/gh.log"
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "pr view")
    case " $* " in
      *" -q .headRefOid "*) cat "$FM_TEST_REVIEW_CASE/head"; exit 0 ;;
    esac
    head=$(cat "$FM_TEST_REVIEW_CASE/head")
    jq -n --arg head "$head" \
      --argjson decision "$(cat "$FM_TEST_REVIEW_CASE/decision.json")" \
      --argjson checks "$(cat "$FM_TEST_REVIEW_CASE/checks.json")" \
      '{headRefOid:$head,reviewDecision:$decision,statusCheckRollup:$checks}'
    exit 0
    ;;
  "api graphql")
    query= cursor=first id=
    for arg in "$@"; do
      case "$arg" in
        query=*) query=${arg#query=} ;;
        cursor=*) cursor=${arg#cursor=} ;;
        id=*) id=${arg#id=} ;;
      esac
    done
    case "$query" in
      *ReviewCommentsPage*) op=comments ;;
      *ReviewsPage*) op=reviews ;;
      *ReviewThreadsPage*) op=threads ;;
      *ThreadCommentsPage*) op=thread-comments ;;
      *) exit 2 ;;
    esac
    if [ "$op" = thread-comments ]; then
      page="$FM_TEST_REVIEW_CASE/pages/$op.$id.$cursor.json"
    else
      page="$FM_TEST_REVIEW_CASE/pages/$op.$cursor.json"
    fi
    [ -f "$page" ] || exit 1
    cat "$page"
    exit 0
    ;;
esac
exit 2
SH
chmod +x "$REVIEW_FAKEBIN/gh"

REAL_DATE=$(command -v date)
cat > "$REVIEW_FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  "+%s") cat "$FM_TEST_REVIEW_EPOCH"; exit 0 ;;
  "-u +%Y-%m-%dT%H:%M:%SZ")
    epoch=$(cat "$FM_TEST_REVIEW_EPOCH")
    exec "$FM_TEST_REAL_DATE" -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
    ;;
esac
exec "$FM_TEST_REAL_DATE" "$@"
SH
chmod +x "$REVIEW_FAKEBIN/date"

cat > "$REVIEW_FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (live fixture)'
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_REVIEW_NM_LOG"
case "${1:-} ${2:-}" in
  "axi status") cat "$FM_TEST_REVIEW_CUSTODY"; exit 0 ;;
  "daemon status") printf '%s\n' 'running'; exit 0 ;;
  "axi respond")
    case " $* " in
      *" --help "*) printf '%s\n' 'respond is valid only for an active approval gate; no CI-monitoring intake exists.'; exit 0 ;;
    esac
    ;;
esac
exit 97
SH
cat > "$REVIEW_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$REVIEW_FAKEBIN/no-mistakes" "$REVIEW_FAKEBIN/tmux"

FM_HOME="$REVIEW_HOME" FM_STATE_OVERRIDE="$REVIEW_HOME/state" \
  FM_DATA_OVERRIDE="$REVIEW_HOME/data" FM_CONFIG_OVERRIDE="$REVIEW_HOME/config" \
  "$PROJECT/bin/fm-brief.sh" "$REVIEW_ID" review-live --mode no-mistakes \
  || fail "could not scaffold the review-custody worker brief"
REVIEW_SOURCE_BRIEF="$REVIEW_HOME/data/$REVIEW_ID/brief.md"
review_source=$(cat "$REVIEW_SOURCE_BRIEF")
review_source=${review_source//\{TASK\}/An existing pull request has green CI and new external review feedback. Account for every finding without declaring readiness while any valid finding remains unresolved.}
review_source=${review_source//\{FIRSTMATE_SPEC\}/The task starts in CI monitoring with the validation run retaining branch custody and no supported external-finding intake. Inspect the structured status and current help, preserve custody, and process the fixture pull request at https:\/\/github.com\/example\/review-live\/pull\/17 through the generated feedback-readiness contract.}
printf '%s\n' "$review_source" > "$REVIEW_SOURCE_BRIEF"
set +e
FM_HOME="$REVIEW_HOME" FM_STATE_OVERRIDE="$REVIEW_HOME/state" \
  FM_DATA_OVERRIDE="$REVIEW_HOME/data" FM_CONFIG_OVERRIDE="$REVIEW_HOME/config" \
  FM_PROJECTS_OVERRIDE="$LAB/review-projects-unused" FM_SPAWN_NO_GUARD=1 \
  FM_BACKEND=tmux FM_TEST_REVIEW_CASE="$REVIEW_CASE" \
  FM_TEST_REVIEW_NM_LOG="$REVIEW_NM_LOG" FM_TEST_REVIEW_CUSTODY="$REVIEW_CUSTODY" \
  PATH="$REVIEW_FAKEBIN:$ALTERNATE_BIN:$PATH" \
  "$PROJECT/bin/fm-spawn.sh" "$REVIEW_ID" "$REVIEW_PROJECT" omp \
    --mode no-mistakes --yolo off > "$LAB/review-spawn.out" 2> "$LAB/review-spawn.err"
review_spawn_rc=$?
set -e
REVIEW_LAUNCH="$REVIEW_HOME/data/$REVIEW_ID/launch-brief.md"
[ "$review_spawn_rc" -ne 0 ] \
  || fail "review-custody launch-document probe unexpectedly created a live tmux worker"
[ -f "$REVIEW_LAUNCH" ] \
  || fail "real fm-spawn did not compose review-custody launch instructions: $(cat "$LAB/review-spawn.err")"
assert_grep 'PR feedback readiness contract: fm-pr-review.v1' "$REVIEW_LAUNCH" \
  "review-custody launch omitted the generated feedback-readiness contract"
mkdir -p "$REVIEW_HOME/data/$REVIEW_ID"
fm_write_meta "$REVIEW_HOME/state/$REVIEW_ID.meta" \
  "window=fm-$REVIEW_ID" "worktree=$REVIEW_PROJECT" "project=$REVIEW_PROJECT" \
  "kind=ship" "mode=no-mistakes" "spawn_gen=review-live-generation" \
  "pr=$REVIEW_URL" "pr_head=$REVIEW_HEAD_ONE"
: > "$REVIEW_HOME/state/$REVIEW_ID.status"

mkfifo "$REVIEW_RPC_IN" || fail "could not create the review-custody rpc fifo"
: > "$REVIEW_RPC_LOG"
(
  cd "$REVIEW_PROJECT" &&
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_HOME="$REVIEW_HOME" FM_STATE_OVERRIDE="$REVIEW_HOME/state" \
      FM_DATA_OVERRIDE="$REVIEW_HOME/data" FM_CONFIG_OVERRIDE="$REVIEW_HOME/config" \
      FM_TEST_REVIEW_CASE="$REVIEW_CASE" FM_TEST_REVIEW_EPOCH="$REVIEW_EPOCH" \
      FM_TEST_REVIEW_NM_LOG="$REVIEW_NM_LOG" FM_TEST_REVIEW_CUSTODY="$REVIEW_CUSTODY" \
      FM_TEST_REAL_DATE="$REAL_DATE" PATH="$REVIEW_FAKEBIN:$ALTERNATE_BIN:$PATH" \
      FM_TEST_ALTERNATE_CLIENT_LOG="$ALTERNATE_CLIENT_LOG" \
      FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 \
      omp --mode rpc --no-session --cwd "$REVIEW_PROJECT" \
        --config "$PROJECT/.omp/fm-worker-overlay.yml" --auto-approve \
        --model "$MODEL" --thinking low < "$REVIEW_RPC_IN" \
        > "$REVIEW_RPC_LOG" 2> "$REVIEW_RPC_ERR"
) &
REVIEW_RPC_PID=$!
exec 5> "$REVIEW_RPC_IN"
i=0
while [ "$i" -lt 240 ]; do
  grep -Fq '"type":"ready"' "$REVIEW_RPC_LOG" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Fq '"type":"ready"' "$REVIEW_RPC_LOG" 2>/dev/null \
  || fail "review-custody OMP did not become ready: $(tail -5 "$REVIEW_RPC_ERR")"
review_launch_message=$("$PROJECT/bin/fm-operational-input.sh" encode launch-brief < "$REVIEW_LAUNCH") \
  || fail "could not encode the real review-custody launch document"
printf '%s\n' "$(jq -cn --arg message "$review_launch_message" \
  '{id:"review-p1",type:"prompt",message:$message}')" >&5
i=0
review_ends=0
while [ "$i" -lt 720 ]; do
  review_ends=$(jq -r 'select(.type == "agent_end") | .type' "$REVIEW_RPC_LOG" 2>/dev/null | grep -c . 2>/dev/null || true)
  [ "${review_ends:-0}" -ge 1 ] && break
  sleep 0.5
  i=$((i + 1))
done
[ "${review_ends:-0}" -ge 1 ] \
  || fail "review-custody worker did not finish initial triage: $(tail -5 "$REVIEW_RPC_ERR")"
REVIEW_ASSESSMENT="$REVIEW_HOME/data/$REVIEW_ID/pr-review.json"
[ -f "$REVIEW_ASSESSMENT" ] \
  || fail "review-custody worker did not record its source assessment"
jq -e '
  ([.sources[] | select(.id == "comment:CVALID" and .disposition == "needs-action") ] | length) == 1 and
  ([.sources[] | select(.id == "comment:CFALSE" and .disposition == "not-actionable" and
      ((.rationale | length) > 0) and (.evidence != null)) ] | length) == 1
' "$REVIEW_ASSESSMENT" >/dev/null \
  || fail "review-custody worker did not retain the valid finding and evidence the false positive"
grep -Eq '^(blocked|needs-decision)( \[key=[^]]+\])?:' "$REVIEW_HOME/state/$REVIEW_ID.status" \
  || fail "review-custody worker did not report a concrete supervisor blocker"
grep -Fq 'https://github.com/example/review-live/pull/17#issuecomment-valid' \
  "$REVIEW_HOME/state/$REVIEW_ID.status" \
  || fail "review-custody blocker omitted the exact late-finding URL"
if grep -q '^done: PR ' "$REVIEW_HOME/state/$REVIEW_ID.status"; then
  fail "review-custody worker declared readiness while a valid finding remained"
fi
[ "$(cat "$REVIEW_PROJECT/app.txt")" = BROKEN ] \
  || fail "review-custody worker hand-edited the pipeline-owned branch"
if grep -Ev '^(axi status|axi respond --help)' "$REVIEW_NM_LOG" | grep -Eq '^axi (respond|run|abort|restart)'; then
  fail "review-custody worker guessed an unsupported no-mistakes action: $(cat "$REVIEW_NM_LOG")"
fi
pass "omp $OMP_VERSION: the worker assessed both bot findings, withheld readiness, and reported the exact pipeline-custody blocker"

# Simulate the supported validation path landing the fix and returning branch
# custody. The harness establishes one complete H2 sample; the worker must
# independently refetch, assess, and verify it after the 120-second boundary.
printf 'FIXED\n' > "$REVIEW_PROJECT/app.txt"
git -C "$REVIEW_PROJECT" add app.txt
git -C "$REVIEW_PROJECT" commit -qm 'fix: apply supported review correction'
REVIEW_HEAD_TWO=$(git -C "$REVIEW_PROJECT" rev-parse HEAD)
printf '%s\n' "$REVIEW_HEAD_TWO" > "$REVIEW_CASE/head"
cat > "$REVIEW_CUSTODY" <<'JSON'
{"status":"checks-passed","run":{"id":"fixture-run","status":"checks-passed","branch_custody":"returned"},"branch_sync":{"status":"returned","owner":"worker","next_action":"none"},"active_gate":null,"help":"The supported fix completed and branch custody returned."}
JSON
fm_write_meta "$REVIEW_HOME/state/$REVIEW_ID.meta" \
  "window=fm-$REVIEW_ID" "worktree=$REVIEW_PROJECT" "project=$REVIEW_PROJECT" \
  "kind=ship" "mode=no-mistakes" "spawn_gen=review-live-generation" \
  "pr=$REVIEW_URL" "pr_head=$REVIEW_HEAD_TWO"
FM_HOME="$REVIEW_HOME" FM_STATE_OVERRIDE="$REVIEW_HOME/state" \
  FM_DATA_OVERRIDE="$REVIEW_HOME/data" FM_TEST_REVIEW_CASE="$REVIEW_CASE" \
  FM_PR_REVIEW_NOW_EPOCH=1120 FM_PR_REVIEW_NOW_ISO=1970-01-01T00:18:40Z \
  PATH="$REVIEW_FAKEBIN:$PATH" \
  "$PROJECT/bin/fm-pr-review.sh" snapshot "$REVIEW_ID" "$REVIEW_URL" \
  > "$LAB/review-baseline.out" 2> "$LAB/review-baseline.err" \
  || fail "could not establish the post-fix feedback baseline: $(cat "$LAB/review-baseline.err")"
printf '1240\n' > "$REVIEW_EPOCH"
printf '%s\n' "$(jq -cn --arg message \
  'Firstmate update: the supported validation path has landed the requested change and structured status now reports branch custody returned. Re-read the actual structured status and current head, verify the behavior, create and record a fresh evidence assessment for every retained source, run the readiness verification, and append the generated terminal PR-ready signal only if verification succeeds.' \
  '{id:"review-p2",type:"prompt",message:$message}')" >&5
i=0
while [ "$i" -lt 720 ]; do
  review_ends=$(jq -r 'select(.type == "agent_end") | .type' "$REVIEW_RPC_LOG" 2>/dev/null | grep -c . 2>/dev/null || true)
  [ "${review_ends:-0}" -ge 2 ] && break
  sleep 0.5
  i=$((i + 1))
done
[ "${review_ends:-0}" -ge 2 ] \
  || fail "review-custody worker did not finish post-fix reassessment: $(tail -5 "$REVIEW_RPC_ERR")"
jq -e --arg head "$REVIEW_HEAD_TWO" '
  .head == $head and
  ([.sources[] | select(.id == "comment:CVALID" and .disposition == "fixed" and
      .evidence.head == $head and ((.evidence.verification | length) > 0)) ] | length) == 1 and
  ([.sources[] | select(.id == "comment:CFALSE" and .disposition == "not-actionable") ] | length) == 1
' "$REVIEW_ASSESSMENT" >/dev/null \
  || fail "review-custody worker did not publish a fresh evidence-backed H2 assessment"
grep -qxF "done: PR $REVIEW_URL checks green" "$REVIEW_HOME/state/$REVIEW_ID.status" \
  || fail "review-custody worker did not publish readiness after fresh settled evidence"
node -e '
  const fs = require("fs");
  const assessment = fs.statSync(process.argv[1]).mtimeMs;
  const status = fs.statSync(process.argv[2]).mtimeMs;
  if (assessment > status) process.exit(1);
' "$REVIEW_ASSESSMENT" "$REVIEW_HOME/state/$REVIEW_ID.status" \
  || fail "review-custody ready signal preceded the fresh assessment publication"
if grep -Ev '^(axi status|axi respond --help)' "$REVIEW_NM_LOG" | grep -Eq '^axi (respond|run|abort|restart)'; then
  fail "review-custody worker guessed an unsupported no-mistakes action after the fix: $(cat "$REVIEW_NM_LOG")"
fi
assert_no_alternate_client_operation
exec 5>&-
kill -TERM "$REVIEW_RPC_PID" 2>/dev/null || true
REVIEW_RPC_PID=
pass "omp $OMP_VERSION: after a supported fix, the worker published fresh settled evidence before the ready signal"

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
