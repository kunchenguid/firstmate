#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for the unattended-session stand-down in
# bin/fm-sessionstart-run.sh.
# The stand-down reads CLAUDE_CODE_SESSION_ATTENDED, a value Claude Code itself
# emits, so only a real `claude -p` can prove it still marks a headless session.
# A lab Firstmate home keeps the real tracked SessionStart registration and the
# real wrapper, plus one local probe hook recording what Claude stamped into the
# hook environment, so a hook that never fired cannot pass vacuously.
#
# Cases, each in a fresh lab:
#   - `claude -p` launched as if from inside an attended interactive session
#     (the plugin-reviewer shape) records ATTENDED=0 and never takes the lock;
#   - the same launch with FM_SESSIONSTART_ALLOW_UNATTENDED=1 takes the lock,
#     proving the stand-down rather than a broken lab kept it away.
#
# Run after every Claude Code upgrade; it spends two short model turns:
#
#   FM_SESSIONSTART_UNATTENDED_LIVE_E2E=1 tests/fm-sessionstart-unattended-live-e2e.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SESSIONSTART_UNATTENDED_LIVE_E2E claude jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE FM_SESSIONSTART_ALLOW_UNATTENDED FM_NO_LOCK \
  FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

CLAUDE_VERSION=$(claude --version)
LAB="${TMPDIR:-/tmp}/fm-sessionstart-unattended-live-e2e.$$"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT INT TERM

make_lab() {  # <name> -> echoes lab dir
  local lab="$LAB/$1"
  mkdir -p "$LAB"
  # A clone carries only committed state, so copy the working-tree wrapper
  # surfaces under test over it.
  git clone -q "$ROOT" "$lab"
  cp -R "$ROOT/bin/." "$lab/bin/"
  mkdir -p "$lab/.claude" "$lab/state" "$lab/data" "$lab/config"
  # Only the tracked SessionStart registration is under test; the other tracked
  # hooks are left out so no Stop-owned rewake can outlive this short session.
  jq '{hooks: {SessionStart: .hooks.SessionStart}}' "$ROOT/.claude/settings.json" \
    > "$lab/.claude/settings.json" || fail "could not extract the tracked SessionStart registration"
  cat > "$lab/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "printf '%s\\n' \"${CLAUDE_CODE_SESSION_ATTENDED-unset}\" > \"$CLAUDE_PROJECT_DIR/attended.probe\"" }
        ]
      }
    ]
  }
}
JSON
  printf '%s\n' "$lab"
}

run_headless() {  # <lab> [env assignments...]
  local lab=$1
  shift
  (
    cd "$lab" || exit 1
    # The parent values a captain's interactive session would pass down.
    env CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli FM_HOME="$lab" "$@" \
      CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
      claude -p 'Reply with exactly: ok' --model haiku --no-session-persistence \
      --permission-mode dontAsk --settings '{"feedbackDrafts":"off"}'
  ) > "$lab/claude.out" 2>&1 </dev/null \
    || fail "Claude $CLAUDE_VERSION headless session failed: $(tail -20 "$lab/claude.out")"
}

lab=$(make_lab standdown)
run_headless "$lab"
[ -f "$lab/attended.probe" ] || fail "Claude $CLAUDE_VERSION never fired the SessionStart hook under claude -p"
[ "$(cat "$lab/attended.probe")" = 0 ] \
  || fail "Claude $CLAUDE_VERSION stamped CLAUDE_CODE_SESSION_ATTENDED=$(cat "$lab/attended.probe") into a claude -p hook; the unattended stand-down no longer recognizes headless sessions"
[ ! -e "$lab/state/.lock" ] \
  || fail "Claude $CLAUDE_VERSION headless session took the session lock: $(cat "$lab/state/.lock")"
pass "Claude $CLAUDE_VERSION: a headless claude -p session opened in the home stands down without the session lock"

lab=$(make_lab allowed)
run_headless "$lab" FM_SESSIONSTART_ALLOW_UNATTENDED=1
[ "$(cat "$lab/attended.probe" 2>/dev/null)" = 0 ] \
  || fail "Claude $CLAUDE_VERSION opted-in case did not record an unattended hook"
[ -f "$lab/state/.lock" ] \
  || fail "Claude $CLAUDE_VERSION opted-in headless session did not take the session lock, so the stand-down proof is vacuous"
pass "Claude $CLAUDE_VERSION: FM_SESSIONSTART_ALLOW_UNATTENDED=1 still runs the real session start under claude -p"
