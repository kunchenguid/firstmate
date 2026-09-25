#!/usr/bin/env bash
# tests/fm-herdr-launch-setup-e2e.test.sh - real-Herdr public relaunch
# regression for pre-launch setup ordering.
#
# Herdr acknowledges pane.run before the pane shell executes the submitted
# command. Firstmate used to send each export through pane.run and then type the
# staged launch source through send-text plus Enter. The deferred Enter from the
# final export could land after the source text, producing one invalid zsh
# export and leaving an agent-free shell even though fm-spawn reported success.
#
# This test uses one guarded non-default lab session, drives the public
# fm-spawn.sh --relaunch path, and requires a real foreground worker process
# whose marker contains every pre-launch environment value.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-launch-setup) || fail "could not allocate a guarded Herdr lab name"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-launch-setup.XXXXXX")
LAB_ACTIVE=0
ID="launch-setup-$$-$RANDOM"
cleanup() {
  local rc=0
  if [ "$LAB_ACTIVE" = 1 ]; then
    LAB_ACTIVE=0
    "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || rc=1
  fi
  rm -rf "$SCRATCH" "/tmp/fm-$ID+"* 2>/dev/null || true
  return "$rc"
}
trap cleanup EXIT

"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision the guarded Herdr lab"
LAB_ACTIVE=1

PROJ="$SCRATCH/project"
WT="$SCRATCH/isolated-copy"
HOME_DIR="$SCRATCH/home"
MARKER="$SCRATCH/agent-started"
AGENT="$SCRATCH/agent.sh"
mkdir -p "$PROJ" "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$HOME_DIR/config"
git -C "$PROJ" init -q
git -C "$PROJ" config user.name 'Firstmate Tests'
git -C "$PROJ" config user.email tests@example.invalid
printf '# launch setup regression\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" commit -qm initial
git clone -q "$PROJ" "$WT"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
cat > "$HOME_DIR/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the isolated Herdr launch path.

## Firstmate spec
Start the marker worker in the recorded local copy.
EOF
cat > "$AGENT" <<EOF
#!/usr/bin/env bash
printf 'FM_TASK_ID=%s\\nGOTMPDIR=%s\\nCOMPACT_ADVISER_DISABLE=%s\\n' \
  "\${FM_TASK_ID:-}" "\${GOTMPDIR:-}" "\${COMPACT_ADVISER_DISABLE:-}" > "$MARKER"
while :; do sleep 60; done
EOF
chmod +x "$AGENT"

WS_JSON=$("$HERDR_LAB_HELPER" run "$SESSION" workspace create \
  --cwd "$WT" --label "launch-setup-$ID" --no-focus) \
  || fail "could not create the isolated worker workspace"
WS=$(printf '%s' "$WS_JSON" | jq -r '.result.workspace.workspace_id // empty')
TAB=$(printf '%s' "$WS_JSON" | jq -r '.result.tab.tab_id // empty')
PANE=$(printf '%s' "$WS_JSON" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WS" ] && [ -n "$TAB" ] && [ -n "$PANE" ] \
  || fail "Herdr did not return complete workspace, tab, and pane ids"

cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
worktree=$WT
project=$PROJ
harness=bash $AGENT
kind=ship
mode=local-only
yolo=off
branch=fm/$ID
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" HERDR_PANE_ID= \
  FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch 2>&1) \
  || fail "the public Herdr relaunch failed: $OUT"
case "$OUT" in
  *"spawned $ID "*) ;;
  *) fail "the public relaunch did not report its worker: $OUT" ;;
esac

for _ in $(seq 1 100); do
  [ ! -f "$MARKER" ] || break
  sleep 0.1
done
if [ ! -f "$MARKER" ]; then
  PANE_OUT=$("$HERDR_LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200 2>&1 || true)
  fail "fm-spawn reported success but the worker did not start; pane: $PANE_OUT"
fi
EXPECTED=$(printf 'FM_TASK_ID=%s\nGOTMPDIR=/tmp/fm-%s/gotmp\nCOMPACT_ADVISER_DISABLE=1' "$ID" "$ID")
[ "$(cat "$MARKER")" = "$EXPECTED" ] \
  || fail "the worker started without the complete pre-launch environment: $(cat "$MARKER")"
PROCESS=$("$HERDR_LAB_HELPER" run "$SESSION" pane process-info --pane "$PANE") \
  || fail "the launched worker pane has no readable process information"
printf '%s' "$PROCESS" | jq -e --arg agent "$AGENT" '
  [.result.process_info.foreground_processes[]?.cmdline // ""]
  | any(contains($agent))
' >/dev/null 2>&1 || fail "the marker was written but the worker is not still running in the pane"
pass "real herdr: public relaunch completes setup before submitting the staged launch and starts the worker"

"$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null \
  || fail "guarded Herdr teardown or default-session tripwire failed"
LAB_ACTIVE=0
rm -rf "$SCRATCH" "/tmp/fm-$ID+"* 2>/dev/null || true
trap - EXIT
