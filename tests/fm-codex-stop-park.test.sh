#!/usr/bin/env bash
# Behavior tests for the native Codex Stop-hook park (bin/fm-codex-stop-park.sh)
# and the two hooks it relies on in the watcher (bin/fm-watch.sh owner-gone
# exit) and the supervision host (bin/fm-supervision-host.sh retained quiet
# boundary).
#
# The hook runs hermetically as a descendant of a fake `codex`: a compiled
# stand-in that stays alive as the session's harness ancestor, so the real
# ancestry walk, session-lock ownership check, and version gate all run. It
# forks bash on the impl script written below, which answers `--version`
# with FM_FAKE_CODEX_VERSION, records `queue` deliveries in the home's
# queue.log (exiting FM_FAKE_CODEX_QUEUE_RC), and otherwise runs bash. A plain
# script or bash symlink cannot stand in: the version gate reads the running
# ancestor's own executable (/proc/<pid>/exe on Linux), which must be a
# `codex`-named binary that also answers `--version`.
#
# Each case runs its hooks from one driver script under one fake codex, the
# way every hook of a real session shares one Codex process, and that process
# holds the fixture home's session lock. The arm, session start, and turn-end
# guard are per-suite fixtures in a fixture checkout, so no real watcher arm,
# digest, model, or fleet state is touched; the watcher and host cases run the
# real scripts against a private home.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $PPID expand inside the fake codex's driver
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  FM_SUPERVISION_ACTOR FM_SUPERVISION_PRIMARY_HARNESS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_CONFIG_OVERRIDE FM_CODEX_PARK_SESSION FM_CODEX_MODEL_FREE_PARK FM_CODEX_PARK_OWNER_PID \
  FM_CODEX_PARK_OWNER_IDENTITY

command -v jq >/dev/null 2>&1 || { echo "skip: jq is required by the Codex park"; exit 0; }
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || { echo "skip: no C compiler for the fake codex binary"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-codex-stop-park)
fm_git_identity fmtest fmtest@example.invalid
SESSION_ID=sess-park-1
PAYLOAD='{"session_id":"sess-park-1","stop_hook_active":false}'

# The fake codex binary and its impl script.
FAKE_DIR="$TMP_ROOT/fake-codex"
mkdir -p "$FAKE_DIR/bin"
cat > "$FAKE_DIR/impl.sh" <<'SH'
case "${1:-}" in
  --version)
    printf 'codex-cli %s\n' "${FM_FAKE_CODEX_VERSION:-0.163.0}"
    exit 0
    ;;
  queue)
    printf '%s\n' "$*" >> "$FM_HOME/queue.log"
    exit "${FM_FAKE_CODEX_QUEUE_RC:-0}"
    ;;
esac
exec bash "$@"
SH
cat > "$FAKE_DIR/codex.c" <<'C'
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
  char **args = calloc((size_t)argc + 2, sizeof *args);
  int i, status;
  pid_t pid;
  if (!args) return 127;
  args[0] = "bash";
  args[1] = FAKE_CODEX_IMPL;
  for (i = 1; i < argc; i++) args[i + 1] = argv[i];
  pid = fork();
  if (pid == 0) {
    execvp("bash", args);
    _exit(127);
  }
  if (pid < 0 || waitpid(pid, &status, 0) < 0) return 127;
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
C
"$CC_BIN" -DFAKE_CODEX_IMPL="\"$FAKE_DIR/impl.sh\"" -o "$FAKE_DIR/bin/codex" "$FAKE_DIR/codex.c" \
  || fail "could not compile the fake codex binary"
FAKE_CODEX="$FAKE_DIR/bin/codex"

# A plain fixture checkout holding the hook, its libraries, and fixtures for
# the scripts it delegates to.
CODE="$TMP_ROOT/code"
mkdir -p "$CODE/bin"
git init -q "$CODE"
git -C "$CODE" commit -q --allow-empty -m init
: > "$CODE/AGENTS.md"
cp "$ROOT/bin/fm-codex-stop-park.sh" "$ROOT/bin/fm-harness.sh" "$ROOT"/bin/*-lib.sh "$CODE/bin/"
PARK="$CODE/bin/fm-codex-stop-park.sh"

# The arm fixture reads its behavior from the home: `wake` reports a signal at
# once, `fail` exits 1 with no wake, and `park` reports a signal only once
# arm-hold is removed. Every arm appends its environment's park binding to
# arm-ran.
cat > "$CODE/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'pid=%s model_free=%s owner=%s\n' "$$" "${FM_CODEX_MODEL_FREE_PARK:-}" \
  "${FM_CODEX_PARK_OWNER_PID:-}" >> "$FM_HOME/arm-ran"
case "$(cat "$FM_HOME/arm-mode" 2>/dev/null)" in
  fail)
    printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
    exit 1
    ;;
  park)
    printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
    while [ -e "$FM_HOME/arm-hold" ]; do sleep 0.1; done
    ;;
esac
printf 'signal: fixture-task finished\n'
SH
cat > "$CODE/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
cat > "$FM_HOME/sessionstart-payload"
printf '%s\n' "${FM_CODEX_PARK_SESSION:-}" > "$FM_HOME/sessionstart-park-session"
SH
cat > "$CODE/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf 'ran\n' >> "$FM_HOME/turnend-guard-ran"
SH
chmod +x "$CODE"/bin/*.sh

# A home with work under way. $2 = opted-in or plain.
make_home() {  # <name> <opted-in|plain>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  : > "$home/state/fixture-task.meta"
  [ "$2" = plain ] || : > "$home/config/codex-stop-park"
  printf '{"type":"session_meta","payload":{"id":"%s","originator":"codex-tui"}}\n' "$SESSION_ID" \
    > "$home/transcript.jsonl"
  fm_test_track_watcher_state "$home/state"
  printf '%s\n' "$home"
}

# Run driver text under one fake codex that holds the home's session lock.
# PARK, PAYLOAD, and SESSION_ID are available to the driver.
under_codex() {  # <home> <driver> [VAR=VAL ...]
  local home=$1 driver=$2
  shift 2
  env FM_HOME="$home" PARK="$PARK" PAYLOAD="$PAYLOAD" SESSION_ID="$SESSION_ID" "$@" \
    "$FAKE_CODEX" -c 'printf "%s\n" "$PPID" > "$FM_HOME/state/.lock"
'"$driver"
}

# The driver line that registers SESSION_ID the way a native SessionStart
# does, bound to the lock-holding codex.
REGISTER='printf "%s\n%s\n" "$SESSION_ID" "$PPID" > "$FM_HOME/state/.codex-park-session"
'

arm_count() {  # <home>
  if [ -f "$1/arm-ran" ]; then wc -l < "$1/arm-ran" | tr -d '[:space:]'; else printf '0\n'; fi
}

queue_count() {  # <home>
  if [ -f "$1/queue.log" ]; then grep -c '^queue --thread ' "$1/queue.log"; else printf '0\n'; fi
}

outcome() {  # <home>
  jq -r '.outcome // empty' "$1/state/.codex-park.json" 2>/dev/null
}

test_unconfigured_home_keeps_the_foreground_checkpoint() {
  local home out
  home=$(make_home plain plain)
  out=$(under_codex "$home" '
    printf "%s" "{\"session_id\":\"$SESSION_ID\",\"transcript_path\":\"$FM_HOME/transcript.jsonl\"}" \
      | "$PARK" --session-start; echo "session-start=$?"
    '"$REGISTER"'
    "$PARK" --capable; echo "capable=$?"
    printf "%s" "$PAYLOAD" | "$PARK"; echo "stop=$?"
    printf "%s" "$PAYLOAD" | "$PARK" --guard; echo "guard=$?"
    : > "$FM_HOME/config/codex-stop-park"
    "$PARK" --capable; echo "opted-in-capable=$?"
  ' 2>&1)
  assert_contains "$out" "session-start=0" "the session start must still run without the opt-in: $out"
  assert_contains "$(cat "$home/sessionstart-payload")" "\"session_id\":\"$SESSION_ID\"" \
    "the session start must receive the native payload unchanged"
  assert_equals "" "$(cat "$home/sessionstart-park-session")" \
    "a home without the opt-in must not select the park for its session start"
  assert_contains "$out" "capable=1" "a home without the opt-in must not report a capable park: $out"
  assert_contains "$out" "stop=0" "the asynchronous Stop hook must exit at once without the opt-in: $out"
  assert_equals 0 "$(arm_count "$home")" "a home without the opt-in must not arm a park"
  assert_absent "$home/state/.codex-park.lock" "a home without the opt-in must not take the park claim"
  assert_absent "$home/state/.codex-park.json" "a home without the opt-in must not write a park record"
  assert_contains "$out" "guard=0" "the synchronous guard must defer to the turn-end guard without the opt-in: $out"
  assert_equals ran "$(cat "$home/turnend-guard-ran" 2>/dev/null)" "the turn-end guard must run exactly once"
  assert_absent "$home/state/.codex-park-fallback" "a home without the opt-in must not latch a fallback"
  assert_contains "$out" "opted-in-capable=0" "the same session must be capable once opted in, or the gate is untested: $out"
  pass "an unconfigured home keeps the foreground checkpoint and every park hook is inert"
}

test_version_gate_selects_only_the_verified_cli() {
  local home out version
  for version in 0.163.0 0.164.0; do
    home=$(make_home "version-$version" opted-in)
    out=$(under_codex "$home" '
      printf "%s" "{\"session_id\":\"$SESSION_ID\",\"transcript_path\":\"$FM_HOME/transcript.jsonl\"}" \
        | "$PARK" --session-start; echo "session-start=$?"
      "$PARK" --capable; echo "capable=$?"
      '"$REGISTER"'
      "$PARK" --capable; echo "registered-capable=$?"
    ' FM_FAKE_CODEX_VERSION="$version" 2>&1)
    assert_contains "$out" "session-start=0" "session start under codex-cli $version: $out"
    if [ "$version" = 0.163.0 ]; then
      assert_equals "$SESSION_ID" "$(sed -n 1p "$home/state/.codex-park-session" 2>/dev/null)" \
        "the verified CLI's native session start must register the session"
      assert_equals "$SESSION_ID" "$(cat "$home/sessionstart-park-session")" \
        "the verified CLI's session start must select the park"
      assert_contains "$out" "capable=0" "a registered verified session must be capable: $out"
    else
      assert_equals "" "$(cat "$home/sessionstart-park-session")" \
        "an unverified CLI's session start must not select the park"
      assert_contains "$out" "capable=1" "an unverified CLI must not be capable: $out"
      assert_contains "$out" "registered-capable=1" "an unverified CLI must not be capable even when registered: $out"
    fi
  done
  pass "the park is selected only for the verified codex-cli version"
}

test_single_flight_claim_admits_one_park() {
  local home out park_pid
  home=$(make_home single-flight opted-in)
  printf 'park\n' > "$home/arm-mode"
  : > "$home/arm-hold"
  # Each hook is waited for within a bound, so a second park that wrongly
  # arms fails the case instead of parking on the held arm forever.
  out=$(under_codex "$home" "$REGISTER"'
    bounded_wait() {  # <pid> <label>
      i=0
      while kill -0 "$1" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
      if kill -0 "$1" 2>/dev/null; then
        echo "$2=still-running"; kill "$1"; wait "$1"
      else
        wait "$1"; echo "$2=$?"
      fi
    }
    printf "%s" "$PAYLOAD" | "$PARK" > "$FM_HOME/first.out" 2>&1 &
    first=$!
    i=0
    until [ "$(jq -r ".outcome // empty" "$FM_HOME/state/.codex-park.json" 2>/dev/null)" = waiting ] \
      && [ -s "$FM_HOME/arm-ran" ]; do
      i=$((i + 1)); [ "$i" -lt 200 ] || { echo "first park never armed"; break; }
      sleep 0.05
    done
    echo "first=$first"
    printf "%s" "$PAYLOAD" | "$PARK" &
    bounded_wait "$!" second
    jq -r .pid "$FM_HOME/state/.codex-park.json" > "$FM_HOME/pid-after-second"
    rm -f "$FM_HOME/arm-hold"
    bounded_wait "$first" first-rc
  ' 2>&1)
  park_pid=$(printf '%s\n' "$out" | sed -n 's/^first=//p')
  [ -n "$park_pid" ] || fail "the first park did not start: $out"
  assert_not_contains "$out" "first park never armed" "fixture: $out"
  assert_contains "$out" "second=0" "a second Stop must yield to the live claim: $out"
  assert_equals "$park_pid" "$(cat "$home/pid-after-second")" "a second Stop must not replace the live park's record"
  assert_equals 1 "$(arm_count "$home")" "only one arm may run while a park holds the claim"
  assert_equals "pid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$home/arm-ran") model_free=1 owner=$park_pid" \
    "$(cat "$home/arm-ran")" "the arm must run model-free and bound to the park that owns it"
  assert_contains "$out" "first-rc=0" "the park must deliver its wake and exit cleanly: $out"
  assert_equals delivered "$(outcome "$home")" "the park must record the delivered wake"
  assert_equals 1 "$(queue_count "$home")" "exactly one native queue delivery must be made"
  assert_contains "$(cat "$home/queue.log")" "queue --thread $SESSION_ID --message Firstmate watcher wake: signal: fixture-task finished" \
    "the wake must reach this session's thread"
  assert_absent "$home/state/.codex-park-fallback" "a delivered wake must not latch fallback"
  assert_absent "$home/state/.codex-park.lock" "the park must release its claim on exit"
  pass "the single-flight claim admits one park, which delivers its wake through the native queue"
}

# A park that has delivered a wake still holds the claim until its EXIT
# cleanup. The holder here is that park's state: a live claim and a delivered
# record naming it, released a second after the woken turn's Stop starts.
# The holder records $1 while it holds the claim for $2 seconds, then records
# delivered and releases it, as a park finishing its queue call does.
test_stop_rearms_after_a_delivering_park_releases_its_claim() {
  local held=$1 hold=$2 home out holder
  home=$(make_home "$held-claim" opted-in)
  printf 'wake\n' > "$home/arm-mode"
  cat > "$home/holder.sh" <<'SH'
. "$1/fm-wake-lib.sh"
STATE=$FM_HOME/state
fm_lock_try_acquire "$STATE/.codex-park.lock" || exit 1
held() {
  jq -n --arg session "$SESSION_ID" --argjson pid "$$" --arg outcome "$1" \
    '{session:$session,pid:$pid,at:0,outcome:$outcome}' > "$STATE/.codex-park.json"
}
held "$2"
echo "$$" > "$FM_HOME/holder.pid"
sleep "$3"
held delivered
fm_lock_release "$STATE/.codex-park.lock"
SH
  out=$(under_codex "$home" "$REGISTER"'
    bash "$FM_HOME/holder.sh" "$(dirname "$PARK")" '"$held $hold"' &
    holder=$!
    i=0
    until [ -s "$FM_HOME/holder.pid" ]; do
      i=$((i + 1)); [ "$i" -lt 100 ] || { echo "holder never claimed"; break; }
      sleep 0.05
    done
    printf "%s" "$PAYLOAD" | "$PARK"; echo "stop=$?"
    wait "$holder"; echo "holder=$?"
  ' 2>&1)
  holder=$(cat "$home/holder.pid" 2>/dev/null)
  assert_not_contains "$out" "holder never claimed" "fixture: $out"
  assert_contains "$out" "holder=0" "fixture: the delivering holder must release its claim: $out"
  assert_contains "$out" "stop=0" "the woken turn's Stop must rearm and deliver cleanly: $out"
  assert_equals 1 "$(arm_count "$home")" "the woken turn's Stop must rearm once the delivering park releases its claim"
  assert_equals 1 "$(queue_count "$home")" "the rearmed park must deliver its own wake and no recovery notice"
  assert_equals delivered "$(outcome "$home")" "the rearmed park must record its delivered wake"
  [ "$(jq -r .pid "$home/state/.codex-park.json")" != "$holder" ] \
    || fail "the delivered record must belong to the rearmed park, not the earlier holder"
  pass "a Stop that meets a $held park's claim held ${hold}s waits for its release and rearms"
}

test_failed_queue_delivery_latches_fallback() {
  local home out
  home=$(make_home queue-failure opted-in)
  printf 'wake\n' > "$home/arm-mode"
  # The guard can latch fallback itself, so the latch is read before it runs.
  out=$(under_codex "$home" "$REGISTER"'
    printf "%s" "$PAYLOAD" | "$PARK"; echo "stop=$?"
    cat "$FM_HOME/state/.codex-park-fallback" > "$FM_HOME/latched-after-stop" 2>/dev/null
    printf "%s" "$PAYLOAD" | "$PARK" --guard; echo "guard=$?"
    "$PARK" --capable; echo "capable=$?"
  ' FM_FAKE_CODEX_QUEUE_RC=1 2>&1)
  assert_contains "$out" "stop=1" "a failed queue delivery must fail the park: $out"
  assert_equals delivery-failed "$(outcome "$home")" "the park must record the failed delivery"
  assert_equals "$SESSION_ID" "$(cat "$home/latched-after-stop")" \
    "a failed delivery must latch this session to foreground fallback"
  assert_contains "$out" "guard=2" "the next synchronous Stop must block on the latched fallback: $out"
  assert_contains "$out" "foreground fallback" "the guard must name the fallback: $out"
  assert_absent "$home/turnend-guard-ran" "the latched guard must answer itself rather than defer"
  assert_contains "$out" "capable=1" "a latched session must no longer report a capable park: $out"
  pass "a failed native queue delivery latches the session to foreground fallback"
}

test_latched_fallback_stays_quiet_without_supervision_need() {
  local home out
  home=$(make_home latched-idle opted-in)
  printf '%s' "$SESSION_ID" > "$home/state/.codex-park-fallback"
  rm -f "$home/state/fixture-task.meta"
  out=$(under_codex "$home" "$REGISTER"'
    printf "%s" "$PAYLOAD" | "$PARK" --guard; echo "guard=$?"
  ' 2>&1)
  assert_contains "$out" "guard=0" "a latched session with nothing to supervise must not block Stop: $out"
  assert_equals ran "$(cat "$home/turnend-guard-ran" 2>/dev/null)" "the latched idle guard must defer to the turn-end guard"
  pass "a latched fallback does not force a Stop turn when nothing needs supervision"
}

test_repeated_arm_failure_latches_fallback() {
  local home out
  home=$(make_home arm-failure opted-in)
  printf 'fail\n' > "$home/arm-mode"
  out=$(under_codex "$home" "$REGISTER"'
    printf "%s" "$PAYLOAD" | "$PARK"; echo "stop=$?"
  ' 2>&1)
  assert_contains "$out" "stop=1" "a repeatedly failing arm must fail the park: $out"
  assert_equals 2 "$(arm_count "$home")" "one failed arm must be retried exactly once"
  assert_equals 2 "$(queue_count "$home")" "each arm failure must be reported through the native queue"
  assert_contains "$(cat "$home/queue.log")" "attempt 1/2" "the first failure must be reported as retryable"
  assert_contains "$(cat "$home/queue.log")" "attempt 2/2" "the second failure must be reported"
  assert_equals failed "$(outcome "$home")" "the park must record the repeated failure"
  assert_equals "$SESSION_ID" "$(cat "$home/state/.codex-park-fallback" 2>/dev/null)" \
    "a repeated arm failure must latch this session to foreground fallback"
  pass "a repeated arm failure latches the session to foreground fallback"
}

# The real watcher bound to a park owner that a native teardown kills.
test_watcher_exits_when_its_park_owner_is_gone() {
  local home owner identity watcher i
  home=$(make_home owner-gone plain)
  rm -f "$home/state/fixture-task.meta"
  sleep 60 &
  owner=$!
  identity=$(fm_test_pid_identity "$owner") || fail "could not read the owner's identity"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_CODEX_PARK_OWNER_PID="$owner" FM_CODEX_PARK_OWNER_IDENTITY="$identity" \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
  watcher=$!
  sleep 2.5
  kill -0 "$watcher" 2>/dev/null \
    || fail "the watcher must keep running while its park owner lives: $(cat "$home/watch.out" "$home/watch.err")"
  kill "$owner" 2>/dev/null
  wait "$owner" 2>/dev/null
  i=0
  while kill -0 "$watcher" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$watcher" 2>/dev/null; then
    kill "$watcher" 2>/dev/null
    fail "the watcher outlived its park owner"
  fi
  wait "$watcher"
  expect_code 1 "$?" "the owner-gone watcher exit"
  assert_contains "$(cat "$home/watch.err")" "native Codex park owner is gone" "the watcher must name why it exited"
  pass "the watcher exits when the park owner bound to it is gone"
}

# The real host under the model-free Codex owner keeps one watcher across
# repeated quiet boundaries instead of ending its park, and its warm-compaction
# tick follows the restarted clock. The tick interval equals the park interval,
# so a tick left on the old clock never comes due again; the engine record is
# seeded only after a quiet boundary, so its compaction must run on the new
# clock. The engine stub fails, which still counts as an attempted compaction.
test_host_quiet_boundary_retains_the_watcher() {
  local home host first_watcher i key
  home=$(make_home quiet-boundary plain)
  printf 'claude sonnet\n' > "$home/config/supervision-host"
  printf 'idle-seconds=60\nmin-context-tokens=1000\n' > "$home/config/warm-compact"
  mkdir -p "$home/claude/projects/p"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":90000,"cache_creation_input_tokens":0}}}\n' \
    > "$home/claude/projects/p/warm-sess.jsonl"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/engine-calls"\nexit 1\n' "$home" > "$home/engine-stub"
  chmod +x "$home/engine-stub"
  env FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SUPERVISION_HOST_PRIMARY=codex FM_SUPERVISION_HOST_PARK_SECONDS=2 FM_CODEX_MODEL_FREE_PARK=1 \
    FM_WARM_COMPACT_TICK=2 CLAUDE_CONFIG_DIR="$home/claude" FM_SUPERVISION_ENGINE_CLAUDE_BIN="$home/engine-stub" \
    "$FAKE_CODEX" -c 'printf "%s\n" "$PPID" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" > "$FM_HOME/host.pid"
      exec "$1" park' _ "$ROOT/bin/fm-supervision-host.sh" > "$home/host.out" 2> "$home/host.err" &
  i=0
  until [ -s "$home/host.pid" ] && [ -s "$home/state/.watch.lock/pid" ]; do
    i=$((i + 1)); [ "$i" -lt 200 ] || fail "the host never started its watcher: $(cat "$home/host.out" "$home/host.err")"
    sleep 0.05
  done
  host=$(cat "$home/host.pid")
  first_watcher=$(cat "$home/state/.watch.lock/pid")
  i=0
  until grep -q 'quiet-boundary' "$home/state/.supervision-host.log" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 150 ] || fail "the host never logged a quiet boundary: $(cat "$home/host.out")"
    sleep 0.1
  done
  key=$(FM_HOME="$home" bash -c '. "$1"; . "$2"; fm_supervision_host_main_key "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/state") \
    || fail "fixture: no main-session key"
  printf 'engine=claude\nmodel=sonnet\nsession=warm-sess\nkey=%s\nturns=1\nconversation_cost=0\nended=%s\n' \
    "$key" $(($(date +%s) - 600)) > "$home/state/.supervision-host-engine"
  printf 'prompt\n' > "$home/state/.supervision-host-prompt"
  i=0
  until [ "$(grep -c 'quiet-boundary' "$home/state/.supervision-host.log" 2>/dev/null)" -ge 3 ] \
    && grep -q 'warm-compact	engine' "$home/state/.supervision-host.log" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 150 ] || break
    sleep 0.1
  done
  grep -q 'warm-compact	engine	failed' "$home/state/.supervision-host.log" 2>/dev/null \
    || fail "the warm-compaction tick did not run on the clock a quiet boundary restarted: $(cat "$home/state/.supervision-host.log")"
  assert_contains "$(cat "$home/engine-calls" 2>/dev/null)" "/compact" "the compaction must resume the engine conversation"
  kill -0 "$host" 2>/dev/null || fail "the host ended its park at a quiet boundary: $(cat "$home/host.out")"
  [ "$(grep -c 'quiet-boundary' "$home/state/.supervision-host.log" 2>/dev/null)" -ge 3 ] \
    || fail "the host never logged three quiet boundaries: $(cat "$home/state/.supervision-host.log" 2>/dev/null)"
  assert_equals "$first_watcher" "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" \
    "the same watcher must survive the quiet boundaries"
  kill -0 "$first_watcher" 2>/dev/null || fail "the retained watcher must still be running"
  assert_not_contains "$(cat "$home/host.out")" "cycle boundary" "a quiet boundary must produce no model output"
  kill "$host" 2>/dev/null
  i=0
  while kill -0 "$host" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  pass "the model-free Codex host keeps one watcher across quiet boundaries with no model output and warm-compacts on the restarted clock"
}

test_unconfigured_home_keeps_the_foreground_checkpoint
test_version_gate_selects_only_the_verified_cli
test_single_flight_claim_admits_one_park
test_stop_rearms_after_a_delivering_park_releases_its_claim delivered 1
test_stop_rearms_after_a_delivering_park_releases_its_claim delivering 4
test_failed_queue_delivery_latches_fallback
test_latched_fallback_stays_quiet_without_supervision_need
test_repeated_arm_failure_latches_fallback
test_watcher_exits_when_its_park_owner_is_gone
test_host_quiet_boundary_retains_the_watcher
