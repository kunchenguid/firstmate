#!/usr/bin/env bash
# Shared "which harness delivered this hook payload?" predicate for the tracked
# Claude-shaped hook entries.
# This file is sourced by hook entrypoints and has no side effects on source.
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
# GitHub Copilot CLI also loads `<project>/.claude/settings.json` and delivers
# Claude-shaped payloads (docs/verification/copilot.md "Claude-shaped payloads").
# It has no `cursor_version`; every payload it sends carries an ISO-8601 string
# `timestamp`, which Claude's SessionStart, PreToolUse, UserPromptSubmit, and
# Stop payloads do not (real payloads compared, copilot 1.0.105 and Claude Code
# 2.x). The discriminator is also made conjunctive with three keys Claude sends
# on its other events and Copilot never does (`permission_mode`, `prompt_id`,
# `tool_use_id`), so a future Claude `timestamp` cannot silently disable
# Claude's own supervision. Copilot has no `asyncRewake`, so the tracked auto-arm
# would otherwise hold its turn end for the declared 28800 s timeout.
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
  if printf '%s' "$payload" | jq -e '
    type == "object" and has("cursor_version") and (.cursor_version | type) == "string"
  ' >/dev/null 2>&1; then
    return 0
  fi
  fm_hook_payload_is_copilot "$payload"
}

# Return 0 when payload $1 was delivered by GitHub Copilot CLI.
fm_hook_payload_is_copilot() {  # <payload>
  local payload=${1-}
  [ -n "$payload" ] || return 1
  # Two payload-independent signals, so a changed or missing `timestamp` cannot
  # re-enable the Claude auto-arm Stop hook (an 8-hour hold). Copilot sets
  # COPILOT_HOOK_DEPTH for hooks only, never for its tool shells, and a hook's
  # parent process is `copilot` itself (docs/verification/copilot.md).
  case "${COPILOT_HOOK_DEPTH:-}" in ''|*[!0-9]*|0*) ;; *) return 0 ;; esac
  # The payload test is cheaper than sourcing a library and forking ps, so it runs first.
  if command -v jq >/dev/null 2>&1 && printf '%s' "$payload" | jq -e '
    type == "object"
    and (.timestamp | type) == "string"
    and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$"))
    and ((has("permission_mode") or has("prompt_id") or has("tool_use_id")) | not)
  ' >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=bin/fm-cursor-lib.sh
  [ -r "${BASH_SOURCE[0]%/*}/fm-cursor-lib.sh" ] && . "${BASH_SOURCE[0]%/*}/fm-cursor-lib.sh" \
    && fm_copilot_args_are_copilot "$(ps -o args= -p "$PPID" 2>/dev/null)" "$PPID"
}
