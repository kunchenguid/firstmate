#!/usr/bin/env bash
# tests/fm-browser-reaper.test.sh - contract tests for the leaked browser-stack
# reaper (bin/fm-browser-reaper.sh).
#
# chrome-devtools-axi runs its bridge detached at ppid 1 and keeps ONE bridge
# per session name for the whole machine, so a leaked headless Chrome stack sits
# in no worker's process tree and can only be attributed by the session name
# bin/fm-spawn.sh assigns it. The reaper turns that name into an owner and kills
# the stack, and the REFUSALS are the primary value here: the captain's editor
# runs seven-plus chrome-devtools-mcp servers of its own, and taking one of
# those out would be worse than the leak this fixes. Every case below drives the
# script's public interface against REAL processes, never a stubbed classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAPER="$ROOT/bin/fm-browser-reaper.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-reaper-tests)

# Fixture pids are recorded in a FILE, not a shell array: every starter below is
# called inside a command substitution, and an array appended to in that subshell
# is lost to the parent - which would leave every fixture process running after
# the suite exits.
FAKE_PIDS_FILE="$TMP_ROOT/fake-pids"
: > "$FAKE_PIDS_FILE"

note_fake_pid() {  # <pid>
  printf '%s\n' "$1" >> "$FAKE_PIDS_FILE"
}

cleanup_fakes() {
  local pid child
  [ -f "$FAKE_PIDS_FILE" ] || return 0
  # Children first, then the recorded process, so nothing is left reparented.
  while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    for child in $(ps -eo pid=,ppid= | awk -v p="$pid" '$2 == p { print $1 }'); do
      kill -KILL "$child" 2>/dev/null || true
    done
    kill -KILL "$pid" 2>/dev/null || true
  done < "$FAKE_PIDS_FILE"
  : > "$FAKE_PIDS_FILE"
}
trap 'cleanup_fakes; fm_test_cleanup' EXIT
trap 'cleanup_fakes; fm_test_cleanup; exit 130' INT
trap 'cleanup_fakes; fm_test_cleanup; exit 143' TERM

# The fixture body every fake process runs. Kept as an inline -c program rather
# than a script file on purpose: a long-running `bash somefile` re-reads that
# file as it executes, so a fixture backed by a file under the suite's temp root
# dies unpredictably the moment cleanup removes it.
IDLE_BODY='while :; do sleep 0.5; done'

# start_proc <case-dir> <argv-marker> [args...]
# Launch a real long-lived process whose argv contains <argv-marker>. The
# reaper's whole identification rests on reading a live process's own argv, so a
# fixture that faked that read would prove nothing.
start_proc() {
  local dir=$1 marker=$2
  shift 2
  # Detach every fd: a backgrounded process that inherits the enclosing command
  # substitution's stdout keeps that pipe open, and the substitution then blocks
  # forever waiting for an EOF the fixture will never send.
  bash -c "$IDLE_BODY" "$dir/$marker" "$@" >/dev/null 2>&1 </dev/null &
  local pid=$!
  note_fake_pid "$pid"
  printf '%s\n' "$pid"
}

# start_stack <case-dir>: a bridge with two children - one carrying the isolated
# puppeteer profile every Chrome process in a real stack is launched with, and
# one bystander carrying no stack marker at all. Echoes "<bridge> <child> <bystander>".
start_stack() {
  local dir=$1 pid child_cmd bystander_cmd
  child_cmd="bash -c '$IDLE_BODY' chrome-stack-child --headless=new --user-data-dir=/tmp/puppeteer_dev_chrome_profile-TEST"
  bystander_cmd="bash -c '$IDLE_BODY' GoogleUpdater --wake-all"
  bash -c "$child_cmd >/dev/null 2>&1 & $bystander_cmd >/dev/null 2>&1 & $IDLE_BODY" \
    "$dir/node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js" \
    >/dev/null 2>&1 </dev/null &
  pid=$!
  note_fake_pid "$pid"
  # Wait for both children to exist before returning, so a case never races the
  # subtree it is about to assert on.
  local waited=0
  while [ "$waited" -lt 100 ]; do
    if [ "$(ps -eo ppid= | tr -d ' ' | grep -c "^$pid\$")" -ge 2 ]; then
      break
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  local kids child="" bystander=""
  kids=$(ps -eo pid=,ppid= | awk -v p="$pid" '$2 == p { print $1 }')
  local k argv
  for k in $kids; do
    note_fake_pid "$k"
    argv=$(ps -ww -p "$k" -o command= 2>/dev/null || true)
    case "$argv" in
      *puppeteer_dev_chrome_profile-*) child=$k ;;
      *GoogleUpdater*) bystander=$k ;;
    esac
  done
  printf '%s %s %s\n' "$pid" "$child" "$bystander"
}

# session_name_for <task-id>: the session name THIS home binds to that task,
# asked of the script itself rather than reconstructed here, so the test cannot
# drift from the derivation bin/fm-spawn.sh and the reaper actually share.
session_name_for() {  # <task-id>
  "$REAPER" --session-name "$1"
}

# register <case-dir> <session> <pid>: write chrome-devtools-axi's own registry
# record, the first of the reaper's two identification signals.
register() {
  local dir=$1 session=$2 pid=$3
  mkdir -p "$dir/sessions/$session"
  printf '{"pid":%s,"port":9999}\n' "$pid" > "$dir/sessions/$session/bridge.pid"
}

run_reaper() {  # <case-dir> <args...>
  local dir=$1
  shift
  FM_BROWSER_SESSIONS_ROOT="$dir/sessions" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_BROWSER_REAP_GRACE_SECS=1 \
    "$REAPER" "$@"
}

new_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/sessions" "$dir/state" "$dir/fakebin"
  printf '%s\n' "$dir"
}

# A chrome-devtools-axi stub that really removes the session record and kills
# the bridge, standing in for the tool's own supported shutdown.
install_working_stop() {  # <case-dir>
  cat > "$1/fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 0
rec="$FM_BROWSER_SESSIONS_ROOT/${CHROME_DEVTOOLS_AXI_SESSION:?}/bridge.pid"
pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$rec" 2>/dev/null)
[ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
rm -f "$rec"
printf 'status: stopped\n'
SH
  chmod +x "$1/fakebin/chrome-devtools-axi"
}

# A chrome-devtools-axi stub whose stop silently fails, forcing the escalation path.
install_broken_stop() {  # <case-dir>
  cat > "$1/fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/fakebin/chrome-devtools-axi"
}

wait_gone() {  # <pid>
  local pid=$1 waited=0
  while [ "$waited" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
    waited=$((waited + 1))
  done
  return 1
}

# --- identification ---------------------------------------------------------

test_identifies_a_real_bridge() {
  local dir pid out
  dir=$(new_case identify-bridge)
  pid=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  register "$dir" "$(session_name_for task-a)" "$pid"

  out=$(run_reaper "$dir" --identify "$pid") \
    || fail "identify: refused a process that carries both signals"
  assert_contains "$out" "identified:" "identify: expected a positive verdict"
  assert_contains "$out" "$(session_name_for task-a)" "identify: expected the owning session named"
  pass "identify accepts a bridge that has BOTH a session record and the bridge argv"
}

# THE safety property: the captain's editor keeps seven-plus chrome-devtools-mcp
# servers alive. They must never be identifiable, so they can never be reaped.
test_refuses_antigravity_autoconnect_server() {
  local dir pid out rc
  dir=$(new_case refuse-antigravity)
  pid=$(start_proc "$dir" npm-exec-chrome-devtools-mcp \
    --autoConnect --no-usage-statistics --no-performance-crux)

  set +e
  out=$(run_reaper "$dir" --identify "$pid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "identify: an Antigravity --autoConnect server was IDENTIFIED"
  assert_contains "$out" "refused:" "identify: expected an explicit refusal"
  assert_not_contains "$out" "identified:" "identify: must not claim an editor's server"

  # And it survives a reap aimed at its own session name.
  run_reaper "$dir" --reap task-a >/dev/null 2>&1
  kill -0 "$pid" 2>/dev/null || fail "reap: an Antigravity --autoConnect server was KILLED"
  pass "an Antigravity --autoConnect chrome-devtools-mcp server is refused, never reaped"
}

test_refuses_registry_record_naming_a_non_bridge() {
  local dir pid out rc
  dir=$(new_case refuse-recycled-pid)
  # Signal 1 present, signal 2 absent: exactly a recycled pid, where trusting the
  # registry alone would kill an unrelated process.
  pid=$(start_proc "$dir" some-unrelated-daemon)
  register "$dir" "$(session_name_for task-a)" "$pid"

  set +e
  out=$(run_reaper "$dir" --identify "$pid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "identify: trusted a session record against a non-bridge pid"
  assert_contains "$out" "refused:" "identify: expected refusal on a recycled pid"

  out=$(run_reaper "$dir" --reap task-a 2>&1 || true)
  assert_contains "$out" "REFUSED" "reap: expected a visible refusal, not a silent skip"
  kill -0 "$pid" 2>/dev/null || fail "reap: killed a pid the registry named but argv disowned"
  pass "a session record naming a non-bridge pid is refused (registry alone is not enough)"
}

test_refuses_bridge_argv_with_no_registry_record() {
  local dir pid rc
  dir=$(new_case refuse-unregistered)
  # Signal 2 present, signal 1 absent: name matching alone must not authorize a kill.
  pid=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)

  set +e
  run_reaper "$dir" --identify "$pid" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "identify: matched on argv alone with no session record"
  kill -0 "$pid" 2>/dev/null || fail "reap: killed an unregistered process"
  pass "bridge-looking argv with no session record is refused (argv alone is not enough)"
}

# --- detection (bin/fm-bootstrap.sh's session-start line) -------------------

test_detect_is_silent_with_no_stacks() {
  local dir out
  dir=$(new_case detect-silent-empty)
  out=$(run_reaper "$dir" --detect)
  [ -z "$out" ] || fail "detect: printed something with no registered sessions:"$'\n'"$out"
  pass "detect prints NOTHING when no browser stack is registered"
}

test_detect_is_silent_while_the_owning_task_lives() {
  local dir pid out
  dir=$(new_case detect-silent-live-task)
  pid=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  register "$dir" "$(session_name_for task-a)" "$pid"
  : > "$dir/state/task-a.meta"

  out=$(FM_BROWSER_OWNED_GRACE_SECS=0 run_reaper "$dir" --detect)
  [ -z "$out" ] || fail "detect: reported a stack whose task is still live:"$'\n'"$out"
  pass "detect prints NOTHING while the owning task is still live"
}

test_detect_reports_a_leak_when_the_task_is_gone() {
  local dir pid out
  dir=$(new_case detect-leak)
  pid=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  register "$dir" "$(session_name_for task-a)" "$pid"
  # No state/task-a.meta: the task is gone and its browser outlived it.

  out=$(FM_BROWSER_OWNED_GRACE_SECS=0 run_reaper "$dir" --detect)
  assert_contains "$out" "BROWSER_LEAK:" "detect: expected the actionable diagnostic prefix"
  assert_contains "$out" "task-a" "detect: expected the leaked task named"
  assert_contains "$out" "--reap task-a" "detect: expected the exact remediation command"
  pass "detect reports BROWSER_LEAK when a stack outlives its task"
}

test_detect_honors_the_owned_grace_floor() {
  local dir pid out
  dir=$(new_case detect-grace)
  pid=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  register "$dir" "$(session_name_for task-a)" "$pid"

  # The default 60s floor keeps a stack a just-spawned task has not yet recorded
  # from being called leaked.
  out=$(run_reaper "$dir" --detect)
  [ -z "$out" ] || fail "detect: reported a seconds-old stack under the grace floor:"$'\n'"$out"
  pass "detect holds a brand-new stack under the owned-grace floor"
}

test_detect_reports_an_unattributed_stack_only_once_it_is_old() {
  local dir pid out
  dir=$(new_case detect-unattributed)
  pid=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  # A session name no task claims: the honest rule for these is age, and they are
  # reported only, never reaped.
  register "$dir" some-ad-hoc-name "$pid"

  out=$(run_reaper "$dir" --detect)
  [ -z "$out" ] || fail "detect: reported a young unattributed stack:"$'\n'"$out"

  out=$(FM_BROWSER_LEAK_AGE_SECS=0 run_reaper "$dir" --detect)
  assert_contains "$out" "BROWSER_LEAK:" "detect: expected an aged unattributed stack reported"
  assert_contains "$out" "unattributed" "detect: expected the unattributed classification"
  assert_not_contains "$out" "--reap" "detect: must not offer --reap for an unowned session"
  pass "detect reports an unattributed stack only past the age floor, and never offers --reap"
}

test_detect_skips_another_firstmate_homes_session() {
  local dir pid out
  dir=$(new_case detect-other-home)
  pid=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  # chrome-devtools-axi's session registry is ONE machine-wide namespace, so a
  # sibling home's live task is visible here. Its task id is not in THIS home's
  # state/, so without the home tag it would read as an unowned leak and the
  # printed remediation would kill a live sibling's browser.
  register "$dir" "fm-firstmate-deadbeef-their-task" "$pid"

  out=$(FM_BROWSER_OWNED_GRACE_SECS=0 FM_BROWSER_LEAK_AGE_SECS=0 run_reaper "$dir" --detect)
  [ -z "$out" ] || fail "detect: reported another firstmate home's session:"$'\n'"$out"

  out=$(run_reaper "$dir" --report)
  assert_contains "$out" "another firstmate home" "report: expected the cross-home classification"
  pass "detect stays silent on another firstmate home's session at any age"
}

# --- reaping ----------------------------------------------------------------

test_reap_prefers_the_tools_own_stop() {
  local dir pid out
  dir=$(new_case reap-graceful)
  install_working_stop "$dir"
  pid=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  register "$dir" "$(session_name_for task-a)" "$pid"

  out=$(PATH="$dir/fakebin:$PATH" run_reaper "$dir" --reap task-a 2>&1)
  assert_contains "$out" "closed" "reap: expected a close outcome"
  assert_not_contains "$out" "signalling its process tree" \
    "reap: escalated even though the tool's own stop worked"
  wait_gone "$pid" || fail "reap: the bridge survived a working stop"
  pass "reap closes through chrome-devtools-axi's own stop when that works"
}

test_reap_escalates_to_the_stack_tree_and_skips_bystanders() {
  local dir stack bridge child bystander out
  dir=$(new_case reap-escalate)
  install_broken_stop "$dir"
  stack=$(start_stack "$dir")
  bridge=${stack%% *}; stack=${stack#* }
  child=${stack%% *}; bystander=${stack#* }
  [ -n "$child" ] || fail "fixture: no marked stack child was started"
  [ -n "$bystander" ] || fail "fixture: no unmarked bystander was started"
  register "$dir" "$(session_name_for task-a)" "$bridge"

  out=$(PATH="$dir/fakebin:$PATH" run_reaper "$dir" --reap task-a 2>&1)
  assert_contains "$out" "signalling its process tree" "reap: expected escalation after a failed stop"
  assert_contains "$out" "SKIP pid $bystander" "reap: expected the unmarked bystander skipped by pid"

  wait_gone "$bridge" || fail "reap: the bridge survived escalation"
  wait_gone "$child" || fail "reap: the marked stack child survived escalation"
  kill -0 "$bystander" 2>/dev/null \
    || fail "reap: killed an unmarked bystander that merely sat in the stack's process tree"
  pass "reap escalates to the stack's own tree and refuses an unmarked bystander inside it"
}

test_reap_never_touches_another_tasks_stack() {
  local dir mine theirs
  dir=$(new_case reap-scoped)
  install_broken_stop "$dir"
  mine=$(start_proc "$dir" node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  theirs=$(start_proc "$dir" other/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js)
  register "$dir" "$(session_name_for task-a)" "$mine"
  register "$dir" "$(session_name_for task-b)" "$theirs"

  PATH="$dir/fakebin:$PATH" run_reaper "$dir" --reap task-a >/dev/null 2>&1
  wait_gone "$mine" || fail "reap: did not reap the named task's own stack"
  kill -0 "$theirs" 2>/dev/null || fail "reap: reaped a DIFFERENT task's live browser stack"
  pass "reap acts only on the named task's session, never a sibling task's stack"
}

test_reap_of_an_absent_session_is_a_silent_no_op() {
  local dir out rc
  dir=$(new_case reap-noop)
  set +e
  out=$(run_reaper "$dir" --reap task-none 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "reap: a task with no browser stack should exit 0, got $rc"
  [ -z "$out" ] || fail "reap: expected silence for a task with no stack:"$'\n'"$out"
  pass "reap of a task that never opened a browser is a silent no-op"
}

test_identifies_a_real_bridge
test_refuses_antigravity_autoconnect_server
test_refuses_registry_record_naming_a_non_bridge
test_refuses_bridge_argv_with_no_registry_record
test_detect_is_silent_with_no_stacks
test_detect_is_silent_while_the_owning_task_lives
test_detect_reports_a_leak_when_the_task_is_gone
test_detect_honors_the_owned_grace_floor
test_detect_reports_an_unattributed_stack_only_once_it_is_old
test_detect_skips_another_firstmate_homes_session
test_reap_prefers_the_tools_own_stop
test_reap_escalates_to_the_stack_tree_and_skips_bystanders
test_reap_never_touches_another_tasks_stack
test_reap_of_an_absent_session_is_a_silent_no_op
cleanup_fakes
