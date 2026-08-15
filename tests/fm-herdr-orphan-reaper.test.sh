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

# --- Test 5: identifies a genuine orphan (unclaimed, no live agent) ----------
PATH="$SAVE_PATH"
setup_test "orphan"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-dead-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_agent "wA:p1" "done"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "orphan detection: expected exit 0, got $rc"
assert_contains "$out" "ORPHAN wA:p1" "orphan detection: should detect the orphan"
assert_contains "$out" "fm-dead-task" "orphan detection: should show tab label"
assert_contains "$out" "report mode" "orphan detection: should mention report mode"
assert_not_contains "$out" "CLOSED" "orphan detection: should not close in report mode"
pass "identifies a genuine orphan (unclaimed, done agent)"

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

# --- Test 7: --close actually closes orphans ---------------------------------
PATH="$SAVE_PATH"
setup_test "close"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-dead-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_agent "wA:p1" "idle"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --close 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "close mode: expected exit 0, got $rc"
assert_contains "$out" "ORPHAN wA:p1" "close mode: should detect the orphan"
assert_contains "$out" "CLOSED wA:p1" "close mode: should report closure"
pass "--close actually closes orphans"

# --- Test 8: non-herdr backend exits cleanly ---------------------------------
PATH="$SAVE_PATH"
setup_test "non-herdr"
printf 'tmux\n' > "$TDIR/home/config/backend"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "non-herdr: expected exit 0, got $rc"
[ -z "$out" ] || fail "non-herdr: expected silent exit, got: $out"
pass "non-herdr backend exits cleanly (silent)"

# --- Test 9: mixed panes - claimed, orphan, captain, live-agent --------------
PATH="$SAVE_PATH"
setup_test "mixed"
seed_workspace "wA" "firstmate"

seed_tab "wA" "wA:t1" "fm-claimed-task"
seed_pane "wA:p1" "wA:t1" "wA"
seed_meta "claimed-task" "wA:p1"

seed_tab "wA" "wA:t2" "fm-orphan-task"
seed_pane "wA:p2" "wA:t2" "wA"
seed_agent "wA:p2" "done"

seed_tab "wA" "wA:t3" "my-shell"
seed_pane "wA:p3" "wA:t3" "wA"

seed_tab "wA" "wA:t4" "fm-live-task"
seed_pane "wA:p4" "wA:t4" "wA"
seed_agent "wA:p4" "working"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "mixed: expected exit 0, got $rc"
assert_contains "$out" "SKIP wA:p1" "mixed: should skip claimed pane"
assert_contains "$out" "ORPHAN wA:p2" "mixed: should detect orphan pane"
assert_not_contains "$out" "wA:p3" "mixed: captain's tab should be invisible"
assert_contains "$out" "SKIP wA:p4" "mixed: should skip live agent pane"
assert_contains "$out" "1 orphaned pane" "mixed: should count exactly 1 orphan"
pass "mixed panes: correctly classifies claimed, orphan, captain, and live-agent"

# --- Test 10: pane with no agent at all (deregistered) is orphan -------------
PATH="$SAVE_PATH"
setup_test "no-agent"
seed_workspace "wA" "firstmate"
seed_tab "wA" "wA:t1" "fm-old-task"
seed_pane "wA:p1" "wA:t1" "wA"

out=$("$ROOT/bin/fm-herdr-orphan-reaper.sh" --report 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "no agent: expected exit 0, got $rc"
assert_contains "$out" "ORPHAN wA:p1" "no agent: should detect orphan with no agent"
pass "pane with no agent at all (deregistered) is still orphan"

echo "all tests passed"
