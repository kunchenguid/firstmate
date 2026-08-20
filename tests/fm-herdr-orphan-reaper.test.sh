#!/usr/bin/env bash
# tests/fm-herdr-orphan-reaper.test.sh - unit tests for the orphaned Herdr pane
# reaper (bin/fm-herdr-orphan-reaper.sh).
#
# These tests use a fake herdr CLI to exercise the reaper's safety refusals
# and orphan detection without touching any real Herdr session.
# The safety refusals are the primary value: a test proving it refuses to
# close a claimed pane, a live-agent pane, and another home's pane is worth
# more than a test proving it closes an orphan.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

herdr_forget_inherited_pane

TMP_ROOT=$(fm_test_tmproot fm-herdr-orphan-reaper-tests)

# Build a self-contained fake herdr CLI that models workspaces, tabs, panes,
# and agent status for the reaper's read-only queries.
# The fake supports: workspace list, tab list, pane get, agent get, pane close.
make_reaper_fakebin() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_HERDR_STATE:?}"
LOG="${FM_HERDR_LOG:-/dev/null}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

# Strip --session flag.
args=()
i=0
all_args=("$@")
while [ "$i" -lt "${#all_args[@]}" ]; do
  if [ "${all_args[$i]}" = "--session" ] && [ "$((i + 1))" -lt "${#all_args[@]}" ]; then
    i=$((i + 2))
    continue
  fi
  args+=("${all_args[$i]}")
  i=$((i + 1))
done
set -- "${args[@]}"

case "${1:-}:${2:-}:${3:-}" in
  status:--json:*)
    printf '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true}}\n'
    ;;
  workspace:list:*)
    cat "$STATE/workspaces.json"
    ;;
  tab:list:*)
    ws=""
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --workspace) ws=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$ws" ] && [ -f "$STATE/tabs-$ws.json" ]; then
      cat "$STATE/tabs-$ws.json"
    else
      printf '{"result":{"tabs":[]}}\n'
    fi
    ;;
  pane:get:*)
    pane_id=$3
    if [ -f "$STATE/pane-$pane_id.json" ]; then
      cat "$STATE/pane-$pane_id.json"
    else
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"},"id":"cli:pane:get"}\n' "$pane_id"
      exit 1
    fi
    ;;
  pane:list:*)
    ws=""
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --workspace) ws=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$ws" ] && [ -f "$STATE/panes-$ws.json" ]; then
      cat "$STATE/panes-$ws.json"
    else
      printf '{"result":{"panes":[],"type":"pane_list"}}\n'
    fi
    ;;
  agent:get:*)
    pane_id=$3
    # A fail marker forces a CLI error with NO output (simulates socket/server failure).
    if [ -f "$STATE/agent-fail-$pane_id" ]; then
      exit 1
    fi
    if [ -f "$STATE/agent-$pane_id.json" ]; then
      cat "$STATE/agent-$pane_id.json"
    else
      printf '{"error":{"code":"agent_not_found","message":"no agent for pane %s"},"id":"cli:agent:get"}\n' "$pane_id"
      exit 1
    fi
    ;;
  pane:close:*)
    pane_id=$3
    printf '{"id":"cli:pane:close","result":{}}\n'
    printf '%s\n' "$pane_id" >> "$STATE/closed-panes.log"
    ;;
  pane:process-info:*)
    pane_id=$4
    if [ -f "$STATE/process-info-$pane_id.json" ]; then
      cat "$STATE/process-info-$pane_id.json"
    else
      printf '{"result":{"process_info":{"pane_id":"%s"}},"type":"pane_process_info"}\n' "$pane_id"
    fi
    ;;
  session:list:*)
    printf '{"sessions":[{"name":"test-session","running":true,"socket_path":"/tmp/test.sock"}]}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"

  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-p" ] && [ "$2" = "99999" ]; then
  echo "Fri Jan  1 00:00:00 2000"
  exit 0
fi
if [ "$1" = "-o" ] && [ "$2" = "comm=" ] && [ "$3" = "-p" ]; then
  if [ "$4" = "99999" ]; then exit 1; fi
  echo "claude"
  exit 0
fi
if [ "$1" = "-o" ] && [ "$2" = "args=" ] && [ "$3" = "-p" ]; then
  echo "claude"
  exit 0
fi
exec /bin/ps "$@"
SH
  chmod +x "$fb/ps"

  printf '%s\n' "$fb"
}

# setup_test: create a complete test fixture with fake herdr state.
# Sets test-global variables TDIR, HERDR_STATE, and prepends fakebin to PATH.
setup_test() {
  local name=$1
  TDIR="$TMP_ROOT/$name"
  HERDR_STATE="$TDIR/herdr-state"
  mkdir -p "$TDIR/home/state" "$TDIR/home/config" "$HERDR_STATE"
  printf 'herdr\n' > "$TDIR/home/config/backend"
  local fb
  fb=$(make_reaper_fakebin "$TDIR")
  export FM_HOME="$TDIR/home"
  export FM_ROOT="$ROOT"
  export FM_STATE_OVERRIDE="$TDIR/home/state"
  export FM_CONFIG_OVERRIDE="$TDIR/home/config"
  export FM_FAKE_HERDR_STATE="$HERDR_STATE"
  export FM_HERDR_LOG="$TDIR/herdr.log"
  export HERDR_SESSION="test-session"
  export PATH="$fb:$PATH"
}

seed_workspace() {
  local ws_id=$1 ws_label=$2
  cat > "$HERDR_STATE/workspaces.json" <<JSON
{"result":{"type":"workspace_list","workspaces":[{"workspace_id":"$ws_id","label":"$ws_label","active_tab_id":"${ws_id}:t1","pane_count":1,"tab_count":1}]}}
JSON
}

seed_workspace_multi() {
  local entries="" sep=""
  while [ "$#" -ge 2 ]; do
    local ws_id=$1 ws_label=$2
    shift 2
    entries="${entries}${sep}{\"workspace_id\":\"$ws_id\",\"label\":\"$ws_label\",\"active_tab_id\":\"${ws_id}:t1\",\"pane_count\":1,\"tab_count\":1}"
    sep=","
  done
  cat > "$HERDR_STATE/workspaces.json" <<JSON
{"result":{"type":"workspace_list","workspaces":[$entries]}}
JSON
}

seed_tab() {
  local ws_id=$1 tab_id=$2 label=$3
  local file="$HERDR_STATE/tabs-$ws_id.json"
  if [ ! -f "$file" ]; then
    printf '{"result":{"tabs":[]}}\n' > "$file"
  fi
  local current
  current=$(cat "$file")
  printf '%s' "$current" | jq --arg tid "$tab_id" --arg lbl "$label" \
    '.result.tabs += [{"tab_id": $tid, "label": $lbl, "focused": false}]' > "$file"
}

seed_pane() {
  local pane_id=$1 tab_id=$2 ws_id=$3
  cat > "$HERDR_STATE/pane-$pane_id.json" <<JSON
{"id":"cli:pane:get","result":{"pane":{"pane_id":"$pane_id","tab_id":"$tab_id","workspace_id":"$ws_id","agent_status":"unknown","cwd":"/tmp"},"type":"pane_info"}}
JSON
  local panes_file="$HERDR_STATE/panes-$ws_id.json"
  if [ ! -f "$panes_file" ]; then
    printf '{"result":{"panes":[],"type":"pane_list"}}\n' > "$panes_file"
  fi
  local current
  current=$(cat "$panes_file")
  printf '%s' "$current" | jq --arg pid "$pane_id" --arg tid "$tab_id" --arg wid "$ws_id" \
    '.result.panes += [{"pane_id": $pid, "tab_id": $tid, "workspace_id": $wid, "agent_status": "unknown", "cwd": "/tmp"}]' > "$panes_file"
}

seed_agent() {
  local pane_id=$1 agent_status=$2 agent_name=${3:-agy}
  cat > "$HERDR_STATE/agent-$pane_id.json" <<JSON
{"id":"cli:agent:get","result":{"agent":{"agent":"$agent_name","agent_status":"$agent_status","pane_id":"$pane_id"}}}
JSON
}

seed_meta() {
  local task_id=$1 pane_id=$2
  fm_write_meta "$TDIR/home/state/${task_id}.meta" \
    "window=test-session:$pane_id" \
    "endpoint_task_id=$task_id" \
    "worktree=/tmp/test" \
    "project=/tmp/test" \
    "harness=agy" \
    "kind=ship" \
    "backend=herdr" \
    "herdr_session=test-session" \
    "herdr_workspace_id=wA" \
    "herdr_tab_id=wA:t1" \
    "herdr_pane_id=$pane_id"
}

seed_process_info() {
  local pane_id=$1 shell_pid=$2
  cat > "$HERDR_STATE/process-info-$pane_id.json" <<JSON
{"result":{"process_info":{"pane_id":"$pane_id","shell_pid":$shell_pid}},"type":"pane_process_info"}
JSON
}

seed_agent_fail() {
  local pane_id=$1
  touch "$HERDR_STATE/agent-fail-$pane_id"
}

SAVE_PATH="$PATH"

# --- Test 1: refuses to close a pane claimed by meta -------------------------
PATH="$SAVE_PATH"
setup_test "claimed"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-my-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_meta "my-task" "wA:p1"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "claimed pane: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "claimed pane: should report SKIP for claimed pane"
assert_contains "$out" "claimed by meta" "claimed pane: should mention claimed by meta"
assert_not_contains "$out" "REAPER: ORPHAN" "claimed pane: should not report any orphans"
pass "refuses to close a pane claimed by meta"

# --- Test 2: refuses to close a pane with a live agent (working) -------------
PATH="$SAVE_PATH"
setup_test "live-working"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-active-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_agent "wA:p1" "working"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "live agent working: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "live agent working: should report SKIP"
assert_contains "$out" "live agent" "live agent working: should mention live agent"
assert_not_contains "$out" "REAPER: ORPHAN" "live agent working: should not report any orphans"
pass "refuses to close a pane with a live agent (working)"

# --- Test 3: refuses to close a pane with a live agent (blocked) -------------
PATH="$SAVE_PATH"
setup_test "live-blocked"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-blocked-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_agent "wA:p1" "blocked"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "live agent blocked: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "live agent blocked: should report SKIP"
assert_contains "$out" "live agent" "live agent blocked: should mention live agent"
assert_not_contains "$out" "REAPER: ORPHAN" "live agent blocked: should not report any orphans"
pass "refuses to close a pane with a live agent (blocked)"

# --- Test 4: another home's pane is invisible --------------------------------
PATH="$SAVE_PATH"
setup_test "other-home"
seed_workspace_multi "wA" "firstmate" "wB" "2ndmate-lucie"
seed_tab "wA" "wA:t1" "fm-primary-orphan"
seed_pane "wA:p1" "wA:t1" "wA"
seed_process_info "wA:p1" 99999

# Primary home should find the orphan.
out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
assert_contains "$out" "ORPHAN wA:p1" "other-home: primary should see its own orphan"

# Secondmate home should NOT see the primary's pane.
mkdir -p "$TDIR/home2/state" "$TDIR/home2/config"
printf 'herdr\n' > "$TDIR/home2/config/backend"
printf 'lucie\n' > "$TDIR/home2/.fm-secondmate-home"
export FM_HOME="$TDIR/home2"
export FM_STATE_OVERRIDE="$TDIR/home2/state"
export FM_CONFIG_OVERRIDE="$TDIR/home2/config"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
assert_not_contains "$out" "ORPHAN wA:p1" "other-home: secondmate must not see primary's orphan"
assert_not_contains "$out" "REAPER: ORPHAN" "other-home: secondmate should find no orphans"
pass "another home's panes are invisible (home-scoped)"

# --- Test 5: done agent is live (done is not gone) --------------------------
PATH="$SAVE_PATH"
setup_test "done-is-live"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-done-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_agent "wA:p1" "done"
seed_process_info "wA:p1" 99999

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "done agent: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "done agent: should report SKIP"
assert_contains "$out" "live agent (status: done)" "done agent: should mention done status"
assert_not_contains "$out" "REAPER: ORPHAN" "done agent: should not report any orphans"
pass "done agent is live (done is not gone; task owns pane until cleanup)"

# --- Test 6: non-fm- tabs are ignored (captain's own terminals) --------------
PATH="$SAVE_PATH"
setup_test "captain-tab"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "apex-root"
seed_pane "wA:p1" "wA:t1" "wA"
seed_tab "wA" "wA:t2" "my-project"
seed_pane "wA:p2" "wA:t2" "wA"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "captain tab: expected exit 0, got $rc"
[ -z "$out" ] || fail "captain tab: expected silent exit (no fm- tabs), got: $out"
pass "non-fm- tabs are ignored (captain's own terminals, silent)"

# --- Test 7: --close actually closes orphans (with lock and no agent) --------
PATH="$SAVE_PATH"
setup_test "close"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-dead-task"
seed_pane "wA:p1" "wA:t1" "wA"
# No agent seeded - a pane with no registered agent is the genuine orphan case.
seed_process_info "wA:p1" 99999
# Seed a session lock (--close requires it).
printf '%s\n' "$$" > "$TDIR/home/state/.lock"
# Seed at least one meta so the self-check does not trip.
seed_meta "other-active-task" "wA:pOther"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --close 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "close mode: expected exit 0, got $rc"
assert_contains "$out" "ORPHAN wA:p1" "close mode: should detect the orphan"
assert_contains "$out" "CLOSED wA:p1" "close mode: should report closure"
pass "--close actually closes orphans (lock held, no agent)"

# --- Test 8: non-herdr backend exits cleanly ---------------------------------
PATH="$SAVE_PATH"
setup_test "non-herdr"
printf 'tmux\n' > "$TDIR/home/config/backend"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "non-herdr: expected exit 0, got $rc"
[ -z "$out" ] || fail "non-herdr: expected silent exit, got: $out"
pass "non-herdr backend exits cleanly (silent)"

# --- Test 9: mixed panes - claimed, orphan, captain, live-agent, done --------
PATH="$SAVE_PATH"
setup_test "mixed"
seed_workspace "wA" "firstmate"

seed_tab "wA" "wA:t1" "fm-claimed-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_meta "claimed-task" "wA:p1"

# No agent = genuine orphan (deregistered)
seed_tab "wA" "wA:t2" "fm-orphan-task"
seed_pane "wA:p2" "wA:t2" "wA"
seed_process_info "wA:p2" 99999

seed_tab "wA" "wA:t3" "my-shell"
seed_pane "wA:p3" "wA:t3" "wA"

seed_tab "wA" "wA:t4" "fm-live-task"
seed_pane "wA:p4" "wA:t4" "wA"
seed_agent "wA:p4" "working"

# Done agent = still live (done is not gone)
seed_tab "wA" "wA:t5" "fm-done-task"
seed_pane "wA:p5" "wA:t5" "wA"
seed_agent "wA:p5" "done"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "mixed: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "mixed: should skip claimed pane"
assert_contains "$out" "ORPHAN wA:p2" "mixed: should detect orphan pane (no agent)"
assert_not_contains "$out" "wA:p3" "mixed: captain's tab should be invisible"
assert_contains "$out" "SKIP wA:p4" "mixed: should skip live agent pane (working)"
assert_contains "$out" "SKIP wA:p5" "mixed: should skip done agent pane (done is live)"
assert_contains "$out" "1 orphaned pane" "mixed: should count exactly 1 orphan"
pass "mixed panes: correctly classifies claimed, orphan, captain, working, and done"

# --- Test 10: pane with no agent at all (deregistered) is orphan -------------
PATH="$SAVE_PATH"
setup_test "no-agent"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-old-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_process_info "wA:p1" 99999

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "no agent: expected exit 0, got $rc"
assert_contains "$out" "ORPHAN wA:p1" "no agent: should detect orphan with no agent"
pass "pane with no agent at all (deregistered) is still orphan"

# --- Test 11: refuses to close its own supervisor pane -----------------------
PATH="$SAVE_PATH"
setup_test "self-owned"
seed_workspace "wA" "2ndmate-lucie"
seed_tab "wA" "wA:t1" "fm-lucie"
seed_pane "wA:p1" "wA:t1" "wA"
seed_agent "wA:p1" "done"  # would also refuse as live agent; supervisor check fires first

printf 'lucie\n' > "$TDIR/home/.fm-secondmate-home"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "self-owned pane: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "self-owned pane: should report SKIP"
assert_contains "$out" "this home's own supervisor pane" "self-owned pane: should mention own supervisor pane"
assert_not_contains "$out" "REAPER: ORPHAN" "self-owned pane: should not report any orphans"
pass "refuses to close its own supervisor pane"

# --- Test 12: refuses to close a pane that is too young ----------------------
PATH="$SAVE_PATH"
setup_test "young-pane"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-new-task"
seed_pane "wA:p1" "wA:t1" "wA"
# No agent seeded - the pane must reach the age check to test the refusal.

# Launch a fresh process so its lstart is within the last second.
sleep 300 &
YOUNG_PID=$!
seed_process_info "wA:p1" "$YOUNG_PID"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "young pane: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "young pane: should report SKIP"
assert_contains "$out" "pane is too young" "young pane: should mention pane is too young"
assert_not_contains "$out" "REAPER: ORPHAN" "young pane: should not report any orphans"
kill "$YOUNG_PID" 2>/dev/null || true; wait "$YOUNG_PID" 2>/dev/null || true
pass "refuses to close a pane that is too young (startup race immunity)"

# --- Test 13: refuses to close a pane whose age cannot be determined --------
PATH="$SAVE_PATH"
setup_test "undeterminable-age"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-undeterminable"
seed_pane "wA:p1" "wA:t1" "wA"
# No agent seeded - the pane must reach the age check to test the refusal.

# The default mock returns process_info without a shell_pid, simulating failure to determine age.
# No seed_process_info call is needed here.

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "undeterminable age: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "undeterminable age: should report SKIP"
assert_contains "$out" "pane is too young (unknowns < 15s)" "undeterminable age: should mention unknown age"
assert_not_contains "$out" "REAPER: ORPHAN" "undeterminable age: should not report any orphans"
pass "refuses to close a pane whose age cannot be determined (fail closed)"

# --- Test 14: unreadable agent status refuses (not orphan) -------------------
# Change (2): a CLI failure reading agent status is not evidence of absence.
# The reaper must refuse, not treat the pane as agent-free and close it.
PATH="$SAVE_PATH"
setup_test "unreadable-status"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-mystery-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_agent_fail "wA:p1"
seed_process_info "wA:p1" 99999
# Seed a lock and a meta so the other gates do not interfere.
printf '%s\n' "$$" > "$TDIR/home/state/.lock"
seed_meta "other-task" "wA:pOther"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --close 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "unreadable status: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "unreadable status: should report SKIP"
assert_contains "$out" "agent status unreadable" "unreadable status: should mention unreadable"
assert_not_contains "$out" "REAPER: ORPHAN" "unreadable status: should not report any orphans"
# The critical assertion: no close call was issued.
[ ! -f "$HERDR_STATE/closed-panes.log" ] || fail "unreadable status: close call was issued (closed-panes.log exists)"
pass "unreadable agent status refuses (CLI failure is not evidence of absence)"

# --- Test 15: --close refuses without session lock ---------------------------
# Change (3): the destructive sweep must be gated on the session lock.
PATH="$SAVE_PATH"
setup_test "no-lock"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-orphan-no-lock"
seed_pane "wA:p1" "wA:t1" "wA"
seed_process_info "wA:p1" 99999
# No lock file - deliberately omitted.
# Seed a meta to give this home a realistic non-idle shape.
seed_meta "some-task" "wA:pOther"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --close 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "no-lock close: expected exit 0, got $rc"
assert_contains "$out" "refusing --close without session lock" "no-lock: should mention refusing without lock"
# The critical assertion: no close call was issued.
[ ! -f "$HERDR_STATE/closed-panes.log" ] || fail "no-lock: close call was issued (closed-panes.log exists)"
pass "--close refuses without session lock (gated on lock)"

# --- Test 16: wrong home with absent state/ is caught by lock gate -----------
# When state/ does not exist, the lock file is also absent, so the lock gate
# refuses first.  The self-check behind it is defense-in-depth for the same
# condition.  This test verifies that a misresolved home with no state
# directory is always caught before anything destructive runs.
PATH="$SAVE_PATH"
setup_test "wrong-home-no-state"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-someones-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_process_info "wA:p1" 99999
# Point state/ at a path that does not exist.
FM_STATE_OVERRIDE="$TDIR/home/missing-state"
export FM_STATE_OVERRIDE

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --close 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "wrong-home-no-state: expected exit 0, got $rc"
assert_contains "$out" "refusing --close" "wrong-home-no-state: should refuse"
# The critical assertion: no close call was issued.
[ ! -f "$HERDR_STATE/closed-panes.log" ] || fail "wrong-home-no-state: close call was issued (closed-panes.log exists)"
pass "wrong home with absent state/ is caught (lock gate refuses)"

# --- Test 17: idle home does NOT refuse (valid state/, no meta) ---------------
# An idle home has a valid, readable state/ directory but zero *.meta files.
# This is the legitimate condition reported by the lucie secondmate.
# The reaper must NOT produce a loud refusal on every bootstrap for this case.
PATH="$SAVE_PATH"
setup_test "idle-home"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-idle-home-pane"
seed_pane "wA:p1" "wA:t1" "wA"
seed_process_info "wA:p1" 99999
# Seed a lock (so the lock gate passes).
printf '%s\n' "$$" > "$TDIR/home/state/.lock"
# Deliberately NO meta files - state/ exists and is readable, just empty of tasks.
# This is the idle-home shape: valid state/, no *.meta, fm-* panes from the
# secondmate's own supervisor pane.

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --close 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "idle-home: expected exit 0, got $rc"
# The critical assertion: no "refusing" diagnostic was printed.
case "$out" in
  *"refusing --close"*) fail "idle-home: should NOT refuse for an idle home with valid state/" ;;
esac
pass "idle home (valid state/, no meta) does not trigger self-check refusal"


# --- Test 18: --close refuses with a STALE session lock ----------------------
PATH="$SAVE_PATH"
setup_test "stale-lock"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-orphan-stale-lock"
seed_pane "wA:p1" "wA:t1" "wA"
seed_process_info "wA:p1" 99999
# Seed a STALE lock file. 99999 is our mocked dead PID.
printf '99999\n' > "$TDIR/home/state/.lock"
# Seed a meta to give this home a realistic non-idle shape.
seed_meta "some-task" "wA:pOther"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --close 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "stale-lock close: expected exit 0, got $rc"
assert_contains "$out" "refusing --close" "stale-lock: should mention refusing"
# The critical assertion: no close call was issued.
[ ! -f "$HERDR_STATE/closed-panes.log" ] || fail "stale-lock: close call was issued (closed-panes.log exists)"
pass "--close refuses with a STALE session lock"
echo "all tests passed"
