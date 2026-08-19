#!/usr/bin/env bash
# fm-prime-agent-lib.sh - the ONE owner of retiring prime-agent's detached
# daemon sessions.
#
# prime-agent runs every root session in a detached daemon worker under one
# per-user supervisor. Closing the pane detaches the client, and so does an
# explicit `/quit`: both leave the worker running, holding its launch directory
# as cwd and a lease on its transcript (verified 2026-08-08 on prime-agent
# 0.7.1 - a torn-down task's session was still `lifecycle=live` on that
# worktree, and a quit session stayed `live` too). Killing the endpoint
# therefore does NOT end the agent.
#
# The retirement lives here rather than inline in its caller because it is the
# single owner of that fact: bin/fm-teardown.sh runs it before its generic
# leaked-process reaper, so the worker ends through prime-agent instead of
# being SIGTERMed out from under its own lease and journals.
#
# Selection is by the session's recorded cwd: the task worktree or secondmate
# home itself, or a path inside it, matched against both the path as given and
# its physical form because a session under a symlinked prefix records either.
# Deliberately never `prime-agent shutdown`,
# which stops the captain's own sessions and every other home's workers too -
# the daemon is fleet-wide, one supervisor per user.
#
# `prime-agent status` is deliberately NOT consulted: it marks even a live
# session's forkserver `stale`, so that word is not a health signal.
#
# Sourcing: set -u and set -e safe. Retirement is best-effort and a silent
# no-op on failure, so a missing binary or an unreachable daemon can never fail
# the teardown it is a courtesy inside of.

FM_PRIME_AGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F fm_run_timed >/dev/null 2>&1 \
  && [ -r "$FM_PRIME_AGENT_LIB_DIR/fm-timeout-lib.sh" ]; then
  # The bound runner enables nounset at file scope, and this lib is sourced from
  # source-only libs that promise the caller's shell flags back unchanged, so
  # restore whatever the caller had.
  case $- in
    *u*) FM_PRIME_AGENT_LIB_NOUNSET=1 ;;
    *) FM_PRIME_AGENT_LIB_NOUNSET=0 ;;
  esac
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$FM_PRIME_AGENT_LIB_DIR/fm-timeout-lib.sh"
  [ "$FM_PRIME_AGENT_LIB_NOUNSET" = 1 ] || set +u
  unset FM_PRIME_AGENT_LIB_NOUNSET
fi

# Every prime-agent CLI call goes through here, BOUNDED. `list` makes the
# supervisor refresh every worker's summaries and sync agent peers before it
# answers, so an unbounded call would let a wedged daemon socket stall whichever
# caller asked. A hit bound is just another unknown: the caller below already
# fails safe on one.
fm_prime_agent_cli() {  # <arg>...
  local bound=${FM_PRIME_AGENT_CLI_TIMEOUT:-5}
  case "$bound" in ''|*[!0-9]*|0*) bound=5 ;; esac
  if declare -F fm_run_timed >/dev/null 2>&1; then
    fm_run_timed "$bound" prime-agent "$@"
  else
    prime-agent "$@"
  fi
}

fm_prime_agent_session_ids_under() {  # <directory> [physical-directory]
  local dir=$1 phys=${2:-$1} listing
  listing=$(fm_prime_agent_cli list --json 2>/dev/null) || return 2
  printf '%s\n' "$listing" \
    | jq -r --arg dir "$dir" --arg phys "$phys" '
        def under($d): $d != "" and (. == $d or startswith($d + "/"));
        if (.sessions | type) == "array" then .sessions else error("sessions are missing") end
        | map(select((.cwd // "") | (under($dir) or under($phys))))
        | .[]
        | if (((.id // null) | type) == "string" and (.id | length) > 0) then .id else error("session id is missing") end' 2>/dev/null
}

# fm_prime_agent_stop_sessions_under <directory>
# Stops each prime-agent session whose cwd is <directory> or inside it.
# Prints one line per stopped session to stderr.
fm_prime_agent_stop_sessions_under() {  # <directory>
  local dir=$1 resolved ids id
  [ -n "$dir" ] || return 0
  command -v prime-agent >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  resolved=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || resolved=$dir
  ids=$(fm_prime_agent_session_ids_under "$dir" "$resolved") || return 0
  while IFS= read -r id; do
    case "$id" in ''|-*|*[!A-Za-z0-9._-]*) continue ;; esac
    echo "prime-agent: stopping detached session $id bound to $resolved" >&2
    fm_prime_agent_cli stop "$id" >/dev/null 2>&1 || true
  done <<EOF
$ids
EOF
}
