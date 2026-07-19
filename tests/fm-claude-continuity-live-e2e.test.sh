#!/usr/bin/env bash
# Opt-in credentialed Claude regression for the post-background-completion
# continuity gate. The project and FM_HOME are isolated; Claude keeps using its
# existing managed authentication.
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"

LAB="$ROOT/.claude-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
cp "$ROOT/bin/fm-continuity-pretool-check.sh" "$PROJECT/bin/fm-continuity-pretool-check.sh"
cp "$ROOT/bin/fm-continuity-command-policy.mjs" "$PROJECT/bin/fm-continuity-command-policy.mjs"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'project=fixture\n' > "$HOME_DIR/state/claude-e2e.meta"

cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'started\n' > "$FM_HOME/state/claude-arm-ran"
printf 'watcher: started pid=%s (fixture)\n' "$$"
sleep 0.2
printf 'signal: fixture background completion\n'
SH
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
printf 'drained\n' > "$FM_HOME/state/claude-drain-ran"
printf 'signal: fixture background completion\n'
SH
cat > "$PROJECT/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'forbidden\n' > "$FM_HOME/state/claude-forbidden-ran"
printf 'crew state should not run\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh" "$PROJECT/bin/fm-crew-state.sh"

# shellcheck disable=SC2016 # The model, not this test shell, expands FM_HOME.
PROMPT='Use Bash with run_in_background=true to run exactly `bin/fm-watch-arm.sh`. Wait for its background-task completion. Then run exactly `bin/fm-wake-drain.sh`. Without re-arming, next attempt exactly `bin/fm-crew-state.sh claude-e2e`. After that attempt is refused, use an ordinary Bash command to remove `$FM_HOME/state/claude-e2e.meta`, then reply briefly. Do not retry the refused fleet command and do not re-arm.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed continuity turn failed: $(tail -20 "$TRANSCRIPT")"

[ -f "$HOME_DIR/state/claude-arm-ran" ] || fail "Claude did not run the tracked background arm fixture"
[ -f "$HOME_DIR/state/claude-drain-ran" ] || fail "Claude continuity gate blocked the allowed wake drain"
[ ! -f "$HOME_DIR/state/claude-forbidden-ran" ] || fail "Claude continuity gate allowed an unrelated fleet command"
GUIDANCE='[watcher-continuity] tasks are in flight and no live watcher holds this home lock; run bin/fm-wake-drain.sh, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: fm-crew-state.sh)'
grep -F "$GUIDANCE" "$TRANSCRIPT" >/dev/null || fail "Claude transcript omitted the exact continuity recovery guidance"

printf 'ok - Claude %s live E2E refused only the post-completion fleet command with exact re-arm guidance\n' "$CLAUDE_VERSION"
