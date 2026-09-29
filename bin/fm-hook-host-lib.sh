#!/usr/bin/env bash
# Shared host predicate and PreToolUse decision rendering for the tracked
# hook checkers.
# This file is sourced by hook entrypoints and has no side effects on source.
# docs/arm-pretool-check.md owns the JSON documents these functions print.
#
# Why it exists: Cursor Agent CLI loads `<project>/.claude/settings.json` in
# addition to its own `<project>/.cursor/hooks.json` (verified live, cursor-agent
# 2026.08.11-e8db854). A Cursor primary running in a Firstmate checkout therefore
# fires BOTH registrations for every event Cursor's Claude-compatibility map
# covers, which would run session start twice and evaluate each PreToolUse
# seatbelt twice. Firstmate's Cursor registration owns those events, so the
# tracked Claude-shaped entry must stand down.
#
# The signal is the PAYLOAD, not the environment, and that choice is
# load-bearing. Cursor exports CURSOR_INVOKED_AS, CURSOR_PROJECT_DIR, and
# CURSOR_VERSION into every child process, so an environment guard would also
# fire inside a Claude session a human started by hand from a Cursor pane and
# would silently disable Claude's own supervision - the exact hazard
# docs/turnend-guard.md records for GROK_SESSION_ID. The delivered payload
# describes THIS event and cannot be inherited: Cursor stamps every hook payload
# with its own `cursor_version`, and Claude never emits that key.
#
# Fail direction: when the host cannot be determined (no payload, no jq), the
# caller RUNS. A redundant run under Cursor wastes work; a skipped run under
# Claude breaks the primary's supervision, which is the worse failure.

# Return 0 when payload $1 was delivered by a foreign host whose own tracked
# Firstmate registration already covers this event.
fm_hook_payload_is_foreign_host() {  # <payload>
  local payload=${1-}
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e '
    type == "object" and has("cursor_version") and (.cursor_version | type) == "string"
  ' >/dev/null 2>&1
}

# Print the allow or deny for the sourcing checker's mode, then exit.
# Unset CURSOR_MODE and CLAUDE_MODE select no-flag rendering: silent allow, and
# a deny that exits 2 with the stderr object plus the Grok stdout object.
# --cursor and --claude always print one JSON document on stdout and exit 0.
# Cursor blocks a permission hook whose stdout is not that document.
fm_hook_allow() {
  if [ "${CURSOR_MODE:-0}" -eq 1 ]; then
    printf '%s\n' '{"permission":"allow"}'
  elif [ "${CLAUDE_MODE:-0}" -eq 1 ]; then
    printf '%s\n' '{}'
  fi
  exit 0
}

fm_hook_deny() { # <json-escaped reason>
  local escaped=$1
  if [ "${CURSOR_MODE:-0}" -eq 1 ]; then
    printf '{"permission":"deny","user_message":"%s","agent_message":"%s"}\n' "$escaped" "$escaped"
    exit 0
  fi
  if [ "${CLAUDE_MODE:-0}" -eq 1 ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"},"systemMessage":"%s"}\n' "$escaped" "$escaped"
    exit 0
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}
