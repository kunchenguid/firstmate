#!/bin/bash
# Global agent command guard, adapted for Linux/WSL2 from davidondrej/skills'
# ops-and-setup/global-agent-guardrails (upstream assumed a fixed macOS ~/.agents/hooks/ layout).
# NOT WIRED into any firstmate harness hook yet - see ../SKILL.md "Status".
#
# Blocks catastrophic shell commands before an agent runs them, given the same
# hook JSON shape Claude Code, Codex, and Cursor pass to a PreToolUse-equivalent hook.
# Denylist: dangerous-patterns.txt, resolved relative to this script by default
# (one ERE regex per line; override with FM_GUARD_PATTERNS_FILE).
#
# stdin:  hook JSON. Claude/Codex/Grok put the command at .tool_input.command
#         (Grok: .toolInput.command), Cursor at .command.
# Block:  default mode -> exit 2 + reason on stderr (Claude/Codex contract).
#         "cursor" mode -> {"permission":"deny",...} JSON on stdout, exit 0.
# Allow:  default mode -> exit 0, silent. cursor mode -> {"permission":"allow"}.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
PATTERNS_FILE="${FM_GUARD_PATTERNS_FILE:-$SCRIPT_DIR/dangerous-patterns.txt}"
MODE="${1:-exitcode}"

allow() {
  [ "$MODE" = "cursor" ] && printf '{"permission":"allow"}\n'
  exit 0
}

# Without jq we cannot inspect the command: fail open rather than break agents.
command -v jq >/dev/null 2>&1 || allow

INPUT=$(cat)
# .tool_input = Claude/Codex, .toolInput = Grok, .command = Cursor
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .toolInput.command // .command // empty' 2>/dev/null)

[ -z "$CMD" ] && allow
[ -f "$PATTERNS_FILE" ] || allow

# shellcheck disable=SC2094 # PATTERNS_FILE is only read (here and via jq --arg below), never written.
while IFS= read -r pattern; do
  case "$pattern" in '' | \#*) continue ;; esac
  if printf '%s\n' "$CMD" | grep -qE -- "$pattern" 2>/dev/null; then
    if [ "$MODE" = "cursor" ]; then
      jq -cn --arg p "$pattern" --arg f "$PATTERNS_FILE" '{
        permission: "deny",
        user_message: "Command guard blocked a dangerous command.",
        agent_message: ("This command was blocked by the dangerous-command guard (" + $f + "). Matched pattern: " + $p + ". Do not retry it or try to work around the guard; explain the block to the user instead.")
      }'
      exit 0
    fi
    echo "Blocked by the dangerous-command guard ($PATTERNS_FILE). Matched pattern: $pattern. Do not retry it or try to work around the guard; explain the block to the user instead." >&2
    exit 2
  fi
done <"$PATTERNS_FILE"

allow
