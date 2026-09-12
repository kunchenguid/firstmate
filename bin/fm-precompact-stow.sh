#!/usr/bin/env bash
# PreCompact stow runner - the pre-compaction half of the captain's compact
# hooks: the hook itself performs stow.
#
# Both supported harnesses expose a PreCompact hook event (Claude Code and
# Codex 0.154+) but neither delivers a PreCompact hook's output to the model,
# and a hook cannot type /stow into the compacting session. The runner
# therefore performs stow the only durable way a hook can: it launches a
# detached headless agent - resuming the compacting session's own context
# where the payload carries a session id - and that agent executes the stow
# skill's required startup-memory pass and knowledge sweep per
# .agents/skills/stow/SKILL.md. The hook never asks the operator, never prints
# an instruction, and never blocks, delays, or refuses the compaction: it
# returns immediately and the bounded stow pass completes after it, logged
# under state/.
#
# Contract:
#   every trigger   launch the detached stow pass - manual and auto alike, an
#                   auto compaction is still a preCompact - then allow the
#                   compaction. Silent, exit 0, both harnesses.
#   cooldown        a pass that completed within FM_PRECOMPACT_STOW_SECS
#                   (default 3600) is not relaunched; a stale, absent, or
#                   unwritable completion timestamp always launches.
#   live run        a still-running pass (pid marker alive) is not stacked
#                   onto; the compaction still proceeds.
#   failure         an unavailable, failed, or timed-out agent never blocks
#                   compaction and never writes the completion timestamp, so
#                   the next compaction retries. State-bookkeeping writes are
#                   guarded and a state directory that rejects writes loses
#                   bookkeeping only: with no blocking path there is nothing
#                   to wedge.
#
# Standing down silently (exit 0, nothing launched): a no-mistakes gate agent,
# a worktree outside the primary scope, and a foreign-host payload, exactly
# like bin/fm-sessionstart-run.sh, which owns those two eligibility checks.
#
# The post-compaction half is bin/fm-postcompact-start.sh, the tracked
# PostCompact registration for both harnesses: it runs the compact-source
# session-start path even though hook stdout is not model-visible, while the
# tracked SessionStart hook remains the delivery channel for its digest.
# See docs/sessionstart-nudge.md "Compaction hooks".
#
# Usage: fm-precompact-stow.sh --claude | --codex [--trigger <manual|auto>]
#   The hook payload arrives on stdin; --trigger overrides it for direct calls.
#   --run-agent is the detached child's internal entry mode, not a public
#   interface. FM_PRECOMPACT_STOW_AGENT overrides the whole headless agent
#   command (tests and live labs drive a stub through it; the marked prompt is
#   appended as the command's final argument); when unset the mode's own
#   harness CLI is used with session resume where a session id is known.
#   FM_PRECOMPACT_STOW_RUN_SECS bounds the agent run (default 900).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LAST_FILE="$STATE/.precompact-stow-last"
RUN_FILE="$STATE/.precompact-stow-run"
LOG_FILE="$STATE/.precompact-stow-last.log"
STOW_SECS=${FM_PRECOMPACT_STOW_SECS:-3600}
RUN_SECS=${FM_PRECOMPACT_STOW_RUN_SECS:-900}

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

MODE=
TRIGGER=
SESSION=
RUN_AGENT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --claude|--codex) MODE=${1#--}; shift ;;
    --trigger) TRIGGER=${2:-manual}; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
    --trigger=*) TRIGGER=${1#--trigger=}; shift ;;
    --session) SESSION=${2:-}; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
    --session=*) SESSION=${1#--session=}; shift ;;
    --run-agent) RUN_AGENT=1; shift ;;
    *) shift ;;
  esac
done
[ -n "$MODE" ] || MODE=claude

stand_down() {
  exit 0
}

# Same jq-free quote-splitting parse as bin/fm-sessionstart-run.sh: find the
# first <key> key and take the string value that follows it.
payload_field() {  # <payload> <key>
  printf '%s' "$1" | awk -v want="$2" '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == want { seen = 1 }
  '
}

write_atomic() {  # <target> <content>
  local tmp
  tmp=$(mktemp "$1.tmp.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$2" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$1" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

log_line() {  # <text>
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

marker_age() {  # <file>
  local marker
  marker=$(cat "$1" 2>/dev/null) || return 1
  case "$marker" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( $(date +%s) - marker ))
}

run_marker_age() {  # <file>
  local mtime
  if [ "$(uname)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$1" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$1" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( $(date +%s) - mtime ))
}

run_pid_is_live() {
  local pid bound age
  pid=$(cat "$RUN_FILE" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  bound=$RUN_SECS
  case "$bound" in ''|*[!0-9]*|0) bound=900 ;; esac
  age=$(run_marker_age "$RUN_FILE") || return 1
  [ "$age" -le $(( bound + 300 )) ]
}

run_agent_pass() {
  # The detached child: bound the headless stow agent and record the outcome.
  # Every failure is logged and swallowed - this process no longer belongs to
  # any harness, so its exit status reaches no one.
  cd "$FM_HOME" 2>/dev/null || true
  write_atomic "$RUN_FILE" "$$" || true
  : > "$LOG_FILE" 2>/dev/null || true
  log_line "stow pass start mode=$MODE trigger=$TRIGGER session=${SESSION:-none}"
  local prompt rc=0
  if ! fm_operational_input_encode precompact-stow \
    "Perform the /stow skill now for this firstmate home: read .agents/skills/stow/SKILL.md in this repository and complete its required startup-memory pass and knowledge sweep, honoring every ownership boundary it states, then reply with only the completion receipt it defines. The pre-compact hook launched you while the session compacted, so sweep the resumed session context; the compaction itself has already proceeded." \
    prompt; then
    prompt="Perform the /stow skill now for this firstmate home: read .agents/skills/stow/SKILL.md in this repository and complete its required startup-memory pass and knowledge sweep, honoring every ownership boundary it states, then reply with only the completion receipt it defines."
  fi
  local run_secs=$RUN_SECS
  case "$run_secs" in ''|*[!0-9]*|0) run_secs=900 ;; esac
  if [ -n "${FM_PRECOMPACT_STOW_AGENT:-}" ]; then
    # shellcheck disable=SC2086 # The override is a caller-supplied argv; the
    # marked prompt rides as its final argument, exactly as it would for the
    # real harness CLIs below.
    fm_run_timed "$run_secs" $FM_PRECOMPACT_STOW_AGENT "$prompt" \
      </dev/null >>"$LOG_FILE" 2>&1
    rc=$?
  elif [ "$MODE" = codex ]; then
    if ! command -v codex >/dev/null 2>&1; then
      log_line "stow pass skipped: no codex CLI on PATH"
      rm -f "$RUN_FILE" 2>/dev/null || true
      exit 0
    fi
    if [ -n "$SESSION" ]; then
      fm_run_timed "$run_secs" codex exec resume "$SESSION" \
        --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
        "$prompt" </dev/null >>"$LOG_FILE" 2>&1
      rc=$?
    else
      fm_run_timed "$run_secs" codex exec \
        --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
        "$prompt" </dev/null >>"$LOG_FILE" 2>&1
      rc=$?
    fi
  else
    if ! command -v claude >/dev/null 2>&1; then
      log_line "stow pass skipped: no claude CLI on PATH"
      rm -f "$RUN_FILE" 2>/dev/null || true
      exit 0
    fi
    if [ -n "$SESSION" ]; then
      fm_run_timed "$run_secs" claude --resume "$SESSION" \
        --dangerously-skip-permissions -p "$prompt" \
        </dev/null >>"$LOG_FILE" 2>&1
      rc=$?
    else
      fm_run_timed "$run_secs" claude --dangerously-skip-permissions \
        -p "$prompt" </dev/null >>"$LOG_FILE" 2>&1
      rc=$?
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    if write_atomic "$LAST_FILE" "$(date +%s)"; then
      log_line "stow pass complete"
    else
      log_line "stow pass complete but the cooldown timestamp could not be written"
    fi
  else
    log_line "stow pass ended rc=$rc (124 means the run bound hit); no cooldown recorded, the next compaction retries"
  fi
  rm -f "$RUN_FILE" 2>/dev/null || true
  exit 0
}

[ "$RUN_AGENT" -eq 1 ] && run_agent_pass

# The same two eligibility owners the session-open wrappers use, so a gate
# agent and an unmarked task worktree never launch stow passes for a home they
# do not own.
fm_is_gate_agent "$FM_ROOT" && stand_down
fm_primary_scope_matches "$FM_ROOT" "$STATE" || stand_down
[ -d "$STATE" ] || stand_down

PAYLOAD=
if [ -z "$TRIGGER" ] || [ -z "$SESSION" ]; then
  [ -t 0 ] || PAYLOAD=$(cat 2>/dev/null || true)
fi
if [ -n "$PAYLOAD" ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
  stand_down
fi
if [ -z "$TRIGGER" ] && [ -n "$PAYLOAD" ]; then
  TRIGGER=$(payload_field "$PAYLOAD" trigger)
fi
if [ -z "$SESSION" ] && [ -n "$PAYLOAD" ]; then
  SESSION=$(payload_field "$PAYLOAD" session_id)
fi
case "$TRIGGER" in
  manual|auto) : ;;
  *) TRIGGER=manual ;;
esac

# Cooldown: a completed pass inside the window satisfies this compaction.
age=$(marker_age "$LAST_FILE") && [ "$age" -lt "$STOW_SECS" ] && stand_down

# A still-running pass is not stacked onto.
run_pid_is_live && stand_down

# Detached three ways, each closing a different failure, exactly like
# bin/fm-startup-network.sh's deferred worker: stdio away from the hook's
# pipes, nohup so the pass outlives the hook, and its own process group so no
# harness-side hook bound can terminate the pass it just launched.
AGENT_ARGS=()
case "$MODE" in
  claude) AGENT_ARGS=(--claude --trigger "$TRIGGER") ;;
  *) AGENT_ARGS=(--codex --trigger "$TRIGGER") ;;
esac
[ -n "$SESSION" ] && AGENT_ARGS+=(--session "$SESSION")
AGENT_ARGS+=(--run-agent)
local_monitor_was_on=0
case $- in *m*) local_monitor_was_on=1 ;; esac
set -m 2>/dev/null || true
# shellcheck disable=SC2024 # Redirection order keeps the log append honest.
nohup "$SCRIPT_DIR/fm-precompact-stow.sh" "${AGENT_ARGS[@]}" \
  >/dev/null 2>&1 </dev/null &
if [ "$local_monitor_was_on" -eq 0 ]; then
  set +m 2>/dev/null || true
fi
stand_down
