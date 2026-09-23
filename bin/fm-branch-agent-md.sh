#!/usr/bin/env bash
# fm-branch-agent-md.sh - regenerate the Claude Code supervision-branch agent
# definition shipped by the fm-branch-mod plugin (docs/claude-supervision-branch.md).
#
# The generated file is .claude/mods/fm-branch-mod/agents/fm-branch.md: a
# Claude Code agent frontmatter block, the verbatim output of
# bin/fm-branch-prompt.sh, and a fixed addendum that adapts the Pi-shaped
# prompt to one persistent Claude Code background agent. Like the prompt it
# wraps, the output is a pure function of tracked files, so it is committed and
# regenerated only when bin/fm-branch-prompt.sh or this script changes.
# tests/fm-branch-claude-mod.test.sh holds the committed copy to --check.
#
# Usage:
#   bin/fm-branch-agent-md.sh          rewrite the agent file in place
#   bin/fm-branch-agent-md.sh --check  exit 1 and name the file when it is stale
#   bin/fm-branch-agent-md.sh --print  write the generated text to stdout only
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_TRACKED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$FM_TRACKED_ROOT/.claude/mods/fm-branch-mod/agents/fm-branch.md"

generate() {
  cat <<'FM'
---
name: fm-branch
description: firstmate supervision branch. Spawned once per session by the fm-branch-mod hooks module; later wakes arrive as messages. Never dispatch it by hand.
tools: Bash, mcp__fm-branch-mod__fm_branch_report
---
FM
  # The prompt embeds a skill written under .agents/skills/<name>/; its
  # repository-relative links are one directory deeper from agents/ here.
  "$SCRIPT_DIR/fm-branch-prompt.sh" | sed 's|](\.\./\.\./\.\./|](../../../../|g'
  cat <<'FM'

# Claude Code hooks-module addendum (one persistent branch agent)

You are ONE persistent background agent inside the captain's Claude Code process. The fm-branch-mod hooks module spawned you once; every later fleet wake reaches you as a new message in this same conversation, so you remember every wake you already handled. There is no fm-main-mirror channel here.
Each message that begins `FIRSTMATE SUPERVISION WAKE:` is one wake: handle it per your operating procedure, call the report tool exactly once for it, run the exact `--ack-through` command the drain printed, then end your turn with the single word `done`. Nothing else in your final message: no summary, no address to anyone.
Your memory is the guard against re-escalation: a `done:`, `blocked:` or `needs-decision:` line you already reported on an earlier wake is history. On a later wake, judge only the status lines that are NEW since the wake you last handled for that task; report verdict captain only for a NEW captain-class line. When the drain presents no new captain-class line, the wake is routine even if an old terminal line is still visible in the log.
Your shell already carries FM_SUPERVISION_ACTOR=branch, FM_LEASE_HOLDER_PID, and FM_HOME for this home; never change them and never set FM_HOME yourself.
Run every firstmate script from the working directory with a relative path such as `bin/fm-wake-drain.sh`; the scripts resolve this home's records from FM_HOME on their own.
This home's records live under $FM_HOME/state and $FM_HOME/data: read `$FM_HOME/state/<task>.status`, never a bare `state/<task>.status`.
The drain prints the exact records you own and their file paths; `bin/fm-crew-state.sh <task>` reads current state; you rarely need anything else for a routine wake. Keep each wake short: drain, at most one or two reads, report, acknowledge, `done`.
The report tool is named `mcp__fm-branch-mod__fm_branch_report`; it is the fm_branch_report your operating procedure names. A second report for the same wake is refused; do not retry it.
Never spawn agents, never use any tool other than Bash and the report tool, never send messages to anyone, and never read the captain's conversation.
FM
}

case "${1:-}" in
  --print)
    generate
    ;;
  --check)
    if ! generate | cmp -s - "$OUT"; then
      echo "stale: $OUT (run bin/fm-branch-agent-md.sh)" >&2
      exit 1
    fi
    ;;
  '')
    mkdir -p "$(dirname "$OUT")"
    generate > "$OUT.tmp"
    mv -f "$OUT.tmp" "$OUT"
    ;;
  *)
    echo "usage: fm-branch-agent-md.sh [--check|--print]" >&2
    exit 2
    ;;
esac
