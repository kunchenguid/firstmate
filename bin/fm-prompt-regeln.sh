#!/usr/bin/env bash
# fm-prompt-regeln.sh - UserPromptSubmit hook: attach the VERFASSUNG rules
# that match the incoming prompt as additionalContext (AGENTS.md "Rule
# database and drift brake": "UserPromptSubmit injects matching contextual
# rules (bin/fm-prompt-regeln.sh)").
#
# Usage:
#   <UserPromptSubmit JSON on stdin> | bin/fm-prompt-regeln.sh
#   bin/fm-prompt-regeln.sh --help
#
# Wiring (settings.json, not owned by this file): register behind the same
# GROK skip prefix every Claude-only hook in .claude/settings.json uses -
#   [ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0; exec .../fm-prompt-regeln.sh
# - and this script repeats that check itself first, so a direct or
# mis-wired invocation under grok is still a silent no-op.
#
# Stdin contract: the UserPromptSubmit hook JSON Claude Code sends. Only
# .prompt (string) and .session_id (string) are read; everything else is
# ignored.
#
# Skip conditions (silent, exit 0, nothing on stdout or stderr):
#   - GROK_AGENT or GROK_HOOK_EVENT set - grok carries its own hook path.
#   - .prompt starts with the invisible operational mark FM_INJECT_MARK
#     (U+2063, canonical owner bin/fm-operational-input.sh). Every current
#     and legacy machine-injected message begins with this byte - typed
#     current input as "<mark>FIRSTMATE_OP: v1 <kind>: ...", legacy input
#     with the mark alone - so a single prefix check catches both forms
#     named in the brief for this file. These are never a captain prompt
#     and must never trigger retrieval or be echoed back as context.
#
# fm-regeln contract (this header is the single owner of HOW this script
# calls it; bin/fm-regeln's own CLI surface is owned there):
#   printf '%s' "$prompt" | bin/fm-regeln query --geltung firstmate
#   No top-k is passed - the CLI decides how many rules to surface from
#   regeln/VERFASSUNG.yaml itself. Exit 0 with JSONL on stdout, one rule per
#   line: {"id":"<rule id>","text":"<rule text>"}. Empty stdout is a valid
#   "no matching rule" answer. Any other exit code, a timeout, or output
#   that does not parse is treated as MISSING (fail-open, see below).
#   Resolution order: colocated "$(dirname "$0")/fm-regeln" first, then
#   PATH - the second path is what lets a test double stand in via a PATH
#   shim without touching this file's own directory.
#
# File contract (this header is the single owner):
#   $FM_HOME/state/writ-fm/.missing-notified
#     empty sentinel. Its presence means the one-time stderr diagnostic
#     ('WRIT_FM: MISSING - Kontextregeln inaktiv') has already fired; it is
#     created on the first MISSING detection and never removed by this
#     script, so the diagnostic does not repeat on every later prompt.
#   $FM_HOME/state/writ-fm/.delivered-<session_id>
#     append-only, one rule id per line: ids already delivered as full text
#     in this Claude Code session. A rule matched again in the same session
#     is repeated only as an id line ("- <id> (bereits genannt)"), never as
#     full text again, so a long session does not re-spend context on rules
#     it has already seen.
#
# Fail-open: EVERY missing dependency (jq, bin/fm-regeln, its own venv/DB
# underneath) and every fm-regeln failure or timeout is silent (exit 0, no
# stdout) except for the single stderr line above. This hook must never
# become the reason a prompt fails to submit.
set -uo pipefail

# GROK skip prefix (requirement 1) - first, before anything else runs.
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE_DIR="$FM_HOME/state/writ-fm"
MISSING_MARKER="$STATE_DIR/.missing-notified"
QUERY_TIMEOUT=20

usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

# Canonical U+2063 mark - source the single owner; fall back to the raw
# byte sequence so a missing sibling file still fails open, not closed.
if [ -r "$SCRIPT_DIR/fm-operational-input.sh" ]; then
  # shellcheck source=bin/fm-operational-input.sh disable=SC1091
  . "$SCRIPT_DIR/fm-operational-input.sh"
fi
: "${FM_INJECT_MARK:=$'\xE2\x81\xA3'}"

notify_missing() { # once-per-marker stderr diagnostic (requirement 2)
  [ -e "$MISSING_MARKER" ] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  : > "$MISSING_MARKER" 2>/dev/null
  echo 'WRIT_FM: MISSING - Kontextregeln inaktiv' >&2
}

command -v jq >/dev/null 2>&1 || { notify_missing; exit 0; }

payload="$(cat)"
prompt="$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"

[ -n "$prompt" ] || exit 0

# Machine-injected messages (requirement 4) - never rules-retrieval input.
case "$prompt" in
  "${FM_INJECT_MARK}"*) exit 0 ;;
  FM_INJECT_MARK*) exit 0 ;;
esac

# FM_REGELN_BIN overrides resolution (tests point it at a shim; an operator
# can point it at an alternate build). Otherwise colocated first, then PATH.
FM_REGELN="${FM_REGELN_BIN:-}"
if [ -z "$FM_REGELN" ]; then
  if [ -x "$SCRIPT_DIR/fm-regeln" ]; then
    FM_REGELN="$SCRIPT_DIR/fm-regeln"
  elif command -v fm-regeln >/dev/null 2>&1; then
    FM_REGELN="$(command -v fm-regeln)"
  fi
fi
[ -n "$FM_REGELN" ] && [ ! -x "$FM_REGELN" ] && FM_REGELN=""
[ -n "$FM_REGELN" ] || { notify_missing; exit 0; }

raw_rules="$(printf '%s' "$prompt" | timeout "$QUERY_TIMEOUT" "$FM_REGELN" query --geltung firstmate 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] || { notify_missing; exit 0; }
[ -n "$raw_rules" ] || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null
delivered_file="$STATE_DIR/.delivered-${session_id:-unknown}"
[ -e "$delivered_file" ] || : > "$delivered_file" 2>/dev/null

block=""
any=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  id="$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)"
  text="$(printf '%s' "$line" | jq -r '.text // empty' 2>/dev/null)"
  [ -n "$id" ] && [ -n "$text" ] || continue
  any=1
  if grep -qxF "$id" "$delivered_file" 2>/dev/null; then
    block="${block}- ${id} (bereits genannt)
"
  else
    block="${block}- [${id}] ${text}
"
    printf '%s\n' "$id" >> "$delivered_file" 2>/dev/null
  fi
done <<RULES
$raw_rules
RULES

[ "$any" -eq 1 ] || exit 0

context="Regeln aus der VERFASSUNG, passend zu diesem Prompt:
${block}"

jq -n --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
