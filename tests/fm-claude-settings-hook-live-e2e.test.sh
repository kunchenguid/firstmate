#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the per-task crewmate hooks that
# bin/fm-spawn.sh installs outside the worktree.
#
# Firstmate keeps a claude crewmate's turn-end and busy-state hooks in
# state/<id>.claude-settings.json and loads them with `claude --settings <file>`,
# because writing <worktree>/.claude/settings.local.json destroyed that file's
# committed content in every project that tracks it. Two vendor behaviors carry
# that design, and only the real binary can confirm them:
#
#   1. hooks supplied through --settings actually fire in an interactive session,
#      so the turn-end wake still reaches firstmate; and
#   2. --settings is ADDITIVE, so the project's own .claude settings still load
#      and its rules still apply to the crewmate.
#
# The lab is an isolated scratch repo and tmux server; Claude keeps using its
# existing managed authentication. No live fleet home, worktree, or session is
# touched.
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the Claude --settings hook regression"
  exit 0
fi

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

CLAUDE_VERSION=$(claude --version)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-settings-live.XXXXXX")
PROJECT="$LAB/project"
STATE="$LAB/state"
SOCK="$LAB/tmux.sock"
SESSION=fm-claude-settings-live

cleanup() {
  env -u TMUX -u TMUX_PANE tmux -S "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.claude" "$STATE"
git init -q "$PROJECT"

# The project's OWN settings, committed exactly as an affected project has them.
# Its Stop hook is the additive-load probe: if --settings replaced project
# settings instead of adding to them, this marker would never appear.
cat > "$PROJECT/.claude/settings.local.json" <<JSON
{"permissions":{"allow":["Bash(echo:*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$STATE/project-stop'"}]}]}}
JSON
git -C "$PROJECT" add -f .claude/settings.local.json
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q -m "track claude settings"
git -C "$PROJECT" ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1 \
  || fail "fixture project does not track .claude/settings.local.json"
BEFORE=$(cat "$PROJECT/.claude/settings.local.json")

# Firstmate's per-task hook file, in the shape fm-spawn writes and at the place it
# writes it: outside the worktree, in the home's state directory.
cat > "$STATE/task-live.claude-settings.json" <<JSON
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"touch '$STATE/task-live.prompt-submitted'"}]}],"Stop":[{"hooks":[{"type":"command","command":"touch '$STATE/task-live.turn-ended'"}]}]}}
JSON

tmux() { env -u TMUX -u TMUX_PANE command tmux -S "$SOCK" "$@"; }

tmux new-session -d -s "$SESSION" -c "$PROJECT" -x 200 -y 50 \
  || fail "could not start the isolated tmux server"
# The launch shape fm-spawn.sh builds for a claude crewmate.
tmux send-keys -t "$SESSION" \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --settings '$STATE/task-live.claude-settings.json' 'reply with the single word ok'" Enter

# Accept the folder-trust dialog if this scratch repo triggers one, then wait for
# the turn to complete. Both markers must appear within the budget.
deadline=$(( $(date +%s) + 300 ))
trusted=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$STATE/task-live.turn-ended" ] && [ -f "$STATE/project-stop" ]; then
    break
  fi
  if [ "$trusted" -eq 0 ] && tmux capture-pane -pt "$SESSION" 2>/dev/null | grep -q 'trust this folder'; then
    tmux send-keys -t "$SESSION" Enter
    trusted=1
  fi
  sleep 2
done

[ -f "$STATE/task-live.prompt-submitted" ] \
  || fail "Claude $CLAUDE_VERSION: --settings UserPromptSubmit hook never fired"
[ -f "$STATE/task-live.turn-ended" ] \
  || fail "Claude $CLAUDE_VERSION: --settings Stop hook never touched the turn-end marker; the crewmate turn-end wake is dead"
[ -f "$STATE/project-stop" ] \
  || fail "Claude $CLAUDE_VERSION: --settings is no longer additive; the project's own settings did not load"

AFTER=$(cat "$PROJECT/.claude/settings.local.json")
[ "$BEFORE" = "$AFTER" ] \
  || fail "Claude $CLAUDE_VERSION: the project's tracked .claude/settings.local.json was modified"
STATUS=$(git -C "$PROJECT" status --porcelain)
[ -z "$STATUS" ] || fail "Claude $CLAUDE_VERSION: the checkout was left dirty: $STATUS"

printf 'ok - Claude %s: --settings hooks fired the turn-end wake, loaded additively beside the project'"'"'s own tracked settings, and left that tracked file unmodified\n' "$CLAUDE_VERSION"
