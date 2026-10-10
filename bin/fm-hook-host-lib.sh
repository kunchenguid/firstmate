#!/usr/bin/env bash
# Shared "which harness delivered this hook payload?" predicate for the tracked
# Claude-shaped hook entries, plus the Pi-hosted Cursor SDK reply shim below.
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
# Fail direction: when the host cannot be determined (no payload, no jq), the
# caller RUNS. A redundant run under Cursor wastes work; a skipped run under
# Claude breaks the primary's supervision, which is the worse failure.

# Return 0 when payload $1 carries Cursor's per-event `cursor_version` stamp.
fm_hook_payload_is_cursor() {  # <payload>
  local payload=${1-}
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e '
    type == "object" and has("cursor_version") and (.cursor_version | type) == "string"
  ' >/dev/null 2>&1
}

# Return 0 when payload $1 was delivered by a foreign host whose own tracked
# Firstmate registration already covers this event.
fm_hook_payload_is_foreign_host() {  # <payload>
  fm_hook_payload_is_cursor "${1-}"
}

# Pi with the Cursor provider (pi-cursor-sdk) loads both tracked registrations
# too, but its Cursor SDK runs each hook command through a login shell
# (`$SHELL -lc`) and keeps only the trailing JSON object on stdout. A silent
# ALLOW then reaches the SDK as whatever the login profile printed, which it
# reports as invalid JSON and turns into a deny, so every read, search, and
# shell call is rejected (verified live: pi 1.1.0, pi-cursor-sdk 0.5.3,
# @cursor/sdk 1.0.37). Once armed, a hook that exits 0 without printing its own
# decision ends stdout with `{}`, which carries no permission and so leaves the
# SDK's own approval flow untouched. A caller that prints its own decision
# object and exits 0 must clear the EXIT trap (`trap - EXIT`) first.
# The Pi host is identified exactly as docs/turnend-guard.md's "Cursor park
# under a Pi host" defines it, and only a Cursor-stamped payload arms, so
# Claude, Codex, Grok, and native Cursor output stay unchanged.
fm_hook_cursor_sdk_reply_arm() {  # <payload>
  [ "${PI_CODING_AGENT:-}" = "true" ] || return 0
  [ -z "${CURSOR_AGENT:-}" ] && [ -z "${CURSOR_INVOKED_AS:-}" ] || return 0
  fm_hook_payload_is_cursor "${1-}" || return 0
  trap '[ "$?" -ne 0 ] || printf "{}\n"' EXIT
}
