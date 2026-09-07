#!/usr/bin/env bash
# Opt-in real Pi/Herdr/Treehouse regression for stale Herdr Pi authority after
# Pi exits into Treehouse's nested shell.
#
# This test makes no model request: a test-local Pi extension accepts project
# trust and aborts every attempted turn before provider work. It provisions a
# named fm-herdr-lab session, enters a real Treehouse worktree through the same
# interactive `treehouse get` topology as production, starts and exits real Pi,
# proves Herdr still exposes the old non-working herdr:pi authority, and invokes
# the public `fm-control relaunch` transaction. The result must reuse the exact
# pane and worktree, rotate to a distinct real Pi authority, leave exactly one
# accepted worker, and retain the ordinary duplicate-worker refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CONTROL_HERDR_PI_RELAUNCH_LIVE_E2E herdr jq pi python3 git treehouse

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-control-herdr-pi-relaunch-live)
TMP_ROOT=$(fm_test_tmproot fm-control-herdr-pi-relaunch-live)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
POOL="$TMP_ROOT/treehouse-pool"
PI_DIR="$TMP_ROOT/pi-agent"
USER_HOME="$TMP_ROOT/user-home"
FAKEBIN="$TMP_ROOT/fakebin"
ID=pi-relaunch-live
WT=
PANE=
ORIGINAL_PATH=$PATH
REAL_PI=$(command -v pi)
HERDR_PI_EXTENSION="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/herdr-agent-state.ts"
[ -f "$HERDR_PI_EXTENSION" ] || { echo "skip: installed Herdr Pi extension not found"; exit 0; }

cleanup() {
  local rc=$?
  trap - EXIT
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    TREEHOUSE_ROOT="$POOL" treehouse return "$WT" >/dev/null 2>&1 || rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PI_DIR/extensions" "$USER_HOME" "$FAKEBIN" "$PROJECT"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf 'herdr\n' > "$HOME_DIR/config/backend"

git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name 'Firstmate Tests'
git -C "$PROJECT" config user.email 'tests@example.invalid'
printf '# Real Herdr Pi relaunch fixture\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm initial

# The replacement receives fm-spawn's normal positional prompt. Abort it before
# provider work while keeping Pi alive and idle, and grant session-only trust.
cat > "$PI_DIR/extensions/no-provider.ts" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
export default function (pi: ExtensionAPI) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", (_event, ctx) => { ctx.abort(); });
}
EOF
cat > "$FAKEBIN/pi" <<EOF
#!/usr/bin/env bash
exec '$REAL_PI' -e '$HERDR_PI_EXTENSION' -e '$PI_DIR/extensions/no-provider.ts' "\$@"
EOF
chmod +x "$FAKEBIN/pi"

# Route every production-adapter Herdr call through the named lab helper. The
# wrapper strips only the adapter's validated trailing session pair; the helper
# adds its own exact session binding.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

# The Herdr server and every shell it creates inherit the isolated Treehouse
# root before any endpoint exists. The pane uses a throwaway HOME so the real Pi
# session is cleaned with the fixture; both the installed Herdr integration and
# the no-provider extension are loaded explicitly by the wrapper above.
export TREEHOUSE_ROOT="$POOL"
unset PI_CODING_AGENT_DIR
# Provision with the real tool path: the wrapper below is for production
# adapter calls and would recursively route the helper's own server startup.
PATH="$ORIGINAL_PATH" "$LAB_HELPER" provision "$SESSION"

PARENT_OUT=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label live-parent --no-focus)
WORKSPACE=$(printf '%s' "$PARENT_OUT" | jq -r '.result.workspace.workspace_id')
TASK_OUT=$("$LAB_HELPER" run "$SESSION" tab create --workspace "$WORKSPACE" --cwd "$PROJECT" --label "fm-$ID" --no-focus)
TAB=$(printf '%s' "$TASK_OUT" | jq -r '.result.tab.tab_id')
PANE=$(printf '%s' "$TASK_OUT" | jq -r '.result.root_pane.pane_id')
TARGET="$SESSION:$PANE"

# shellcheck disable=SC2016 # $PATH expands in the pane, after the fixed prefix.
TREEHOUSE_CMD=$(printf 'export HOME=%q PATH=%q:$PATH TREEHOUSE_ROOT=%q; treehouse get --no-fetch' "$USER_HOME" "$FAKEBIN" "$POOL")
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "$TREEHOUSE_CMD" >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null
for _ in $(seq 1 240); do
  WT=$("$LAB_HELPER" run "$SESSION" pane get "$PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null || true)
  if [ -n "$WT" ] && [ "$WT" != "$PROJECT" ] \
     && [ -f "$(dirname "$(dirname "$WT")")/treehouse-state.json" ]; then
    break
  fi
  WT=
  sleep 0.25
done
[ -n "$WT" ] || fail "real treehouse get did not settle in an isolated managed worktree"
[ "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)" = "$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir)" ] \
  || fail "real Treehouse copy does not belong to the fixture project"

# Start a real idle Pi without a positional prompt. Herdr's real Pi integration
# supplies the authority record; the test-local extension suppresses only model
# turns and trust prompts.
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" 'pi --no-context-files --no-session' >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null
OLD_SESSION=
for _ in $(seq 1 240); do
  OLD_SESSION=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null \
    | jq -r 'select(.result.agent.agent_status == "idle") | select(.result.agent.agent_session.source == "herdr:pi") | .result.agent.agent_session.value // empty' 2>/dev/null || true)
  [ -n "$OLD_SESSION" ] && break
  sleep 0.25
done
[ -n "$OLD_SESSION" ] || fail "real Pi did not acquire idle herdr:pi authority"

# Reproduce the incident: Pi exits normally, the nested shell returns, while
# Herdr retains the old idle authority and session reference.
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE" '/quit' >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null
STALE_SESSION=
for _ in $(seq 1 240); do
  process_name=$("$LAB_HELPER" run "$SESSION" pane process-info --pane "$PANE" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[0].name // empty' 2>/dev/null || true)
  STALE_SESSION=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null \
    | jq -r 'select(.result.agent.agent_status != "working") | select(.result.agent.agent_session.source == "herdr:pi") | .result.agent.agent_session.value // empty' 2>/dev/null || true)
  case "$process_name" in sh|bash|zsh|dash|ksh|fish)
    [ "$STALE_SESSION" = "$OLD_SESSION" ] && break
    ;;
  esac
  STALE_SESSION=
  sleep 0.25
done
[ "$STALE_SESSION" = "$OLD_SESSION" ] || fail "real Pi exit did not reproduce retained non-working herdr:pi authority over the nested shell"

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$ID" fixture --mode direct-PR >/dev/null
python3 - "$HOME_DIR/data/$ID/brief.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace("{TASK}", "Verify the real Herdr Pi nested-shell relaunch without making a model request.")
s = s.replace("{FIRSTMATE_SPEC}", "Remain idle after the test-local extension aborts the prompt.")
p.write_text(s)
PY
BUSY_GEN=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID")
cat > "$STATE/$ID.meta" <<EOF
window=$TARGET
endpoint_task_id=$ID
worktree=$WT
project=$PROJECT
harness=pi
kind=ship
mode=direct-PR
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE
herdr_tab_id=$TAB
herdr_pane_id=$PANE
busy_gen=$BUSY_GEN
spawn_gen=old-real-generation
EOF

OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.1 FM_CONTROL_HERDR_SAMPLE_WAIT=0.25 FM_CONTROL_LAUNCH_WAIT=60 \
  "$CONTROL" "$ID" relaunch --note 'continue in the exact real endpoint after Pi exited') \
  || fail "real Herdr Pi relaunch failed: $OUT"
assert_contains "$OUT" "relaunched $ID harness=pi" "real relaunch did not report the replacement"
[ "$(grep '^window=' "$STATE/$ID.meta" | cut -d= -f2-)" = "$TARGET" ] || fail "real relaunch changed the endpoint"
[ "$(grep '^worktree=' "$STATE/$ID.meta" | cut -d= -f2-)" = "$WT" ] || fail "real relaunch changed the Treehouse copy"
NEW_SESSION=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" \
  | jq -r 'select(.result.agent.agent_status == "working" or .result.agent.agent_status == "idle" or .result.agent.agent_status == "done" or .result.agent.agent_status == "blocked") | select(.result.agent.agent_session.source == "herdr:pi") | .result.agent.agent_session.value // empty')
[ -n "$NEW_SESSION" ] && [ "$NEW_SESSION" != "$OLD_SESSION" ] \
  || fail "real relaunch did not rotate to a distinct live herdr:pi session"
pass "real Herdr/Pi: stale nested-shell authority is released and one replacement reuses the exact endpoint and Treehouse copy"

# The ordinary direct launch half still refuses while the replacement is live;
# stale-authority repair must not weaken duplicate-worker protection.
set +e
DUP_OUT=$(PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 "$SPAWN" "$ID" --relaunch 2>&1)
DUP_RC=$?
set -e
[ "$DUP_RC" -ne 0 ] || fail "a direct relaunch unexpectedly started a duplicate real Pi"
assert_contains "$DUP_OUT" 'positively agent-free endpoint' "duplicate-worker refusal did not identify the live replacement"
AFTER_DUP_SESSION=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" | jq -r '.result.agent.agent_session.value // empty')
[ "$AFTER_DUP_SESSION" = "$NEW_SESSION" ] || fail "duplicate-worker refusal disturbed the accepted replacement authority"
pass "real Herdr/Pi: duplicate-worker refusal remains intact after stale-authority recovery"
