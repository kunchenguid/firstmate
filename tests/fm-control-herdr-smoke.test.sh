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
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION=$(PATH="$PATH" "$HERDR_LAB_HELPER" name fm-control-smoke)
INITIAL_SESSION=$SESSION
export HERDR_LAB_HELPER HERDR_LAB_SESSION="$SESSION" HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  local status=0
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  for lab_session in "${INITIAL_SESSION:-}" "${RECOVERY_SESSION:-}"; do
    [ -n "$lab_session" ] || continue
    [ -f "$(fm_herdr_lab_tripwire_path "$lab_session")" ] || continue
    PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$lab_session" || status=1
  done
  return "$status"
}
trap cleanup_all EXIT
PATH="$PATH" "$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not prepare isolated Herdr lab session"

lab() {
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$SESSION" "$@"
}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

REAL_HERDR=$(command -v herdr)
ORIGINAL_PATH=$PATH
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@"
fi
args=("$@")
last=$((${#args[@]} - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$last-1]}" = --session ] \
   && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset 'args[last]' 'args[last-1]'
fi
for arg in "${args[@]}"; do
  case "$arg" in
    --session|--session=*) exit 2 ;;
  esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$FAKEBIN/herdr"
export HERDR_ORIGINAL_PATH="$ORIGINAL_PATH" REAL_HERDR PATH="$FAKEBIN:$ORIGINAL_PATH"
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

run_spawn_missing() {
  env PATH="$PATH" FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$SCRATCH/grokhome" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}


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

if ! lab pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle >/dev/null 2>&1; then
  fail "could not register a live agent on the task pane"
fi

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

  lab pane get "$PANE_ID" >/dev/null 2>&1 \
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

# --- authenticated missing-endpoint recovery -------------------------------
# Use a fresh named lab after the stop-failure smoke. The old scenario is
# intentionally terminal: its failed exit may leave the prior workspace in a
# state that is unsuitable for a second independent assertion.
PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$INITIAL_SESSION" \
  || fail "could not retire the first isolated Herdr smoke session"
INITIAL_SESSION=
RECOVERY_SESSION=$(PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" name fm-control-recovery)
SESSION=$RECOVERY_SESSION
export HERDR_LAB_SESSION="$SESSION" HERDR_SESSION="$SESSION"
PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$SESSION" \
  || fail "could not provision the recovery Herdr lab session"
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") \
  || fail "recovery container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "recovery create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=historical-unsupported"
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
# The fresh task pane is agent-free by construction. Closing it below creates
# the authoritative missing endpoint without invoking lifecycle control on the
# deliberately unsupported historical harness.
# Keep an anchor tab so closing the retired task tab cannot remove the named
# workspace. Its cwd is deliberately not the task worktree, so the duplicate
# worktree inventory remains a meaningful guard.
lab tab create --workspace "$WORKSPACE_ID" --cwd "$ROOT" --label fm-control-anchor --no-focus \
  >/dev/null || fail "could not create the non-task workspace anchor"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
set -u
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane report-agent "$HERDR_PANE_ID" \
  --source fm-control-relaunch-smoke --agent fm-control-relaunch-agent --state idle >/dev/null
while :; do sleep 1; done
SH
chmod +x "$FAKEBIN/claude"
lab pane close "$PANE_ID" >/dev/null || fail "could not remove the retired task pane"
awk -F= 'BEGIN { OFS="=" } $1 == "harness" { $2="historical-unsupported" } { print }' \
  "$HOME_DIR/state/hsmoke.meta" > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
OUT=$(run_control hsmoke relaunch --harness claude --note "recover the missing Herdr endpoint") \
  || fail "authenticated missing Herdr recovery should succeed: $OUT"
case "$OUT" in
  *"endpoint-recreated="*) : ;;
  *) fail "recovery outcome should identify the recreated endpoint, got: $OUT" ;;
esac
NEW_PANE=$(grep '^herdr_pane_id=' "$HOME_DIR/state/hsmoke.meta" | cut -d= -f2-)
NEW_TAB=$(grep '^herdr_tab_id=' "$HOME_DIR/state/hsmoke.meta" | cut -d= -f2-)
NEW_WORKSPACE=$(grep '^herdr_workspace_id=' "$HOME_DIR/state/hsmoke.meta" | cut -d= -f2-)
[ "$NEW_WORKSPACE" = "$WORKSPACE_ID" ] || fail "recovery must preserve the recorded workspace"
[ "$NEW_PANE" != "$PANE_ID" ] || fail "recovery must publish the new response-derived pane"
[ "$NEW_TAB" != "$TAB_ID" ] || fail "recovery must publish the new response-derived tab"
[ "$(fm_backend_agent_state herdr "$SESSION:$NEW_PANE")" = alive ] \
  || fail "the replacement agent must be alive on the recreated pane"
[ "$(cat "$HOME_DIR/state/hsmoke.control-relaunch.candidate" 2>/dev/null || true)" = "" ] \
  || fail "a completed recovery must retire its candidate sidecar"
[ "$(grep '^harness=' "$HOME_DIR/state/hsmoke.meta")" = harness=claude ] \
  || fail "recovery must publish the explicit verified replacement harness"
pass "real herdr: authenticated relaunch recreates a missing task endpoint in the recorded workspace"

# Direct fm-spawn relaunch is not an authorization path. Remove the replacement
# pane, leave its metadata intact, and prove a direct missing-endpoint attempt
# refuses without creating another tab.
lab pane close "$NEW_PANE" >/dev/null || fail "could not remove the recovered pane for bypass testing"
DIRECT_BEFORE_TABS=$(lab tab list --workspace "$WORKSPACE_ID")
if DIRECT_OUT=$(run_spawn_missing hsmoke --relaunch --harness claude 2>&1); then
  fail "direct fm-spawn relaunch must refuse a missing Herdr endpoint: $DIRECT_OUT"
fi
case "$DIRECT_OUT" in
  *"only the owning fm-control relaunch transaction"*) : ;;
  *) fail "direct missing-endpoint refusal should name fm-control ownership: $DIRECT_OUT" ;;
esac
AFTER_TABS=$(lab tab list --workspace "$WORKSPACE_ID")
[ "$AFTER_TABS" = "$DIRECT_BEFORE_TABS" ] || fail "direct missing-endpoint refusal must not create a Herdr tab"
pass "real herdr: direct fm-spawn relaunch cannot bypass authenticated missing-endpoint recovery"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
