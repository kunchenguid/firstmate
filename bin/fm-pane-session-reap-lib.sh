#!/usr/bin/env bash
# fm-pane-session-reap-lib.sh - reap a closed tmux pane's own POSIX session.
#
# WHY. tmux kill-window only hangs up the pane pty: SIGHUP reaches the session
# leader and the foreground process group, so a pane-session member that
# ignores SIGHUP or sits in its own process group outlives a completed close
# (reproduced 2026-09-22 on tmux 3.7c). Herdr's pane close already ends the
# whole pane session, so only the tmux close path uses this.
#
# CONTRACT.
#   fm_pane_session_snapshot <tmux-target>, called immediately before the
#     close, prints one "<sid> <pid> <start>" line per member of the exact
#     window's pane sessions: each pane shell is its session leader, so its pid
#     is the session id. Membership comes from os.getsid, because macOS
#     `ps -o sess` prints 0 for every process. This shell and its ancestors are
#     never recorded. Prints nothing when the window or python3 is unavailable.
#   fm_pane_session_reap <snapshot> <label>, called only after a successful
#     close, sends TERM to every recorded member whose session and start time
#     still match, waits 1 s, then sends KILL to those still matching. Only the
#     pre-close snapshot names targets and a later lookup never widens it, so a
#     reused pid or another task's window is never reached.
# Sourced by bin/fm-teardown.sh; no side effects on source.

fm_pane_session_leaders() {  # <tmux-target>
  case "$1" in *:*) ;; *) return 0 ;; esac
  tmux list-panes -t "=${1%%:*}:=${1#*:}" -F '#{pane_pid}' 2>/dev/null \
    | grep -E '^[1-9][0-9]*$' || true
}

fm_pane_session_members() {  # <sid>
  ps -A -o pid= 2>/dev/null | python3 -c '
import os, sys
sid = int(sys.argv[1])
for pid in sys.stdin.read().split():
    try:
        if os.getsid(int(pid)) == sid: print(pid)
    except (OSError, ValueError): pass
' "$1" 2>/dev/null || true
}

fm_pane_session_sid_of() {  # <pid>
  python3 -c 'import os, sys; print(os.getsid(int(sys.argv[1])))' "$1" 2>/dev/null
}

fm_pane_session_start() {  # <pid>
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | awk '{$1 = $1; print}'
}

fm_pane_session_self_chain() {
  local pid=$$
  while [ "${pid:-0}" -gt 1 ] 2>/dev/null; do
    printf '%s\n' "$pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  done
}

fm_pane_session_record() {  # <sid> <pid> <self-chain>
  local start
  printf '%s\n' "$3" | grep -Fqx -- "$2" && return 0
  start=$(fm_pane_session_start "$2")
  [ -z "$start" ] || printf '%s %s %s\n' "$1" "$2" "$start"
}

fm_pane_session_snapshot() {  # <tmux-target>
  local sid pid self
  command -v python3 >/dev/null 2>&1 \
    || { echo "warning: python3 is unavailable; pane-session processes of $1 are not reaped after its close" >&2; return 0; }
  self=$(fm_pane_session_self_chain)
  for sid in $(fm_pane_session_leaders "$1"); do
    for pid in $(fm_pane_session_members "$sid"); do
      fm_pane_session_record "$sid" "$pid" "$self"
    done
  done
}

fm_pane_session_matches() {  # <sid> <pid> <start>
  [ "$(fm_pane_session_sid_of "$2")" = "$1" ] \
    && [ "$(fm_pane_session_start "$2")" = "$3" ]
}

fm_pane_session_signal() {  # <snapshot> <signal>
  local sid pid start
  while read -r sid pid start; do
    [ -n "$pid" ] || continue
    fm_pane_session_matches "$sid" "$pid" "$start" || continue
    kill "-$2" "$pid" 2>/dev/null && printf '%s ' "$pid"
  done <<EOF
$1
EOF
}

fm_pane_session_reap() {  # <snapshot> <label>
  local termed killed
  [ -n "$1" ] || return 0
  termed=$(fm_pane_session_signal "$1" TERM)
  [ -n "$termed" ] || return 0
  echo "teardown: reaping surviving pane-session process(es) for $2: $termed" >&2
  sleep 1
  killed=$(fm_pane_session_signal "$1" KILL)
  [ -z "$killed" ] || echo "teardown: force-killing pane-session process(es) for $2: $killed" >&2
}
