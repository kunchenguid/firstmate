#!/usr/bin/env bash
# fm-jcode-busy-bridge.sh - the jcode-debug semantic busy source.
#
# jcode exposes no hook or extension mechanism of the kind claude-hook and
# pi-ext are built on, but its daemon publishes per-session turn state that is
# strictly better than a rendered-text heuristic:
#
#   $ jcode debug sessions
#   [{ "session_id": "...", "working_dir": "/abs/path",
#      "is_processing": false, "status": "ready", ... }]
#
# Verified 2026-09-09 on jcode v0.84.0: across one real turn the matching entry
# moved ready -> running -> ready with is_processing tracking it exactly, so a
# turn boundary is read, never inferred.
#
# Firstmate gives every crewmate its own git worktree, so working_dir is the
# task<->session key. This bridge owns ONLY the transition->event mapping; the
# record format, gen binding, sequencing, and locking all stay in
# bin/fm-busy-event.sh, which remains the sole writer.
#
# Usage:
#   fm-jcode-busy-bridge.sh <state-dir> <task-id> --gen <G> --working-dir <path>
#                           [--interval <secs>] [--startup-grace <secs>] [--once]
#
# --startup-grace bounds the wait for the session to FIRST appear. fm-spawn
# starts this bridge alongside the pane, so the daemon has not registered the
# session yet and an immediate miss-exit would race the crewmate to death.
# Misses only end the run once the session has been seen at least once.
#
# Requires the DAEMON to have been started with JCODE_DEBUG_CONTROL=1 (or
# display.debug_socket enabled); debug control is a server-side gate and cannot
# be turned on from the client. Without it every poll fails and the bridge
# publishes nothing, which classifies unknown rather than a wrong idle - the
# safe direction, because jcode's interrupt key doubles as quit when idle.
#
# Exit codes: 0 clean stop (session gone, or --once served); 1 refused by the
# writer (stale gen - this incarnation was replaced); 2 usage.
set -u

here=$(cd "$(dirname "$0")" && pwd)
busy_event="$here/fm-busy-event.sh"

usage() {
  printf 'usage: fm-jcode-busy-bridge.sh <state-dir> <task-id> --gen <G> --working-dir <path> [--interval <secs>] [--startup-grace <secs>] [--once]\n' >&2
  exit 2
}

state_dir=${1-}; task_id=${2-}
[ -n "$state_dir" ] && [ -n "$task_id" ] || usage
shift 2 || usage

gen= ; working_dir= ; interval=1 ; once=0 ; startup_grace=120
while [ $# -gt 0 ]; do
  case "$1" in
    --gen) gen=${2-}; shift 2 || usage ;;
    --working-dir) working_dir=${2-}; shift 2 || usage ;;
    --interval) interval=${2-}; shift 2 || usage ;;
    --startup-grace) startup_grace=${2-}; shift 2 || usage ;;
    --once) once=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$gen" ] && [ -n "$working_dir" ] || usage
[ -x "$busy_event" ] || { printf 'fm-jcode-busy-bridge: missing %s\n' "$busy_event" >&2; exit 2; }

# Resolve the worktree the same way the daemon reports it, so a symlinked or
# non-normalised spawn path still matches its session entry.
working_dir=$(cd "$working_dir" 2>/dev/null && pwd -P) || {
  printf 'fm-jcode-busy-bridge: unreadable working dir\n' >&2; exit 2; }

# One poll -> "busy", "idle", or empty when this worktree owns no session.
poll_state() {
  JCODE_DEBUG_CONTROL=1 jcode debug sessions 2>/dev/null \
    | jq -r --arg wd "$working_dir" '
        (. // []) | map(select(.working_dir == $wd)) | .[0]
        | if . == null then empty
          elif .is_processing then "busy"
          else "idle" end' 2>/dev/null
}

publish() {  # <state> <event>
  "$busy_event" apply "$state_dir" "$task_id" "$1" \
    --gen "$gen" --source jcode-debug --event "$2"
}

# Publish this bridge's pid where fm_control_harness_wiring_paths says a jcode
# task's wiring lives, so a relaunch can stop a superseded incarnation instead
# of letting two bridges publish against the same task. Removed on exit only
# while it still names this process, so a superseded bridge that exits late
# cannot delete its replacement's pidfile.
pidfile="$state_dir/$task_id.jcode-bridge.pid"
echo "$$" > "$pidfile" 2>/dev/null || true
cleanup() {
  [ "$(head -n 1 "$pidfile" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$pidfile" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# Seed `last` from the record this incarnation already owns, so a bridge that
# is restarted (crash, daemon reload, a recovery re-arm) does not republish a
# state that is already recorded. Only a record carrying THIS gen is adopted;
# any other is a superseded incarnation and is ignored, which leaves `last`
# empty so the first real observation is published normally.
last=
if [ -f "$state_dir/$task_id.busy-state" ]; then
  rec=$(cat "$state_dir/$task_id.busy-state" 2>/dev/null || true)
  case "$rec" in
    *"gen=$gen "*)
      case "$rec" in
        *" state=busy "*) last=busy ;;
        *" state=idle "*) last=idle ;;
      esac
      ;;
  esac
fi
misses=0
seen=0
waited=0
while :; do
  now=$(poll_state)

  if [ -z "$now" ]; then
    if [ "$seen" -eq 0 ]; then
      # The session has never appeared. fm-spawn launches this bridge next to
      # the pane, so the daemon may not have registered it yet; wait out the
      # startup grace rather than racing the crewmate to death. Publishing
      # nothing here leaves the task on its seed record, which is correct.
      waited=$((waited + 1))
      if [ "$waited" -ge "$startup_grace" ]; then
        printf 'fm-jcode-busy-bridge: no session for %s within %ss\n' "$working_dir" "$startup_grace" >&2
        exit 1
      fi
    else
      # It was here and went away. Tolerate a few misses across a daemon
      # reload, then stop: a vanished session is the endpoint's business to
      # classify, and a synthetic idle here could invite an interrupt that quits.
      misses=$((misses + 1))
      [ "$misses" -lt 5 ] || exit 0
    fi
  else
    seen=1
    misses=0
    if [ "$now" != "$last" ]; then
      if [ "$now" = busy ]; then event=turn-start; else event=turn-end; fi
      publish "$now" "$event" || exit 1
      last=$now
    fi
  fi

  [ "$once" -eq 0 ] || exit 0
  sleep "$interval"
done
