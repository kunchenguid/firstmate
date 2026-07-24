#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: at least two complete tokenless auto-arm and rewake cycles with
# zero model-issued arm commands, the rapid started-plus-immediate-actionable
# shape closing without a multi-hour blind window, and the cooperative guard
# consuming no forced continuation while the hook's launch is healthy.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude Stop auto-arm regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json Stop registration
# (guard --claude + asyncRewake auto-arm, timeout 28800) and adds a local
# SessionStart hook that acquires the fixture home's session lock exactly the
# way bin/fm-session-start.sh does in production, plus a PreToolUse recorder.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/fm-lock.sh" }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'project=fixture\n' > "$HOME_DIR/state/task.meta"

# Rapid-death arm fixture: started plus an immediate actionable reason, the
# exact spent-Stop edge shape. Runs 1-2 close actionable; run 3 closes clean so
# a misbehaving session can never loop forever.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: the model's only allowed tool call; the second drain ends the
# in-flight need so the session can settle after two full rewake cycles.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 2 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

PROMPT='Reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 hook-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
DRAIN_RUNS=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
[ "$DRAIN_RUNS" = 2 ] || fail "expected the model to drain both wakes, got $DRAIN_RUNS drains"
REWAKES=$(grep -c 'Stop hook feedback' "$TRANSCRIPT" 2>/dev/null || true)
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q '&' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard consumed a forced continuation while the auto-arm launch was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "auto-arm epoch ledger must record the rewake outcome"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "auto-arm owner lock was left behind"

printf 'ok - Claude %s live E2E completed two tokenless Stop-owned auto-arm rewake cycles with zero model arm commands and no guard continuation\n' "$CLAUDE_VERSION"
