#!/usr/bin/env bash
# Shared "must this session stay away from the fleet lock?" predicate for
# bin/fm-sessionstart-run.sh and bin/fm-session-start.sh.
# This file is sourced by those entrypoints and has no side effects on source.
#
# A session stands down when:
#   - FM_NO_LOCK=1, the generic opt-out for any tool that launches Claude in the
#     home and must not take the fleet lock; nothing overrides it.
#   - Claude Code marked it unattended (CLAUDE_CODE_SESSION_ATTENDED=0) and
#     FM_SESSIONSTART_ALLOW_UNATTENDED=1 did not opt it back in.
#
# With a session id argument, the hook payload's session_id, the unattended
# signal counts only when that id equals CLAUDE_CODE_SESSION_ID, so a value
# inherited into another harness's hook is ignored.
# Without one, the caller is a command the calling Claude session ran directly,
# so the signal is read from that session's own environment.
# docs/sessionstart-nudge.md owns why.

# Return 0 when this session must stand down from session start.
fm_session_start_stands_down() {  # [<payload-session-id>]
  [ "${FM_NO_LOCK:-}" = 1 ] && return 0
  [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = 0 ] || return 1
  [ "${FM_SESSIONSTART_ALLOW_UNATTENDED:-}" = 1 ] && return 1
  [ "$#" -eq 0 ] && return 0
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$1" = "$CLAUDE_CODE_SESSION_ID" ]
}
