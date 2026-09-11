#!/usr/bin/env bash
# PreCompact stow gate - the pre-compaction half of the captain's compact hooks.
#
# Both supported harnesses expose a PreCompact hook event (Claude Code and
# Codex 0.154+) but neither delivers a PreCompact hook's output to the model,
# and neither offers a shell-executable /stow: semantic memory curation is the
# live agent's job. This gate therefore does the only enforceable thing: it
# asks ONCE per compaction sequence for a /stow pass, then always steps aside.
#
# Contract:
#   trigger manual  first attempt  block the compaction once, with the
#                                  instruction to run /stow visible to the
#                                  operator (Claude exit 2 + stderr; Codex
#                                  {"continue": false} + systemMessage), and
#                                  arm state/.precompact-stow-gate.
#                  retry          clear the marker and allow, no matter
#                                  whether /stow ran: a gate that blocks
#                                  forever is the wedge class this repo
#                                  exists to prevent.
#   trigger auto   always         allow with no blocking. Blocking an
#                                  error-recovery auto-compaction fails the
#                                  in-flight request on Claude Code, and the
#                                  Codex exec auto path is unverified, so the
#                                  gate never risks the session. Codex gets a
#                                  non-blocking systemMessage advisory, the
#                                  only channel auto compaction has at all;
#                                  Claude Code discards PreCompact
#                                  systemMessage fields, so --claude stays
#                                  silent.
#   stale marker   older than     treated as absent: the gate re-arms, so a
#                  the window     crashed attempt never wedges later ones.
#
# Standing down silently (exit 0, no marker writes): a no-mistakes gate agent,
# a worktree outside the primary scope, and a foreign-host payload, exactly
# like bin/fm-sessionstart-run.sh, which owns those two eligibility checks.
#
# The post-compaction half needs no script of its own: both harnesses discard
# PostCompact hook stdout, so the model-visible post-compact restart remains
# the tracked SessionStart hook delivering the digest for a compacted open
# (Claude source=compact; Codex exec rehydrates a compacted resume as a
# startup). See docs/sessionstart-nudge.md "Compaction hooks".
#
# Usage: fm-precompact-stow.sh --claude | --codex [--trigger <manual|auto>]
#   The hook payload arrives on stdin; --trigger overrides it for direct calls.
# Every transport path exits 0 except --claude's deliberate one-shot exit 2,
# which is the documented Claude Code PreCompact blocking code.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GATE_FILE="$STATE/.precompact-stow-gate"
GATE_SECS=${FM_PRECOMPACT_STOW_SECS:-3600}

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

MODE=
TRIGGER=
while [ $# -gt 0 ]; do
  case "$1" in
    --claude|--codex) MODE=${1#--}; shift ;;
    --trigger) TRIGGER=${2:-manual}; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
    --trigger=*) TRIGGER=${1#--trigger=}; shift ;;
    *) shift ;;
  esac
done
[ -n "$MODE" ] || MODE=claude

stand_down() {
  exit 0
}

# The same two eligibility owners the session-open wrappers use, so a gate
# agent and an unmarked task worktree never gate compactions for a home they
# do not own.
fm_is_gate_agent "$FM_ROOT" && stand_down
fm_primary_scope_matches "$FM_ROOT" "$STATE" || stand_down
[ -d "$STATE" ] || stand_down

if [ -z "$TRIGGER" ] && [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    stand_down
  fi
  # Same jq-free quote-splitting parse as bin/fm-sessionstart-run.sh: find the
  # first "trigger" key and take the string value that follows it.
  TRIGGER=$(printf '%s' "$PAYLOAD" | awk '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == "trigger" { seen = 1 }
  ')
fi
case "$TRIGGER" in
  manual|auto) : ;;
  *) TRIGGER=manual ;;
esac

gate_age() {
  local marker
  marker=$(cat "$GATE_FILE" 2>/dev/null) || return 1
  case "$marker" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( $(date +%s) - marker ))
}

GATE_MSG='Firstmate pre-compact gate: run the /stow skill now to capture session knowledge, then compact again; this gate steps aside on the next attempt.'

if [ "$TRIGGER" = auto ]; then
  # Never block an automatic compaction; Codex still gets the advisory, the
  # only channel an auto compaction exposes at all.
  if [ "$MODE" = codex ]; then
    printf '{"systemMessage":"Firstmate: context compacted automatically; run the /stow skill after this turn when practical."}\n'
  fi
  exit 0
fi

age=$(gate_age) && [ "$age" -lt "$GATE_SECS" ] || age=
if [ -n "$age" ]; then
  # The retry: the request was made, so the gate complies regardless of the
  # answer. Consuming the marker keeps every later compaction cycle identical.
  rm -f "$GATE_FILE"
  exit 0
fi

date +%s > "$GATE_FILE"
if [ "$MODE" = codex ]; then
  printf '{"continue":false,"stopReason":"%s","systemMessage":"%s"}\n' "$GATE_MSG" "$GATE_MSG"
  exit 0
fi
printf '%s\n' "$GATE_MSG" >&2
exit 2
