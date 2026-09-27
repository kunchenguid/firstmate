#!/usr/bin/env bash
# Opt-in real Orca/Codex stopped-worker replacement in the CURRENT isolated
# Orca worktree. Creates only private fixture state and two owned terminals;
# never allocates, releases, switches, or removes a worktree. Spends one prompt.
# Run: FM_ORCA_RECOVERY_LIVE=1 bin/fm-test-run.sh tests/fm-orca-recovery-live-e2e.test.sh
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_ORCA_RECOVERY_LIVE orca codex node
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
fm_backend_source orca

cd "$ROOT"
WT=$(pwd -P)
GIT_DIR=$(git rev-parse --absolute-git-dir)
COMMON=$(git rev-parse --path-format=absolute --git-common-dir)
[ "$GIT_DIR" != "$COMMON" ] || fail 'live Orca recovery requires an existing isolated linked worktree'
PROJECT=$(dirname "$COMMON")
WT_ID=$(orca worktree current --json | node -e '
const d=JSON.parse(require("fs").readFileSync(0,"utf8"));
if (!d.ok || d.result?.worktree?.path !== process.argv[1]) process.exit(1);
console.log(d.result.worktree.id);' "$WT") || fail 'Orca current worktree does not match this checkout'
VERSION=$(codex --version)
mkdir -p "$ROOT/.no-mistakes"
FIXTURE=$(mktemp -d "$ROOT/.no-mistakes/orca-recovery-live.XXXXXX")
ID=orca-recovery-live
OLD=
NEW=
cleanup() {
  local handle
  if [ -f "$FIXTURE/state/$ID.meta" ]; then
    NEW=$(sed -n 's/^terminal=//p' "$FIXTURE/state/$ID.meta")
  fi
  for handle in "$OLD" "$NEW"; do
    [ -z "$handle" ] || orca terminal close --terminal "$handle" --json >/dev/null 2>&1 || true
  done
  # Keep the private transcript/evidence for diagnosis, including on failure.
  fm_test_cleanup
}
trap cleanup EXIT
mkdir -p "$FIXTURE/state" "$FIXTURE/data/$ID" "$FIXTURE/config"
printf 'preserve uncommitted task content\n' > "$FIXTURE/preserved"
BEFORE=$(git diff --binary HEAD | shasum -a 256)
HEAD_BEFORE=$(git rev-parse HEAD)
orca terminal create --worktree "id:$WT_ID" --title fm-recovery-live-old \
  --command 'codex --dangerously-bypass-approvals-and-sandbox --disable hooks' --json > "$FIXTURE/create.json"
OLD=$(fm_backend_orca_json_get terminal-handle < "$FIXTURE/create.json")
for _ in $(seq 1 60); do
  [ "$(fm_backend_agent_state orca "$OLD")" != alive ] || break
  sleep 1
done
[ "$(fm_backend_agent_state orca "$OLD")" = alive ] || fail "$VERSION: live Orca agent was not classified alive"
cat > "$FIXTURE/state/$ID.meta" <<EOF
window=fm-$ID
endpoint_task_id=$ID
backend=orca
terminal=$OLD
orca_worktree_id=$WT_ID
worktree=$WT
project=$PROJECT
harness=codex
kind=scout
model=default
effort=default
EOF
cat > "$FIXTURE/data/$ID/brief.md" <<EOF
# Current worker role contract
This is a bounded runtime smoke probe, not a supervisor session.
Do not run session-start, inspect the fleet, delegate, or edit project code.
Your sole task is to run: printf 'replacement-ran\\n' > '$FIXTURE/replacement-ran'
Then reply 'probe complete' and stop.

# Task
## Captain's intent
Verify stopped-worker replacement with Codex.

## Firstmate spec
Execute only the marker command above.
EOF
run_local() {
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$FIXTURE" FM_ROOT="$ROOT" FM_SPAWN_NO_GUARD=1 "$@"
}
if run_local "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch --harness codex > "$FIXTURE/live-refusal.log" 2>&1; then
  fail 'live Orca agent was accepted for direct replacement'
fi
assert_grep alive "$FIXTURE/live-refusal.log" 'the live refusal must identify its actual cause'
orca terminal close --terminal "$OLD" --json > "$FIXTURE/close.json"
[ "$(fm_backend_agent_state orca "$OLD")" = missing ] || fail 'closed Orca terminal lacks recovery-grade exit proof'
[ "$(fm_control_endpoint_absence_verdict orca "$OLD")" = $'gone\t' ] || fail 'closed Orca terminal lacks endpoint-absence proof'
run_local "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness codex \
  --note 'The old terminal was deliberately closed. Execute only the smoke marker command.' \
  > "$FIXTURE/relaunch.log" 2>&1 || { cat "$FIXTURE/relaunch.log"; fail 'live Orca replacement failed'; }
NEW=$(sed -n 's/^terminal=//p' "$FIXTURE/state/$ID.meta")
[ -n "$NEW" ] && [ "$NEW" != "$OLD" ] || fail 'replacement did not publish a new exact endpoint'
for _ in $(seq 1 90); do
  [ ! -f "$FIXTURE/replacement-ran" ] || break
  sleep 1
done
[ -f "$FIXTURE/replacement-ran" ] || fail "$VERSION: replacement never processed its launch instructions ($FIXTURE)"
[ "$(cat "$FIXTURE/preserved")" = 'preserve uncommitted task content' ] || fail 'replacement lost uncommitted contents'
[ "$(git rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail 'replacement changed HEAD'
[ "$(git diff --binary HEAD | shasum -a 256)" = "$BEFORE" ] || fail 'replacement changed the existing worktree diff'
[ "$(sed -n 's/^worktree=//p' "$FIXTURE/state/$ID.meta")" = "$WT" ] || fail 'replacement changed the worktree'
[ "$(sed -n 's/^orca_worktree_id=//p' "$FIXTURE/state/$ID.meta")" = "$WT_ID" ] || fail 'replacement changed Orca identity'
printf 'ok - Orca live recovery (%s): live refusal, confirmed full exit, Codex replacement processed instructions, checkout preserved\n' "$VERSION"
