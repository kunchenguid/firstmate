#!/usr/bin/env bash
# Live Codex exit and relaunch guard for Herdr's stale unknown registration.
# Real Codex runs one trivial turn in a disposable committed worktree, quits
# orderly with /quit, and shell output then follows it in the same pane, the
# shape a Firstmate steering nudge leaves behind a finished worker. Herdr keeps
# the record but drops its agent label: `agent get` reads `agent_status`
# unknown with no `agent` while `agent_session` still names Codex. The guard
# asserts that shape, that the classifier recovers it, and that a relaunch
# through fm-control.sh reuses the same pane with the committed candidate
# intact. Codex's directory-trust dialog is answered with Enter, as any first
# launch in a new project root is. A transient "Approaching rate limits"
# model-suggestion dialog, which Codex pops once a turn settles under low
# quota, is dismissed with Escape before /quit because while it is up it
# captures input and swallows the command. The relaunch submits the disposable
# brief, so this guard is opt-in.
# Every Herdr call, including backend and control calls via the PATH shim,
# routes through fm-herdr-lab.sh with an exact trailing named session.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
fm_live_gate opt-in FM_HERDR_CODEX_UNKNOWN_LIVE_E2E herdr codex jq
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_REAL_BIN=$(command -v herdr)
HERDR_VERSION=$(herdr --version)
CODEX_VERSION=$(codex --version)
herdr_forget_inherited_pane
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-unknown1)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_REAL_BIN
export HERDR_ORIGINAL_PATH=$PATH
SCRATCH=
cleanup() {
  local status=$?
  PATH=$HERDR_ORIGINAL_PATH "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

version_fail() {  # <message>
  echo "not ok - $1 [$HERDR_VERSION, $CODEX_VERSION]" >&2
  exit 1
}
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
record() { lab agent get "$PANE_ID" | jq -c '.result | {type, agent: .agent.agent, agent_status: .agent.agent_status, pane_id: .agent.pane_id, agent_session: .agent.agent_session}'; }
foreground() { lab pane process-info --pane "$PANE_ID" | jq -c '.result.process_info.foreground_processes | map({name,argv0,argv,cmdline})'; }
shell_only() { lab pane process-info --pane "$PANE_ID" | jq -e '.result.process_info.foreground_processes | length == 1 and .[0].name == "bash"' >/dev/null; }
wait_until() {  # <tries> <interval> <command...>
  local tries=$1 interval=$2
  shift 2
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep "$interval"
  done
  return 1
}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-unknown1.XXXXXX")
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

WS=$(lab workspace create --label fm-unknown-probe --cwd "$SCRATCH/worktree")
PANE_ID=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
TAB_ID=$(lab pane get "$PANE_ID" | jq -r '.result.pane.tab_id')
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

# A real session: Codex answers one trivial prompt so Herdr records its
# agent_session, answering the startup trust dialog with Enter when Herdr
# reports it as the blocker.
lab pane run "$PANE_ID" bash
sleep 0.5
lab pane run "$PANE_ID" "codex 'Reply with only the word ready.'"
session_established() {
  local status
  status=$(lab agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  [ "$status" != blocked ] || lab pane send-keys "$PANE_ID" Enter >/dev/null
  lab agent get "$PANE_ID" 2>/dev/null \
    | jq -e '.result.agent | .agent_status == "idle" and .agent_session.agent == "codex"' >/dev/null 2>&1
}
wait_until 120 1 session_established \
  || version_fail "codex never reached idle with a recorded agent_session in 120s: $(record)"
printf 'running_registration=%s\n' "$(record)"
printf 'running_foreground=%s\n' "$(foreground)"

rate_limit_dialog_up() {
  lab pane read "$PANE_ID" 2>/dev/null | grep -q 'esc to go back'
}
# Escape backs out of the model-suggestion dialog without changing any model
# setting; Enter would accept its default (switching the model).
dismiss_rate_limit_dialog() {
  while rate_limit_dialog_up; do
    lab pane send-keys "$PANE_ID" Escape
    sleep 0.5
  done
}
tries=0
until shell_only; do
  tries=$((tries + 1))
  [ "$tries" -le 3 ] || version_fail "codex did not exit to a shell after /quit: $(foreground)"
  # /quit typed while the suggestion dialog is up never reaches the composer,
  # so every attempt dismisses it first and submits a fresh /quit.
  dismiss_rate_limit_dialog
  lab pane send-text "$PANE_ID" /quit
  sleep 1.2
  lab pane send-keys "$PANE_ID" Enter
  wait_until 50 0.2 shell_only || true
done
printf 'shell_only_foreground=%s\n' "$(foreground)"

# Shell output after the exit is what makes Herdr re-detect the pane and drop
# the agent label while keeping the record.
lab pane run "$PANE_ID" ':'
unlabeled_unknown() {
  lab agent get "$PANE_ID" | jq -e --arg pane "$PANE_ID" '
    .result.type == "agent_info"
    and .result.agent.pane_id == $pane
    and .result.agent.agent_status == "unknown"
    and (.result.agent.agent == null)
    and .result.agent.agent_session.agent == "codex"
  ' >/dev/null
}
wait_until 120 1 unlabeled_unknown \
  || version_fail "herdr did not leave an unlabeled unknown registration over the shell-only pane within 120s: $(record)"
printf 'stale_registration=%s\n' "$(record)"

. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
PANE_STATE=$(fm_backend_herdr_pane_agent_state "$HERDR_LAB_SESSION" "$PANE_ID")
RECOVERY_STATE=$(fm_backend_agent_state herdr "$HERDR_LAB_SESSION:$PANE_ID")
HUSK=$(fm_backend_herdr_tab_is_husk "$HERDR_LAB_SESSION" "$PANE_ID" && echo yes || echo no)
printf 'pane_state=%s recovery_state=%s husk=%s\n' "$PANE_STATE" "$RECOVERY_STATE" "$HUSK"
[ "$PANE_STATE $RECOVERY_STATE $HUSK" = "stale-agent dead no" ] \
  || version_fail "the unlabeled unknown registration must read stale-agent, recover as dead, and refuse husk closing; got '$PANE_STATE $RECOVERY_STATE husk=$HUSK'"

set +e
OUT=$(FM_HOME="$SCRATCH/home" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
  "$ROOT/bin/fm-control.sh" labtask relaunch --note "Resume from the committed candidate." 2>&1)
RC=$?
set -e
printf 'control_rc=%s\n' "$RC"
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" >&2; version_fail "relaunch refused the shell-only unknown pane"; }
HEAD_AFTER=$(git -C "$SCRATCH/worktree" rev-parse HEAD)
ENDPOINT=$(sed -n 's/^window=//p' "$SCRATCH/home/state/labtask.meta" | tail -1)
printf 'candidate_head_before=%s candidate_head_after=%s endpoint=%s\n' "$HEAD_BEFORE" "$HEAD_AFTER" "$ENDPOINT"
[ "$HEAD_AFTER" = "$HEAD_BEFORE" ] || version_fail "relaunch moved the committed candidate"
[ "$ENDPOINT" = "$HERDR_LAB_SESSION:$PANE_ID" ] || version_fail "relaunch moved the task off its pane"
process_is_agent() { [ "$(fm_backend_herdr_pane_process_state "$HERDR_LAB_SESSION" "$PANE_ID")" = agent ]; }
wait_until 60 0.2 process_is_agent || version_fail "no codex process reached the relaunched pane: $(foreground)"
printf 'ok - %s + %s: an unlabeled unknown registration over a shell-only pane relaunches Codex in the same pane and committed worktree\n' \
  "$HERDR_VERSION" "$CODEX_VERSION"
