#!/usr/bin/env bash
# Opt-in isolated real-Claude regression for the project /calm command.
set -u

if [ "${FM_CLAUDE_CALM_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_CALM_LIVE_E2E=1 to run the Claude Calm adapter regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"

LAB="$ROOT/.claude-calm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
mkdir -p "$PROJECT/.claude/commands" "$PROJECT/.claude/output-styles"
cp "$ROOT/.claude/commands/calm.md" "$PROJECT/.claude/commands/calm.md"
cp "$ROOT/.claude/output-styles/firstmate-calm.md" "$PROJECT/.claude/output-styles/firstmate-calm.md"

# The real settings registration stays intact, but this fixture suppresses the
# unrelated session-start digest so the model receives only the Calm hook's
# presentation instruction.
cat > "$PROJECT/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$PROJECT/bin/fm-sessionstart-nudge.sh"

cat > "$PROJECT/AGENTS.md" <<'MD'
# Claude Calm fixture

Follow the prompt exactly and do not run tools unless the prompt asks for them.
MD

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
printf 'on\n' > "$HOME_DIR/config/calm"
run_claude() {
  local prompt=$1 output=$2
  (
    cd "$PROJECT" || exit 1
    FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
      claude -p "$prompt" --dangerously-skip-permissions --effort low --output-format text
  ) > "$output" 2>&1
}

COMMAND_OUT="$LAB/command.out"
run_claude '/calm' "$COMMAND_OUT" \
  || fail "Claude Calm command fixture failed: $(tail -20 "$COMMAND_OUT")"
[ "$(cat "$HOME_DIR/config/calm")" = off ] \
  || fail "real Claude /calm command did not atomically toggle the shared preference off"

printf 'ok - Claude %s runs the project /calm command in an isolated fixture\n' "$CLAUDE_VERSION"
