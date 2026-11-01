#!/usr/bin/env bash
# launchd exec target for the Firstmate-owned dev.firstmate.herdr.fm-remote
# launch agent: make the Aqua login session own the fm-remote Herdr server.
#
# Usage:
#   fm-remote-herdr-guard.sh <herdr-path> <session>
#
# bin/fm-remote-doctor.sh renders the launch agent as the account's login
# shell running `exec <this script> <herdr> fm-remote` with
# LimitLoadToSessionType=Aqua, RunAtLoad, KeepAlive={SuccessfulExit=false},
# and ThrottleInterval=10, then bootstraps it into gui/<uid>. That domain, not
# the login shell, is what gives this process and every server it execs the
# Aqua audit session and login-keychain access; the login shell only gives the
# server the account's own environment.
# The server runs as this script's child, made a session leader with setsid
# before it execs herdr: Herdr reports the detached_server_daemon capability,
# which `herdr machine add` requires of a saved machine, only when the server
# is its own session leader, and a launchd job never is one. The child keeps
# the agent's Aqua audit session and environment, so panes keep keychain
# access. The script waits on the server, forwards TERM, INT and HUP to it
# (it no longer shares the job's process group, so launchd's own kill misses
# it), and exits with its status, so a crash or kill asks launchd for a retry.
# A watcher in the server's session stops the server when this script is gone,
# so a SIGKILL of the script (launchd's ExitTimeOut escalation, an OOM kill)
# does not leave the server running without a supervisor.
# docs/verification/runtime-backends.md ("fm-remote server birth and
# login-keychain access" and "fm-remote detached server daemon") holds the
# dated evidence.
#
# Decision, made once per launch (exit codes matter under SuccessfulExit=false:
# 0 tells launchd the job is done until something restarts it, non-zero asks
# for a retry after the throttle interval):
#   no server owns the session socket  -> run `herdr server --session <s>` as a
#                                          setsid child and wait for it
#   the owner was born in the Aqua session (launchd or the Aqua remote-job
#   worker) and its parent is the running launchd job named by its
#   XPC_SERVICE_NAME, that is a live guard -> exit 0, leave it alone
#   the owner was born anywhere else (an SSH remote attach, a shell over
#   ssh/mosh, or a birth it cannot prove), or it has no live guard (its guard
#   was SIGKILLed and the watcher is stopping it, or an older guard exec'd it)
#                                       -> `herdr server stop`, wait until the
#                                          socket is released, then start
#                                          `herdr server --session <s>` at once
#                                          so the socket is rebound before a
#                                          reconnecting SSH attach can start
#                                          another foreign server
#   the foreign server does not release the socket in time -> exit 1
# A takeover closes every pane in that session; the parent firstmate's
# secondmate liveness sweep relaunches its mates into the Aqua-born server.
# bin/fm-remote-herdr-owner-lib.sh owns the owner discovery and the birth
# markers; FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS (default 50) bounds the
# release wait in tenths of a second. Every decision prints one line to
# stdout, which launchd routes to the agent's log.
set -u

SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$SCRIPT_DIR/fm-remote-herdr-owner-lib.sh"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ "$#" -eq 2 ] || usage
HERDR_BIN=$1
SESSION=$2
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || { printf 'fm-remote-herdr-guard: herdr is not executable: %s\n' "$HERDR_BIN" >&2; exit 1; }
[ -n "$SESSION" ] || usage
command -v jq >/dev/null 2>&1 || { printf 'fm-remote-herdr-guard: jq does not resolve on the launch agent PATH\n' >&2; exit 1; }
STOP_WAIT_TENTHS=${FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS:-50}

log() { printf 'fm-remote-herdr-guard: %s\n' "$*"; }

herdr_status() { # prints the session's status JSON, empty when herdr fails
  HERDR_SESSION="$SESSION" "$HERDR_BIN" status --json --session "$SESSION" 2>/dev/null || true
}

status_running() { # <status-json>
  [ "$(printf '%s' "$1" | jq -r '.server.running // false' 2>/dev/null)" = true ]
}

start_server() {
  local child rc
  command -v perl >/dev/null 2>&1 || { log "perl does not resolve on the launch agent PATH, so the server cannot become a session leader"; exit 1; }
  log "starting the herdr server for session $SESSION as a session leader supervised by this launch agent (pid $$)"
  # Herdr reports detached_server_daemon only when the server is its own session
  # leader (getsid(0) == getpid()), which saved machines require. A launchd job
  # is a process-group leader but never a session leader, and setsid(2) fails
  # for a group leader, so the server is a background child that calls setsid
  # and then execs herdr, keeping this agent's Aqua audit session and environment.
  # Before the exec it forks a watcher into the server's new session, which a
  # SIGKILL of this script's process group cannot reach: when this script is
  # gone, the watcher stops the server (TERM, then KILL after 10 seconds), so
  # the server never outlives its launch agent. The watcher exits as soon as
  # the server is gone, because it is then no longer the watcher's parent.
  HERDR_SESSION="$SESSION" perl -MPOSIX -e '
    my $guard = shift;
    POSIX::setsid() != -1 or die "setsid: $!\n";
    my $server = $$;
    defined(my $watcher = fork) or die "fork: $!\n";
    if (!$watcher) {
      sleep 1 while getppid() == $server && kill 0, $guard;
      exit 0 if getppid() != $server;
      kill "TERM", $server;
      my $tenths = 0;
      select undef, undef, undef, 0.1 while getppid() == $server && $tenths++ < 100;
      kill "KILL", $server if getppid() == $server;
      exit 0;
    }
    exec @ARGV or die "exec $ARGV[0]: $!\n";
  ' "$$" "$HERDR_BIN" server --session "$SESSION" &
  child=$!
  # The server no longer shares this job's process group, so launchd's own kill
  # (kickstart -k, bootout) reaches only this script; forward it to the server.
  trap 'kill -TERM "$child" 2>/dev/null' TERM INT HUP
  wait "$child"; rc=$?
  while kill -0 "$child" 2>/dev/null; do wait "$child"; rc=$?; done
  log "the herdr server for session $SESSION exited with status $rc"
  exit "$rc"
}

STATUS=$(herdr_status)
if ! status_running "$STATUS"; then
  log "no server owns session $SESSION"
  start_server
fi

SOCKET=$(printf '%s' "$STATUS" | jq -r '.server.socket // empty' 2>/dev/null)
OWNER=$(fm_remote_herdr_socket_owner "$SOCKET"); OWNER_RC=$?
if [ "$OWNER_RC" -eq 2 ]; then
  log "session $SESSION is running but lsof does not resolve, so its server's birth cannot be proven"
  BIRTH=unknown
elif [ -z "$OWNER" ]; then
  log "session $SESSION is running but no herdr process could be proven to own ${SOCKET:-its socket}"
  BIRTH=unknown
else
  BIRTH=$(fm_remote_herdr_owner_birth "$OWNER")
fi

if ! fm_remote_herdr_birth_is_aqua "$BIRTH"; then
  log "session $SESSION is served by ${OWNER:+pid }${OWNER:-an unproven process} born outside the Aqua login session ($BIRTH); its panes cannot reach the login keychain, taking the session over"
elif fm_remote_herdr_owner_has_live_guard "$OWNER"; then
  log "session $SESSION is served by pid $OWNER born in the Aqua login session ($BIRTH) under a live guard; nothing to do"
  exit 0
else
  log "session $SESSION is served by pid $OWNER born in the Aqua login session ($BIRTH) without a live guard; taking the session over so this launch agent supervises it"
fi
HERDR_SESSION="$SESSION" "$HERDR_BIN" server stop --session "$SESSION" >/dev/null 2>&1 \
  || log "herdr server stop for session $SESSION did not succeed; waiting for the socket anyway"
i=0
while [ "$i" -lt "$STOP_WAIT_TENTHS" ]; do
  if ! status_running "$(herdr_status)"; then
    log "session $SESSION released its socket after $i tenths of a second"
    start_server
  fi
  sleep 0.1
  i=$((i + 1))
done
log "the foreign server for session $SESSION did not release its socket within $STOP_WAIT_TENTHS tenths of a second; exiting 1 so launchd retries"
exit 1
