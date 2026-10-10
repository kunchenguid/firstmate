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
# Devin is the joint of payload and environment: it stamps no vendor key of its
# own (verified, devin 3000.11.3 - its payloads carry only hook_event_name,
# session_id, prompt_id, and event fields), but it exports DEVIN_PROJECT_DIR to
# hook processes only. A Devin-delivered payload arriving through the tracked
# Claude-shaped registration is therefore an object WITHOUT Claude's own
# `transcript_path` key inside a Devin hook environment: under Claude every
# hook payload carries transcript_path, and under anything else DEVIN_PROJECT_DIR
# is unset, so neither half alone can misfire.
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
  ' >/dev/null 2>&1 && return 0
  [ -n "${DEVIN_PROJECT_DIR:-}" ] || return 1
  printf '%s' "$payload" | jq -e '
    type == "object" and (has("transcript_path") | not)
  ' >/dev/null 2>&1
}
