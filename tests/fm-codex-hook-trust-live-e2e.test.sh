#!/usr/bin/env bash
# Opt-in credentialed Codex guard for interactive hook-trust handling.
#
# The portable spawn regression proves the composed command shape with fake
# process surfaces.
# This guard exercises commands captured from the real fm-spawn.sh executable
# against an exact vendor Codex binary in a private tmux server.
# It gives Codex an isolated config home with one untrusted global hook and a
# trusted scratch worktree with one untrusted project hook.
# The treatment command must reach its brief, run the global hook, and emit the
# existing notify= turn-end marker without showing the review dialog.
# The otherwise-identical control removes only the bypass flag and must park at
# the review dialog before its brief or notify marker can fire.
set -u

if [ "${FM_CODEX_HOOK_TRUST_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_HOOK_TRUST_LIVE_E2E=1 and FM_CODEX_HOOK_TRUST_BIN to run the Codex hook-trust regression"
  exit 0
fi

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CODEX_VENDOR_BIN=${FM_CODEX_HOOK_TRUST_BIN:-}
REAL_TMUX=$(command -v tmux || true)
AUTH_FILE=${FM_CODEX_HOOK_TRUST_AUTH_FILE:-${HOME}/.codex/auth.json}

[ -x "$CODEX_VENDOR_BIN" ] \
  || fail "FM_CODEX_HOOK_TRUST_BIN must name an exact executable that does not inject --dangerously-bypass-hook-trust"
[ -n "$REAL_TMUX" ] || fail "tmux not found"
[ -f "$AUTH_FILE" ] || fail "Codex auth file not found at $AUTH_FILE"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-hook-trust-live.XXXXXX")
SOCKET="fm-codex-hook-trust-$$"
PROJECT="$LAB/project"
WORKTREE="$LAB/worktree"
TEST_HOME="$LAB/fmhome"
CODEX_TEST_HOME="$LAB/codex-home"
SHIM_DIR="$LAB/bin"
TREAT_ID="codex-hook-treatment-$$"
CONTROL_ID="codex-hook-control-$$"
TREAT_BRIEF_MARKER="$LAB/treatment-brief-reached"
CONTROL_BRIEF_MARKER="$LAB/control-brief-reached"
GLOBAL_HOOK_MARKER="$LAB/global-hook-fired"
PROJECT_HOOK_MARKER="$LAB/project-hook-fired"
TREAT_LOG="$LAB/treatment-launch.log"
CONTROL_LOG="$LAB/control-launch.log"
TIMEOUT=${FM_CODEX_HOOK_TRUST_LIVE_TIMEOUT:-240}

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$LAB" "/tmp/fm-$TREAT_ID" "/tmp/fm-$CONTROL_ID"
}
trap cleanup EXIT INT TERM

capture() {  # <window>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "hooktrust:$1" -S -500 2>/dev/null || true
}

wait_for_file() {  # <path>
  local path=$1 i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -e "$path" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

wait_for_text() {  # <window> <text>
  local window=$1 expected=$2 i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    capture "$window" | grep -Fq "$expected" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

compose_launch() {  # <task-id> <brief-marker> <log>
  local task_id=$1 brief_marker=$2 log=$3 out status
  fm_test_spawn_brief "$TEST_HOME" "$task_id" \
    "Run exactly \`touch $brief_marker\`, then reply with exactly BRIEF_REACHED."
  : > "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$log" \
    fm_test_run_spawn "$TEST_HOME" "$WORKTREE" "$FAKEBIN" \
      "$task_id" "$PROJECT" --scout 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "fm-spawn could not compose $task_id: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] \
    || fail "fm-spawn emitted an unexpected launch-command count for $task_id"
}

git clone -q --no-hardlinks "$ROOT" "$PROJECT" || fail "could not create scratch project"
git -C "$PROJECT" worktree add -q --detach "$WORKTREE" HEAD \
  || fail "could not create scratch worktree"
fm_test_spawn_home "$TEST_HOME" codex
FAKEBIN=$(fm_test_make_spawn_fakebin "$LAB/fake")
compose_launch "$TREAT_ID" "$TREAT_BRIEF_MARKER" "$TREAT_LOG"
compose_launch "$CONTROL_ID" "$CONTROL_BRIEF_MARKER" "$CONTROL_LOG"

mkdir -p "$WORKTREE/.codex" "$CODEX_TEST_HOME" "$SHIM_DIR"
cat > "$WORKTREE/.codex/hooks.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc 'touch $PROJECT_HOOK_MARKER'",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF
cat > "$CODEX_TEST_HOME/config.toml" <<EOF
[projects."$WORKTREE"]
trust_level = "trusted"

[features]
hooks = true
EOF
cat > "$CODEX_TEST_HOME/hooks.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -lc 'touch $GLOBAL_HOOK_MARKER'",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF
ln -s "$AUTH_FILE" "$CODEX_TEST_HOME/auth.json"
cat > "$SHIM_DIR/codex" <<'EOF'
#!/usr/bin/env bash
exec "${FM_CODEX_HOOK_TRUST_VENDOR_BIN:?}" "$@"
EOF
chmod +x "$SHIM_DIR/codex"

TREAT_LAUNCH=$(cat "$TREAT_LOG")
CONTROL_LAUNCH=$(cat "$CONTROL_LOG")
case "$TREAT_LAUNCH" in
  *' --dangerously-bypass-hook-trust '*) ;;
  *) fail "fm-spawn treatment command omitted --dangerously-bypass-hook-trust" ;;
esac
case "$CONTROL_LAUNCH" in
  *' --dangerously-bypass-hook-trust '*) ;;
  *) fail "fm-spawn control seed command omitted --dangerously-bypass-hook-trust" ;;
esac
CONTROL_LAUNCH=${CONTROL_LAUNCH/ --dangerously-bypass-hook-trust/}

TREAT_TASK_TMP=$(sed -n 's/^tasktmp=//p' "$TEST_HOME/state/$TREAT_ID.meta")
CONTROL_TASK_TMP=$(sed -n 's/^tasktmp=//p' "$TEST_HOME/state/$CONTROL_ID.meta")
[ -n "$TREAT_TASK_TMP" ] && [ -n "$CONTROL_TASK_TMP" ] \
  || fail "fm-spawn metadata omitted a task temp root"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s hooktrust -n treatment -x 180 -y 45 \
  -c "$WORKTREE" -- env CODEX_HOME="$CODEX_TEST_HOME" \
  FM_CODEX_HOOK_TRUST_VENDOR_BIN="$CODEX_VENDOR_BIN" \
  GOTMPDIR="$TREAT_TASK_TMP/gotmp" PATH="$SHIM_DIR:$PATH" \
  /bin/bash -c "$TREAT_LAUNCH" \
  || fail "could not start flagged Codex treatment"

wait_for_file "$TREAT_BRIEF_MARKER" \
  || { capture treatment >&2; fail "flagged Codex did not reach the launch brief"; }
wait_for_file "$TEST_HOME/state/$TREAT_ID.turn-ended" \
  || { capture treatment >&2; fail "flagged Codex did not emit the notify= turn-end signal"; }
[ -e "$GLOBAL_HOOK_MARKER" ] \
  || { capture treatment >&2; fail "flagged Codex did not run the enabled global hook"; }
if capture treatment | grep -Fq 'Hooks need review'; then
  capture treatment >&2
  fail "flagged Codex still showed the hook-trust dialog"
fi

rm -f "$GLOBAL_HOOK_MARKER" "$PROJECT_HOOK_MARKER"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t hooktrust: -n control -c "$WORKTREE" -- \
  env CODEX_HOME="$CODEX_TEST_HOME" \
  FM_CODEX_HOOK_TRUST_VENDOR_BIN="$CODEX_VENDOR_BIN" \
  GOTMPDIR="$CONTROL_TASK_TMP/gotmp" PATH="$SHIM_DIR:$PATH" \
  /bin/bash -c "$CONTROL_LAUNCH" \
  || fail "could not start unflagged Codex control"

wait_for_text control 'Hooks need review' \
  || { capture control >&2; fail "unflagged Codex did not reproduce the hook-trust dialog"; }
[ ! -e "$CONTROL_BRIEF_MARKER" ] \
  || fail "unflagged Codex reached the brief while parked at hook review"
[ ! -e "$TEST_HOME/state/$CONTROL_ID.turn-ended" ] \
  || fail "unflagged Codex emitted the turn-end signal while parked at hook review"
[ ! -e "$GLOBAL_HOOK_MARKER" ] && [ ! -e "$PROJECT_HOOK_MARKER" ] \
  || fail "unflagged Codex ran hooks before trust was resolved"

CODEX_VERSION=$($CODEX_VENDOR_BIN --version 2>/dev/null | head -1)
printf 'ok - %s flagged fm-spawn launch reached the brief, ran the global hook, emitted notify, and showed no hook review\n' "$CODEX_VERSION"
printf 'ok - %s unflagged counterfactual parked at Hooks need review before hooks, brief, or notify\n' "$CODEX_VERSION"
