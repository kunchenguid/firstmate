#!/usr/bin/env bash
# Opt-in credentialed Codex guard for interactive hook-trust handling.
#
# The portable spawn regression proves the composed command shape with fake
# process surfaces.
# This guard exercises commands captured from the real fm-spawn.sh executable
# against an exact vendor Codex binary in a private tmux server.
# It gives Codex an isolated config home with one untrusted global hook and a
# trusted scratch worktree with one untrusted project hook.
# The treatment command must launch a real Codex secondmate, reach its charter,
# and suppress both hooks without showing the review dialog.
# The otherwise-identical control removes only hook suppression and must park at
# the review dialog before its charter can run.
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
  || fail "FM_CODEX_HOOK_TRUST_BIN must name an exact executable that does not inject hook-trust flags"
[ -n "$REAL_TMUX" ] || fail "tmux not found"
[ -f "$AUTH_FILE" ] || fail "Codex auth file not found at $AUTH_FILE"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-hook-trust-live.XXXXXX")
SOCKET="fm-codex-hook-trust-$$"
PROJECT="$LAB/project"
WORKTREE="$LAB/worktree"
TEST_HOME="$LAB/fmhome"
CODEX_TEST_HOME="$LAB/codex-home"
SHIM_DIR="$LAB/bin"
TASK_ID="codex-hook-secondmate-$$"
BRIEF_MARKER="$LAB/secondmate-brief-reached"
GLOBAL_HOOK_MARKER="$LAB/global-hook-fired"
PROJECT_HOOK_MARKER="$LAB/project-hook-fired"
TREAT_LOG="$LAB/treatment-launch.log"
CONTROL_LOG="$LAB/control-launch.log"
TIMEOUT=${FM_CODEX_HOOK_TRUST_LIVE_TIMEOUT:-240}

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$LAB" "/tmp/fm-$TASK_ID"
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

compose_launch() {  # <log>
  local log=$1 out status
  : > "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$log" \
    fm_test_run_spawn "$TEST_HOME" "$WORKTREE" "$FAKEBIN" \
      "$TASK_ID" "$WORKTREE" --secondmate 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "fm-spawn could not compose the Codex secondmate: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ] \
    || fail "fm-spawn emitted an unexpected secondmate launch-command count"
}

git clone -q --no-hardlinks "$ROOT" "$PROJECT" || fail "could not create scratch project"
git -C "$PROJECT" worktree add -q --detach "$WORKTREE" HEAD \
  || fail "could not create scratch worktree"
fm_test_spawn_home "$TEST_HOME" codex
FAKEBIN=$(fm_test_make_spawn_fakebin "$LAB/fake")
mkdir -p "$WORKTREE/data"
printf '%s\n' "$TASK_ID" > "$WORKTREE/.fm-secondmate-home"
printf "Run exactly \`touch %s\`, then reply with exactly BRIEF_REACHED.\n" \
  "$BRIEF_MARKER" > "$WORKTREE/data/charter.md"
compose_launch "$TREAT_LOG"
cp "$TREAT_LOG" "$CONTROL_LOG"

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
  *' --disable hooks '*) ;;
  *) fail "fm-spawn treatment command omitted --disable hooks" ;;
esac
case "$CONTROL_LAUNCH" in
  *' --disable hooks '*) ;;
  *) fail "fm-spawn control seed command omitted --disable hooks" ;;
esac
CONTROL_LAUNCH=${CONTROL_LAUNCH/ --disable hooks/}

TASK_TMP=$(sed -n 's/^tasktmp=//p' "$TEST_HOME/state/$TASK_ID.meta")
[ -n "$TASK_TMP" ] \
  || fail "fm-spawn metadata omitted a task temp root"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s hooktrust -n treatment -x 180 -y 45 \
  -c "$WORKTREE" -- env CODEX_HOME="$CODEX_TEST_HOME" \
  FM_CODEX_HOOK_TRUST_VENDOR_BIN="$CODEX_VENDOR_BIN" \
  GOTMPDIR="$TASK_TMP/gotmp" PATH="$SHIM_DIR:$PATH" \
  /bin/bash -c "$TREAT_LAUNCH" \
  || fail "could not start hook-disabled Codex treatment"

wait_for_file "$BRIEF_MARKER" \
  || { capture treatment >&2; fail "hook-disabled Codex secondmate did not reach its charter"; }
[ ! -e "$GLOBAL_HOOK_MARKER" ] && [ ! -e "$PROJECT_HOOK_MARKER" ] \
  || { capture treatment >&2; fail "hook-disabled Codex executed a hook"; }
if capture treatment | grep -Fq 'Hooks need review'; then
  capture treatment >&2
  fail "hook-disabled Codex still showed the hook-trust dialog"
fi

rm -f "$BRIEF_MARKER" "$GLOBAL_HOOK_MARKER" "$PROJECT_HOOK_MARKER"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t hooktrust: -n control -c "$WORKTREE" -- \
  env CODEX_HOME="$CODEX_TEST_HOME" \
  FM_CODEX_HOOK_TRUST_VENDOR_BIN="$CODEX_VENDOR_BIN" \
  GOTMPDIR="$TASK_TMP/gotmp" PATH="$SHIM_DIR:$PATH" \
  /bin/bash -c "$CONTROL_LAUNCH" \
  || fail "could not start hooks-enabled Codex control"

wait_for_text control 'Hooks need review' \
  || { capture control >&2; fail "hooks-enabled Codex did not reproduce the hook-trust dialog"; }
[ ! -e "$BRIEF_MARKER" ] \
  || fail "hooks-enabled Codex secondmate reached its charter while parked at hook review"
[ ! -e "$GLOBAL_HOOK_MARKER" ] && [ ! -e "$PROJECT_HOOK_MARKER" ] \
  || fail "hooks-enabled Codex ran hooks before trust was resolved"

CODEX_VERSION=$($CODEX_VENDOR_BIN --version 2>/dev/null | head -1)
printf 'ok - %s hook-disabled fm-spawn secondmate reached its charter, suppressed hooks, and showed no hook review\n' "$CODEX_VERSION"
printf 'ok - %s hooks-enabled secondmate counterfactual parked at Hooks need review before hooks or charter\n' "$CODEX_VERSION"
