#!/usr/bin/env bash
# Worker-placement guard for a primary running inside a Firstmate view
# (bin/fm-view.sh). A view exists only in the session's private mount
# namespace, so a multiplexer server first started from inside it would hand
# every worker pane the view - the composed surface, read-only - at the
# project's primary checkout path. Workers must run from a server started
# outside the session, as a supervisor launched in the captain's own
# multiplexer pane already does.
#
# This file is sourced; it has no side effects on source. Outside a view
# (FM_VIEW unset) every function succeeds without looking.

# fm_view_pid_inside <pid>: true when <pid> runs in this process's mount
# namespace while this process is inside a view. An unreadable namespace link
# means another user namespace owns the process, which is outside the view.
fm_view_pid_inside() {
  local pid=$1 mine theirs
  [ "${FM_VIEW:-}" = 1 ] || return 1
  [ -n "$pid" ] || return 1
  mine=$(readlink "/proc/$$/ns/mnt" 2>/dev/null) || return 1
  theirs=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || return 1
  [ "$mine" = "$theirs" ]
}

# fm_view_refuse_server_start <backend>: refuse (return 1 with a reason) to
# start a <backend> server from inside a view; succeed outside one.
fm_view_refuse_server_start() {
  [ "${FM_VIEW:-}" = 1 ] || return 0
  echo "error: no $1 server is running outside this Firstmate view, and one started from inside it would show workers the view instead of the real project; start the $1 server from a terminal outside this session (or launch firstmate from inside $1), then spawn again" >&2
  return 1
}

# fm_view_refuse_server_inside <backend> <pid>: refuse (return 1 with a reason)
# when a running <backend> server was started inside this view.
fm_view_refuse_server_inside() {
  fm_view_pid_inside "$2" || return 0
  echo "error: the $1 server (pid $2) was started inside this Firstmate view, so its workers would see the view instead of the real project; stop that server and start one from a terminal outside this session, then spawn again" >&2
  return 1
}
