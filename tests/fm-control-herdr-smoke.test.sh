#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent on a plain
# shell pane exercises exactly the classification the control plane gates on.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
FAKE_BIN="$SCRATCH/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
chmod +x "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent: classification flips, and the verbs follow ---------

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

# --- vanished pane: fm-spawn --relaunch recreates the exact task endpoint ---
# A worker can exit and leave Herdr to reap both its pane and registration while
# the task's branch, worktree, metadata, and no-mistakes custody remain. The
# public relaunch path must recreate exactly one replacement pane in the
# recorded workspace, preserving the task record's non-endpoint fields.
MISSING_ID=hmissing
mkdir -p "$HOME_DIR/data/$MISSING_ID"
printf '# brief\n\nDelivery contract: mode=no-mistakes\n' > "$HOME_DIR/data/$MISSING_ID/brief.md"
MISSING_SPACE=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" workspace create \
  --cwd "$WT" --label "fm-control-missing-pane" --no-focus) \
  || fail "could not create the vanished-pane workspace"
MISSING_WORKSPACE_ID=$(printf '%s' "$MISSING_SPACE" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$MISSING_WORKSPACE_ID" ] || fail "vanished-pane workspace returned no id"
MISSING_IDS=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" tab create \
  --workspace "$MISSING_WORKSPACE_ID" --cwd "$WT" --label "fm-$MISSING_ID" --no-focus) \
  || fail "could not create the vanished-pane fixture"
read -r MISSING_TAB MISSING_PANE <<EOF
$(printf '%s' "$MISSING_IDS" | jq -r '[.result.tab.tab_id, .result.root_pane.pane_id] | @tsv')
EOF
[ -n "$MISSING_TAB" ] && [ -n "$MISSING_PANE" ] || fail "vanished-pane fixture returned incomplete ids"
{
  echo "window=$SESSION:$MISSING_PANE"
  echo "endpoint_task_id=$MISSING_ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "tasktmp=/tmp/fm-$MISSING_ID"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$MISSING_WORKSPACE_ID"
  echo "herdr_tab_id=$MISSING_TAB"
  echo "herdr_pane_id=$MISSING_PANE"
  echo "pr=https://example.invalid/firstmate/pull/1"
  echo "no_mistakes_run=active-fixture"
} > "$HOME_DIR/state/$MISSING_ID.meta"
printf 'preserved\n' > "$WT/uncommitted-missing-pane.txt"
DEFAULT_BEFORE=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" session list --json \
  | jq -c '[.sessions[]? | select(.default == true)]')
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane close "$MISSING_PANE" >/dev/null \
  || fail "could not remove the vanished-pane fixture"
if "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane get "$MISSING_PANE" >/dev/null 2>&1; then
  fail "vanished-pane fixture still has its old pane"
fi
if "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" agent get "$MISSING_PANE" >/dev/null 2>&1; then
  fail "vanished-pane fixture still has its old agent registration"
fi
OUT=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=herdr HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-spawn.sh" "$MISSING_ID" --relaunch 2>&1) \
  || fail "fm-spawn --relaunch did not recreate a vanished Herdr pane: $OUT"
NEW_MISSING_PANE=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$MISSING_ID.meta" | cut -d= -f2-)
NEW_MISSING_TAB=$(grep '^herdr_tab_id=' "$HOME_DIR/state/$MISSING_ID.meta" | cut -d= -f2-)
[ -n "$NEW_MISSING_PANE" ] && [ -n "$NEW_MISSING_TAB" ] \
  && [ "$NEW_MISSING_PANE" != "$MISSING_PANE" ] \
  || fail "vanished-pane relaunch did not publish a distinct replacement endpoint: $OUT"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane get "$NEW_MISSING_PANE" >/dev/null \
  || fail "vanished-pane relaunch did not create its recorded replacement pane"
[ -f "$WT/uncommitted-missing-pane.txt" ] \
  || fail "vanished-pane relaunch lost an uncommitted worktree file"
grep -qx 'pr=https://example.invalid/firstmate/pull/1' "$HOME_DIR/state/$MISSING_ID.meta" \
  || fail "vanished-pane relaunch lost PR custody"
grep -qx 'no_mistakes_run=active-fixture' "$HOME_DIR/state/$MISSING_ID.meta" \
  || fail "vanished-pane relaunch lost active no-mistakes custody"
DEFAULT_AFTER=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" session list --json \
  | jq -c '[.sessions[]? | select(.default == true)]')
[ "$DEFAULT_AFTER" = "$DEFAULT_BEFORE" ] \
  || fail "vanished-pane relaunch changed the default Herdr session"
pass "real herdr: fm-spawn --relaunch recreates one vanished pane and preserves task custody without changing default"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
fm_backend_herdr_kill "$SESSION:$NEW_MISSING_PANE" 2>/dev/null || true
