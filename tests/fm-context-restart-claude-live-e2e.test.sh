#!/usr/bin/env bash
# Opt-in credentialed proof that the installed Claude Stop payload names a real
# transcript whose latest assistant usage matches Firstmate's context accounting.
set -u

if [ "${FM_CONTEXT_RESTART_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CONTEXT_RESTART_CLAUDE_LIVE_E2E=1 to run the Claude context-refresh regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

LAB="$ROOT/.context-restart-claude-live.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
RESULT="$LAB/result.json"
CLAUDE_VERSION=$(claude --version)
TRANSCRIPT=

cleanup() {
  [ -z "$TRANSCRIPT" ] || rm -f "$TRANSCRIPT" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "cat > \"$FM_HOME/state/live-context-stop-payload.json\""
          }
        ]
      }
    ]
  }
}
JSON
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf '999999999\n' > "$HOME_DIR/config/context-restart-budget"
printf '7500\n' > "$HOME_DIR/config/startup-memory-budget"

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p 'Reply with exactly CONTEXT_REFRESH_LIVE_OK.' \
      --dangerously-skip-permissions --effort low --output-format json
) > "$RESULT" 2> "$LAB/claude.err" \
  || fail "Claude context-refresh live session failed: $(tail -20 "$LAB/claude.err")"

PAYLOAD="$HOME_DIR/state/live-context-stop-payload.json"
[ -f "$PAYLOAD" ] || fail "the real Claude Stop hook did not publish its payload"
TRANSCRIPT=$(jq -er '.transcript_path | select(type == "string" and length > 0)' "$PAYLOAD") \
  || fail "the real Stop payload did not carry transcript_path"
SESSION_ID=$(jq -er '.session_id | select(type == "string" and length > 0)' "$PAYLOAD") \
  || fail "the real Stop payload did not carry session_id"
[ -f "$TRANSCRIPT" ] || fail "the real Stop transcript path was not readable"

COMPUTED=$(bash -c '. "$1"; fm_context_restart_transcript_tokens "$2"' \
  _ "$ROOT/bin/fm-context-restart-lib.sh" "$TRANSCRIPT") \
  || fail "Firstmate could not account for the real Claude transcript"
EXPECTED=$(jq -r '
  .usage
  | .input_tokens
    + (.cache_creation_input_tokens // 0)
    + (.cache_read_input_tokens // 0)
    + (.output_tokens // 0)
' "$RESULT") || fail "could not account for Claude's result usage"
[ "$COMPUTED" = "$EXPECTED" ] \
  || fail "transcript context $COMPUTED did not match Claude result usage $EXPECTED"
case "$COMPUTED" in ''|0|*[!0-9]*) fail "real Claude context total was not positive: $COMPUTED" ;; esac
[ ! -e "$HOME_DIR/state/.context-restart-crossing" ] \
  || fail "the high-budget live session unexpectedly published a crossing"
[ "$(jq -r '.result' "$RESULT")" = CONTEXT_REFRESH_LIVE_OK ] \
  || fail "the live fixture did not complete its one ordinary under-budget turn"

printf 'ok - Claude %s live Stop payload session=%s exposed transcript usage=%s and stayed inert below budget\n' \
  "$CLAUDE_VERSION" "$SESSION_ID" "$COMPUTED"
