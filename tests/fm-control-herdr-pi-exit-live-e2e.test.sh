#!/usr/bin/env bash
# Live Herdr/Pi lifecycle guard (live-harness-optin family).
# It spends one short OpenAI-backed Pi turn in a named non-default Herdr lab,
# exits Pi through fm-control, proves Herdr retained the stale idle registration
# over a real shell-only endpoint, and relaunches through the same public verb.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_PI_EXIT_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_PI_EXIT_LIVE=1 to run the real Herdr/Pi exit-and-relaunch guard"
  exit 0
fi
for tool in herdr jq pi treehouse git; do
  command -v "$tool" >/dev/null 2>&1 || fail "FM_HERDR_PI_EXIT_LIVE=1 but $tool is not installed"
done
[ -x "$LAB_HELPER" ] || fail "the Herdr lab helper is not executable at $LAB_HELPER"

MODEL=${FM_HERDR_PI_EXIT_MODEL:-gpt-5.6-sol}
case "$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')" in
  *claude*|*anthropic*) fail "the live guard requires a non-Claude model" ;;
esac
SESSION=$("$LAB_HELPER" name herdr-pi-exit)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-pi-exit.XXXXXX")
HOME_DIR="$SCRATCH/home"
REMOTE="$SCRATCH/remote.git"
PROJECT="$SCRATCH/project"
TASK=pi-exit-live
SANITIZED=(env -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV)

cleanup() {
  if [ -f "$HOME_DIR/state/$TASK.meta" ]; then
    "${SANITIZED[@]}" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
      FM_ROOT_OVERRIDE="$ROOT" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=20 \
      "$ROOT/bin/fm-control.sh" "$TASK" exit >/dev/null 2>&1 || true
    "${SANITIZED[@]}" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
      FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" "$TASK" --force >/dev/null 2>&1 || true
  fi
  "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$TASK" "$HOME_DIR/config"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
git init --bare -q "$REMOTE"
git clone -q "$REMOTE" "$PROJECT"
git -C "$PROJECT" config user.name 'Firstmate Tests'
git -C "$PROJECT" config user.email 'tests@example.invalid'
git -C "$PROJECT" config commit.gpgsign false
printf '# lifecycle fixture\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit --no-gpg-sign -qm initial
git -C "$PROJECT" push -q -u origin HEAD
cat > "$HOME_DIR/data/$TASK/brief.md" <<'EOF'
# Task
## Captain's intent
Reply once with ready, then wait quietly for lifecycle control.

## Firstmate spec
Do not modify files.

Delivery contract: mode=local-only
EOF

"${SANITIZED[@]}" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" \
  HERDR_SESSION="$SESSION" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJECT" --mode local-only --yolo off \
    --harness pi --model "$MODEL" --effort low --backend herdr >/dev/null 2>"$SCRATCH/spawn.err" \
  || fail "Pi spawn failed: $(cat "$SCRATCH/spawn.err")"
META="$HOME_DIR/state/$TASK.meta"
PANE=$(sed -n 's/^herdr_pane_id=//p' "$META")
[ -n "$PANE" ] || fail "spawn did not record the Herdr pane"

agent_json=
agent_status=
attempt=0
while [ "$attempt" -lt 120 ]; do
  agent_json=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null || true)
  agent_status=$(printf '%s' "$agent_json" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$agent_status" in idle|done) break ;; esac
  sleep 0.5
  attempt=$((attempt + 1))
done
case "$agent_status" in idle|done) ;; *) fail "Pi did not reach an idle lifecycle point" ;; esac

exit_out=$("${SANITIZED[@]}" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
  FM_ROOT_OVERRIDE="$ROOT" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=20 \
  "$ROOT/bin/fm-control.sh" "$TASK" exit 2>&1) \
  || fail "public exit did not recognize Pi's transition to a shell: $exit_out"
case "$exit_out" in stopped\ *) ;; *) fail "public exit returned an unexpected result: $exit_out" ;; esac

agent_json=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null || true)
[ "$(printf '%s' "$agent_json" | jq -r '.result.agent.agent_status // empty')" = idle ] \
  || fail "Herdr no longer retained the stale idle Pi registration; refresh this guard's expected divergence"
process_json=$("$LAB_HELPER" run "$SESSION" pane process-info --pane "$PANE" 2>/dev/null) \
  || fail "could not read the post-Pi process shape"
printf '%s' "$process_json" | jq -e '
  .result.type == "pane_process_info"
  and (.result.process_info.foreground_processes | length == 1)
  and (.result.process_info.foreground_processes[0].name | test("(^|/)(zsh|bash|sh|dash|ksh|fish)$"))
' >/dev/null || fail "the post-Pi endpoint was not a real one-shell foreground shape"

relaunch_out=$("${SANITIZED[@]}" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
  FM_ROOT_OVERRIDE="$ROOT" FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=5 FM_CONTROL_LAUNCH_WAIT=30 \
  "$ROOT/bin/fm-control.sh" "$TASK" relaunch --harness pi --model "$MODEL" --effort low \
    --note 'continue after verified lifecycle replacement' 2>&1) \
  || fail "public relaunch still refused the shell-only endpoint: $relaunch_out"
case "$relaunch_out" in *"relaunched $TASK harness=pi"*) ;; *) fail "public relaunch returned an unexpected result: $relaunch_out" ;; esac

pass "live Herdr/Pi: stale idle registration over the post-exit shell no longer blocks public relaunch ($MODEL)"
