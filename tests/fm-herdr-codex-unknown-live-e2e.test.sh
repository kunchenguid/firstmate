#!/usr/bin/env bash
# Live Codex exit and relaunch guard for Herdr's stale unknown registration.
# The harness is launched without a prompt, then its exact lab-owned process
# receives SIGTERM while Herdr still reports unknown. Relaunch submits the
# disposable brief, so this guard is opt-in.
# Every Herdr call, including backend and control calls via the PATH shim,
# routes through fm-herdr-lab.sh with an exact trailing named session.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
fm_live_gate opt-in FM_HERDR_CODEX_UNKNOWN_LIVE_E2E herdr codex jq
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_REAL_BIN=$(command -v herdr)
HERDR_VERSION=$(herdr --version)
CODEX_VERSION=$(codex --version)
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-unknown1)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

mkdir -p "$ROOT/state"
SCRATCH=$(mktemp -d "$ROOT/state/fm-herdr-unknown1.XXXXXX")
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_REAL_BIN
export HERDR_ORIGINAL_PATH=$PATH
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/state" "$SCRATCH/home/data/labtask" "$SCRATCH/repo"
cat > "$SCRATCH/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
  exec "$HERDR_REAL_BIN" --version
fi
[ "$#" -ge 3 ] || { echo "lab wrapper: missing scoped command" >&2; exit 2; }
args=("$@")
count=${#args[@]}
[ "${args[count-2]}" = --session ] && [ "${args[count-1]}" = "$HERDR_LAB_SESSION" ] \
  || { echo "lab wrapper: exact trailing session required" >&2; exit 2; }
PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]:0:count-2}"
SH
chmod +x "$SCRATCH/bin/herdr"
export PATH="$SCRATCH/bin:$PATH"
trap 'PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT

git -C "$SCRATCH/repo" init -q
printf 'candidate retained\n' > "$SCRATCH/repo/README.md"
git -C "$SCRATCH/repo" add README.md
git -C "$SCRATCH/repo" -c user.name=Lab -c user.email=lab@example.invalid commit -qm candidate
git -C "$SCRATCH/repo" worktree add --quiet -b labtask "$SCRATCH/worktree"
HEAD_BEFORE=$(git -C "$SCRATCH/worktree" rev-parse HEAD)
cat > "$SCRATCH/home/data/labtask/brief.md" <<'EOF'
# Task
## Captain's intent
Verify a safe isolated Codex recovery.

## Firstmate spec
Resume only the disposable lab task in its committed worktree.
EOF

WS=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --label fm-unknown-probe --cwd "$SCRATCH/worktree")
PANE_ID=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
PANE_RECORD=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$PANE_ID")
TAB_ID=$(printf '%s' "$PANE_RECORD" | jq -r '.result.pane.tab_id')
WORKSPACE_ID=${PANE_ID%%:*}
cat > "$SCRATCH/home/state/labtask.meta" <<EOF
window=$HERDR_LAB_SESSION:$PANE_ID
endpoint_task_id=labtask
worktree=$SCRATCH/worktree
project=$SCRATCH/repo
harness=codex
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$WORKSPACE_ID
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE_ID
EOF

"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE_ID" bash
sleep 0.5
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE_ID" codex
sleep 1
INFO=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane process-info --pane "$PANE_ID")
CODEX_PID=$(printf '%s' "$INFO" | jq -r '.result.process_info.foreground_processes[] | select(.name=="codex") | .pid')
STATUS_BEFORE=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$PANE_ID" | jq -r '.result.agent.agent_status')
[ "$STATUS_BEFORE" = unknown ] && [ -n "$CODEX_PID" ] && [ "$CODEX_PID" != null ]
printf 'running_registration=%s running_pid=%s\n' "$STATUS_BEFORE" "$CODEX_PID"
kill -TERM "$CODEX_PID"
for _ in $(seq 1 60); do
  INFO=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane process-info --pane "$PANE_ID")
  if printf '%s' "$INFO" | jq -e '.result.process_info.foreground_processes | length == 1 and .[0].name == "bash"' >/dev/null; then
    break
  fi
  sleep 0.2
done
printf '%s' "$INFO" | jq -e '.result.process_info.foreground_processes | length == 1 and .[0].name == "bash"' >/dev/null
STATUS_AFTER=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent get "$PANE_ID" | jq -r '.result.agent.agent_status')
[ "$STATUS_AFTER" = unknown ]
printf 'shell_only=%s stale_registration=%s\n' "$(printf '%s' "$INFO" | jq -c '.result.process_info.foreground_processes | map({name,pid})')" "$STATUS_AFTER"

. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
printf 'pane_state=%s recovery_state=%s husk=%s\n' \
  "$(fm_backend_herdr_pane_agent_state "$HERDR_LAB_SESSION" "$PANE_ID")" \
  "$(fm_backend_agent_state herdr "$HERDR_LAB_SESSION:$PANE_ID")" \
  "$(fm_backend_herdr_tab_is_husk "$HERDR_LAB_SESSION" "$PANE_ID" && echo yes || echo no)"

set +e
OUT=$(FM_HOME="$SCRATCH/home" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
  "$ROOT/bin/fm-control.sh" labtask relaunch --note "Resume from the committed candidate." 2>&1)
RC=$?
set -e
printf 'control_rc=%s\n' "$RC"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; echo "not ok - relaunch refused the shell-only unknown pane [$HERDR_VERSION, $CODEX_VERSION]" >&2; exit 1; }
printf 'candidate_head_before=%s candidate_head_after=%s endpoint=%s\n' \
  "$HEAD_BEFORE" "$(git -C "$SCRATCH/worktree" rev-parse HEAD)" \
  "$(sed -n 's/^window=//p' "$SCRATCH/home/state/labtask.meta" | tail -1)"
[ "$(git -C "$SCRATCH/worktree" rev-parse HEAD)" = "$HEAD_BEFORE" ]
[ "$(sed -n 's/^window=//p' "$SCRATCH/home/state/labtask.meta" | tail -1)" = "$HERDR_LAB_SESSION:$PANE_ID" ]
for _ in $(seq 1 60); do
  [ "$(fm_backend_herdr_pane_process_state "$HERDR_LAB_SESSION" "$PANE_ID")" != agent ] || break
  sleep 0.2
done
[ "$(fm_backend_herdr_pane_process_state "$HERDR_LAB_SESSION" "$PANE_ID")" = agent ]
printf 'ok - %s + %s: shell-only unknown registration relaunches Codex in the same pane and committed worktree\n' \
  "$HERDR_VERSION" "$CODEX_VERSION"
export PATH="$HERDR_ORIGINAL_PATH"
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null
sleep 1
rm -rf "$SCRATCH"
