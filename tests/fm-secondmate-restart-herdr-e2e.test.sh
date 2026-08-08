#!/usr/bin/env bash
# tests/fm-secondmate-restart-herdr-e2e.test.sh - isolated real-Herdr regression
# for bin/fm-secondmate-restart.sh against the two Herdr workspace shapes a
# persistent second mate actually has.
#
# WHY THIS NEEDS REAL HERDR
# A second mate's own tab is normally the ONLY tab in its 2ndmate-<id>
# workspace, because its crewmates get their own presentation workspaces. That
# sole-tab shape is where Herdr's tab lifecycle is special: `tab close` refuses
# it outright with `tab_close_failed: cannot close the last tab in a workspace`,
# which is what an operator retiring the endpoint by hand runs into. The pane
# close the adapter itself uses succeeds there and takes the emptied workspace
# with it, and the next spawn recreates the workspace - behavior no canned
# response can prove. This test therefore asserts the OBSERVABLE outcome of a
# restart (old endpoint gone, workspace present again, new endpoint carrying a
# genuinely registered agent, siblings untouched) rather than which API calls
# were made.
#
# Covered here:
#   - sole-tab restart: the whole 2ndmate-<id> workspace is emptied and
#     recreated, and the relaunched second mate ends up live again.
#   - ordinary multi-tab restart: a sibling tab in the same workspace survives
#     and the workspace id itself never changes.
#   - the persistent home survives both restarts verbatim, including a crewmate
#     endpoint record the second mate owns.
#   - changed launch flags reach the relaunched task metadata.
#
# Safety (tests/herdr-test-safety.sh): every lifecycle call targets this test's
# own isolated non-default $SESSION, cleanup goes only through
# herdr_safe_stop_and_delete, and its fleet-state tripwire requires the live
# `default` session to be byte-identical afterwards. The captain's fleet runs in
# `default`; nothing here may touch it.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-sm-restart-e2e-$$"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-sm-restart-e2e.XXXXXX")
CLEANED=0
# "The live default session is unaffected" is a guarantee this suite ASSERTS,
# not a warning it prints. The guarded teardown re-checks refuse-default before
# each destructive call and requires the recorded default-session fleet state to
# be byte-identical afterwards; a failure there must fail the run. A bare EXIT
# trap cannot do that - bash keeps the status that triggered the trap unless the
# trap itself exits - so this one exits explicitly, and CLEANED keeps fail()'s
# own call path from tearing down twice.
cleanup_all() {
  local rc=$?
  [ "$CLEANED" = 0 ] || return "$rc"
  CLEANED=1
  if ! herdr_safe_stop_and_delete "$SESSION"; then
    printf 'not ok - guarded lab teardown or its default-session tripwire failed; the live default session may have changed\n' >&2
    rm -rf "$SCRATCH"
    exit 1
  fi
  rm -rf "$SCRATCH"
  return "$rc"
}
trap cleanup_all EXIT

ID=labsm
HOME_DIR="$SCRATCH/home"
SUB="$SCRATCH/sub"
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKEBIN"
printf 'claude\n' > "$HOME_DIR/config/secondmate-harness"

# A stand-in "claude" that registers itself as a real agent on its own Herdr
# pane (Herdr injects HERDR_PANE_ID into every pane process) and then idles, so
# the relaunched endpoint reaches a genuinely agent-registered state exactly as
# a real harness would. Never runs a real harness or spends a credential.
cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
set -u
[ -z "\${HERDR_PANE_ID:-}" ] || herdr pane report-agent "\$HERDR_PANE_ID" \\
  --source fm-sm-restart-e2e --agent fm-lab-agent --state idle \\
  --session "$SESSION" >/dev/null 2>&1 || true
exec sleep 120
SH
chmod +x "$FAKEBIN/claude"
# The Herdr server is started below from THIS process, so panes it creates
# inherit this PATH and find the stand-in rather than a real harness.
PATH="$FAKEBIN:$PATH"
export PATH

# The persistent second mate home, holding material that must survive verbatim.
mkdir -p "$SUB/bin" "$SUB/data" "$SUB/state" "$SUB/config" "$SUB/projects/alpha"
printf '# Firstmate\n' > "$SUB/AGENTS.md"
printf '%s\n' "$ID" > "$SUB/.fm-secondmate-home"
printf 'persistent charter for %s\n' "$ID" > "$SUB/data/charter.md"
printf -- '- [ ] sub-item-a1 queued work\n' > "$SUB/data/backlog.md"
printf 'clone marker\n' > "$SUB/projects/alpha/marker.txt"
# A crewmate this second mate owns; restarting the parent must not touch it.
printf 'window=x:fm-child\nendpoint_task_id=child\nkind=ship\n' > "$SUB/state/child.meta"
SUB_ABS=$(cd "$SUB" && pwd -P)
printf -- '- %s - lab charter (home: %s; scope: lab; projects: alpha; added 2026-08-08)\n' \
  "$ID" "$SUB_ABS" > "$HOME_DIR/data/secondmates.md"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
touch "$HOME_DIR/state/.last-watcher-beat"

fm_herdr_lab_provision "$SESSION" >/dev/null 2>&1 \
  || fail "could not provision the isolated Herdr lab session"
export HERDR_SESSION="$SESSION"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
meta_value() { grep "^$1=" "$HOME_DIR/state/$ID.meta" 2>/dev/null | cut -d= -f2- | tail -1; }
tab_count() { lab tab list --workspace "$1" 2>/dev/null | jq -r '[.result.tabs[]?] | length'; }
workspace_present() {
  lab workspace list 2>/dev/null \
    | jq -r --arg w "$1" 'if ([.result.workspaces[]? | select(.workspace_id==$w)] | length) == 1 then "yes" else "no" end'
}
pane_gone() { [ "$(fm_backend_herdr_pane_agent_state "$SESSION" "$1")" = dead ]; }

# Wait for the recorded endpoint to reach a registered-agent state, the way a
# supervisor would rather than assuming launch timing.
wait_alive() {
  local target=$1 i=0
  while [ "$i" -lt 120 ]; do
    [ "$(fm_backend_agent_state herdr "$target")" = alive ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

run_fm() {  # <script> <args...>
  local script=$1
  shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_BACKEND=herdr \
    HERDR_SESSION="$SESSION" \
    "$ROOT/bin/$script" "$@" 2>&1
}

assert_home_intact() {  # <why>
  grep -Fq "persistent charter for $ID" "$SUB/data/charter.md" || fail "$1: the charter was lost"
  grep -Fq 'sub-item-a1' "$SUB/data/backlog.md" || fail "$1: the second mate's backlog was lost"
  grep -Fq 'clone marker' "$SUB/projects/alpha/marker.txt" || fail "$1: a project clone was lost"
  [ -f "$SUB/.fm-secondmate-home" ] || fail "$1: the second mate home marker was removed"
  grep -Fq 'window=x:fm-child' "$SUB/state/child.meta" \
    || fail "$1: the second mate's own crewmate record was lost or rewritten"
}

# --- 1. stand the second mate up through the ordinary spawn path ------------

run_fm fm-spawn.sh "$ID" --secondmate --harness claude --backend herdr >/dev/null \
  || fail "the initial secondmate spawn failed"
OLD_TARGET=$(meta_value window)
OLD_PANE=$(meta_value herdr_pane_id)
OLD_WS=$(meta_value herdr_workspace_id)
[ -n "$OLD_TARGET" ] && [ -n "$OLD_PANE" ] && [ -n "$OLD_WS" ] \
  || fail "the initial spawn did not record a complete Herdr endpoint"
wait_alive "$OLD_TARGET" || fail "the initial second mate never reached a registered-agent state"
[ "$(tab_count "$OLD_WS")" = 1 ] \
  || fail "expected the sole-tab workspace shape, got $(tab_count "$OLD_WS") tabs in $OLD_WS"
pass "setup: a live second mate occupies the sole tab of its own Herdr workspace"

# --- 2. sole-tab restart ----------------------------------------------------
# The reported failure shape: this is the workspace whose last tab `tab close`
# refuses. The restart must still retire the endpoint, and the relaunch must
# bring the workspace back.

RESTART_OUT=$(run_fm fm-secondmate-restart.sh "$ID" --model opus --backend herdr) \
  || fail "the sole-tab restart failed: $RESTART_OUT"
case "$RESTART_OUT" in
  *"restarted $ID"*) : ;;
  *) fail "the sole-tab restart did not report a relaunch: $RESTART_OUT" ;;
esac

pane_gone "$OLD_PANE" || fail "the previous endpoint pane $OLD_PANE still exists after the restart"
[ "$(workspace_present "$OLD_WS")" = no ] \
  || fail "the emptied sole-tab workspace $OLD_WS was expected to be removed with its last pane"

NEW_TARGET=$(meta_value window)
NEW_PANE=$(meta_value herdr_pane_id)
NEW_WS=$(meta_value herdr_workspace_id)
[ -n "$NEW_TARGET" ] || fail "the restart left no endpoint recorded"
[ "$NEW_PANE" != "$OLD_PANE" ] || fail "the restart recorded the old pane instead of the replacement"
[ "$(workspace_present "$NEW_WS")" = yes ] \
  || fail "the second mate's workspace was not recreated by the relaunch"
[ "$(tab_count "$NEW_WS")" = 1 ] \
  || fail "the recreated workspace should hold exactly the second mate's tab, got $(tab_count "$NEW_WS")"
wait_alive "$NEW_TARGET" || fail "the relaunched second mate never reached a registered-agent state"
[ "$(meta_value model)" = opus ] || fail "the changed launch flag did not reach the task record"
[ "$(meta_value kind)" = secondmate ] || fail "the relaunched record is no longer a second mate"
[ "$(meta_value home)" = "$SUB_ABS" ] || fail "the relaunched record no longer names the persistent home"
assert_home_intact "sole-tab restart"
pass "sole-tab restart: the emptied workspace is recreated, the second mate is live again on the new flags, and its home is intact"

# --- 3. ordinary multi-tab restart ------------------------------------------
# The other real shape: a sibling tab sharing the workspace (a crewmate of this
# second mate when presentation spaces are off). The workspace must survive and
# the sibling must be untouched.

SIB=$(lab tab create --workspace "$NEW_WS" --cwd "$SUB_ABS" --label fm-sibling --no-focus 2>/dev/null \
  | jq -r '[.result.tab.tab_id, .result.root_pane.pane_id] | @tsv')
SIB_TAB=${SIB%%$'\t'*}
SIB_PANE=${SIB##*$'\t'}
[ -n "$SIB_TAB" ] && [ -n "$SIB_PANE" ] || fail "could not create the sibling tab for the multi-tab case"
[ "$(tab_count "$NEW_WS")" = 2 ] || fail "expected the multi-tab shape before the second restart"

MULTI_OLD_PANE=$NEW_PANE
RESTART_OUT=$(run_fm fm-secondmate-restart.sh "$ID" --model sonnet --backend herdr) \
  || fail "the multi-tab restart failed: $RESTART_OUT"

pane_gone "$MULTI_OLD_PANE" || fail "the previous endpoint pane survived the multi-tab restart"
[ "$(workspace_present "$NEW_WS")" = yes ] \
  || fail "a multi-tab restart must never remove the shared workspace"
[ "$(meta_value herdr_workspace_id)" = "$NEW_WS" ] \
  || fail "the multi-tab relaunch moved the second mate out of its existing workspace"
lab pane get "$SIB_PANE" >/dev/null 2>&1 || fail "the sibling tab's pane was closed by the restart"
[ "$(tab_count "$NEW_WS")" = 2 ] \
  || fail "expected the sibling plus the replacement tab, got $(tab_count "$NEW_WS")"
wait_alive "$(meta_value window)" || fail "the second relaunch never reached a registered-agent state"
[ "$(meta_value model)" = sonnet ] || fail "the second changed launch flag did not reach the task record"
assert_home_intact "multi-tab restart"
pass "multi-tab restart: the shared workspace and its sibling tab survive while the second mate is replaced in place"

fm_backend_herdr_kill "$(meta_value window)" 2>/dev/null || true
fm_backend_herdr_kill "$SESSION:$SIB_PANE" 2>/dev/null || true
