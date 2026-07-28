#!/usr/bin/env bash
# Best-effort Parlay chat-panel enrollment for the crewmate lifecycle.
#
# `parlay listen --agent <id>` (trillium/parlay#14) registers the agent,
# announces it, then execs into the same relay-backed poll loop as
# `parlay monitor` - it never returns. fm_parlay_listen backgrounds it (so a
# spawn never blocks waiting on it) and records its pid at
# state/<id>.parlay-listen.pid so fm_parlay_agent_down can stop it.
# `parlay agent-down <id>` (trillium/parlay#15) deregisters that same id via
# the server's /api/chat/unregister endpoint.
#
# Both are enhancements only: a missing `parlay` binary, a failed launch, or a
# failed deregistration logs a warning and never blocks or fails the caller's
# spawn or teardown.

fm_parlay_listen() {  # <task-id> <state-dir>
  local id=$1 state_dir=$2 pid
  command -v parlay >/dev/null 2>&1 || return 0
  mkdir -p "$state_dir" 2>/dev/null || true
  nohup parlay listen --agent "$id" </dev/null >/dev/null 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  if ! printf '%s\n' "$pid" > "$state_dir/$id.parlay-listen.pid" 2>/dev/null; then
    echo "warning: could not record the Parlay listen pid for $id; it will not be stopped on teardown" >&2
  fi
}

fm_parlay_agent_down() {  # <task-id> <state-dir>
  local id=$1 state_dir=$2 pid
  local pidfile=$state_dir/$id.parlay-listen.pid
  command -v parlay >/dev/null 2>&1 || return 0
  if [ -f "$pidfile" ]; then
    pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  fi
  parlay agent-down "$id" >/dev/null 2>&1 \
    || echo "warning: parlay agent-down failed for $id; its Parlay panel entry may remain until it expires" >&2
}
