#!/usr/bin/env bash
# Session-open entry point for harnesses that RUN the digest instead of asking
# the agent to. It is the one command those harnesses' session-open adapters
# invoke, and it decides, from the session-open source, whether this open needs
# the full digest, a context re-emit, or nothing at all.
#
# Why running beats nudging: bin/fm-sessionstart-nudge.sh can only ASK the agent
# to take the helm, and an agent can defer that, including when a first-command
# skill has its own read-only path. When the harness injects hook stdout into
# model context, running the digest here removes that discretion - the helm is
# taken before the model's first turn, whatever the first turn is.
#
# Usage: fm-sessionstart-run.sh [--source <source>]
#   --source  The harness's own session-open source. When omitted, the source is
#             read from a Claude/Codex-shaped JSON hook payload on stdin
#             (the `source` field). An unreadable or unrecognized source is
#             treated as `startup`, because taking the helm redundantly is
#             cheap and idempotent while not taking it is the whole bug.
#
# Claude identity bridge: on a Claude-shaped payload, the wrapper validates
# `session_id`, appends FM_SESSION_HARNESS, FM_SESSION_ID, and the publishing
# session's FM_SESSION_PUBLISHER_PID to Claude's vendor-provided CLAUDE_ENV_FILE,
# and exports the same values into this hook.
# The lock acquired below can therefore compare the same stable identity from a
# later Stop hook or from an ordinary Bash tool after process reparenting, while
# the publisher pid keeps a nested session that inherited those exports from
# presenting this session's identity as its own.
# If the harness process cannot be resolved or the environment-file write fails,
# no identity is advertised and the legacy ancestry decision remains in force.
#
# Source routing (see docs/sessionstart-nudge.md for the per-harness names):
#   startup, new            full digest - this process has not taken the helm
#   clear, compact          `--reemit` digest only when this lock owner recorded
#                           a completed full startup; otherwise a full digest,
#                           so a startup killed mid-sweep is finished first
#   resume, reload, fork    delegate to the nudge wrapper. Prior context is
#                           restored on these, so re-running is redundant when
#                           this process still holds the lock (the nudge stays
#                           silent) and a plain instruction is enough when a new
#                           process resumed an old session (the nudge fires).
#
# Every path exits 0, exactly like the nudge wrapper: a Claude SessionStart
# exit 2 blocks session initialization, so a failed session start must reach the
# agent as digest text it can act on, never as a refusal to open the session.
# A lock another live session holds and a truncated digest are reported inside
# the digest, while broken GitHub auth arrives through the deferred network
# result inline or as a wake, for exactly that reason.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
COMPLETION_FILE="$STATE/.session-start-complete"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# Session identity can refresh a reparented lock, so it shares fm-lock.sh's
# portable acquisition lock.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      # A bare trailing --source leaves the source empty rather than aborting,
      # so a malformed call still falls through to taking the helm.
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    *) shift ;;
  esac
done

# The same two eligibility owners the nudge wrapper uses, so a no-mistakes gate
# agent and an unmarked task worktree can never run a session start for a home
# they do not own.
fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# True when the session that owns the lock right now is the one that recorded a
# completed full startup.
# The recorded pid proves that for an owner whose pid has not moved. An
# identity-matched reparenting atomically refreshes the lock's pid, so the
# owner's stable session identity proves the same thing when it has, and either
# proof alone is enough; a different session matches neither.
session_start_completed() {
  local lock_pid lock_identity completion_pid completion_identity
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  [ -f "$COMPLETION_FILE" ] && [ ! -L "$COMPLETION_FILE" ] || return 1
  fm_session_lock_owned_by_self "$STATE" || return 1
  fm_session_lock_read "$STATE" || return 1
  lock_pid=$FM_SESSION_LOCK_PID
  lock_identity=$FM_SESSION_LOCK_IDENTITY
  completion_pid=$(sed -n '1p' "$COMPLETION_FILE" 2>/dev/null) || return 1
  [ "$completion_pid" = "$lock_pid" ] && return 0
  completion_identity=$(sed -n 's/^session=//p' "$COMPLETION_FILE" 2>/dev/null | head -1)
  [ -n "$lock_identity" ] && [ "$completion_identity" = "$lock_identity" ]
}

PAYLOAD=
if [ -z "$SOURCE" ] && [ ! -t 0 ]; then
  # Claude and Codex both deliver a JSON SessionStart payload on stdin whose
  # `source` field carries startup|resume|clear|compact. Parsed without jq so a
  # host missing it still gets correct routing rather than silent full runs.
  # A terminal stdin is skipped outright: a hook always pipes its payload, and
  # an operator running this by hand must not be left waiting on a read.
  # Splitting on the quote character finds the FIRST "source" key and its value
  # without depending on greedy-regex luck, and it cannot mistake a string VALUE
  # of "source" for the key, because only a key is followed by a bare colon.
  PAYLOAD=$(cat 2>/dev/null || true)
  # Cursor loads the tracked Claude settings as well as its own registration,
  # so a Cursor-delivered payload here is the duplicate: bin/fm-sessionstart-
  # cursor.sh already owns that session open and calls this wrapper with an
  # explicit --source and no payload. Running twice would take the helm twice
  # and repeat every startup sweep.
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  # Claude's session_id is delivered to SessionStart and Stop hooks but is not
  # ambient in ordinary Bash tool calls.
  # CLAUDE_ENV_FILE is the vendor-owned bridge expressly provided by Claude for
  # SessionStart hooks to persist exports into every later Bash tool call.
  # Publish only after that append succeeds, so a lock never records an identity
  # that ordinary commands in the same session cannot recover.
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    SESSION_ID=$(fm_session_identity_from_hook_payload "$PAYLOAD" 2>/dev/null || true)
    # The publishing session's own pid travels with the identity. Ordinary
    # commands inherit both, so a nested session whose own bridge never ran is
    # detectable by that provenance instead of presenting this session's
    # identity as its own. A nested session that DOES run this bridge overwrites
    # both values with its own and keeps full identity ownership.
    SESSION_PUBLISHER_PID=$(fm_harness_ancestry_pid 2>/dev/null || true)
    case "$SESSION_PUBLISHER_PID" in ''|*[!0-9]*|1) SESSION_PUBLISHER_PID= ;; esac
    if [ -n "$SESSION_ID" ] && [ -n "$SESSION_PUBLISHER_PID" ] \
      && printf 'export FM_SESSION_HARNESS=claude\nexport FM_SESSION_ID=%s\nexport FM_SESSION_PUBLISHER_PID=%s\n' \
        "$SESSION_ID" "$SESSION_PUBLISHER_PID" >> "$CLAUDE_ENV_FILE" 2>/dev/null; then
      FM_SESSION_HARNESS=claude
      FM_SESSION_ID=$SESSION_ID
      FM_SESSION_PUBLISHER_PID=$SESSION_PUBLISHER_PID
      export FM_SESSION_HARNESS FM_SESSION_ID FM_SESSION_PUBLISHER_PID
    fi
  fi
  SOURCE=$(printf '%s' "$PAYLOAD" | awk '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == "source" { seen = 1 }
  ')
fi

case "$SOURCE" in
  resume|reload|fork)
    exec "$SCRIPT_DIR/fm-sessionstart-nudge.sh"
    ;;
  clear|compact)
    if session_start_completed; then
      "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SOURCE" || true
    else
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SOURCE" || true
    fi
    ;;
  *)
    "$SCRIPT_DIR/fm-session-start.sh" --source "$SOURCE" || true
    ;;
esac
exit 0
