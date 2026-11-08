#!/usr/bin/env bash
# launchd exec target for a Firstmate-owned remote Herdr agent: make the
# Aqua login session own its configured Herdr server session.
# The primary root uses dev.firstmate.herdr.fm-remote and fm-remote; additional
# roots receive root-derived labels and session names.
#
# Usage:
#   fm-remote-herdr-guard.sh <herdr-path> <session>
#
# bin/fm-remote-doctor.sh renders the launch agent as the account's login
# shell running `exec <this script> <herdr> <session>` with
# LimitLoadToSessionType=Aqua, RunAtLoad, KeepAlive={SuccessfulExit=false},
# and ThrottleInterval=10, then bootstraps it into gui/<uid>. That domain, not
# the login shell, is what gives this process and every server it execs the
# Aqua audit session and login-keychain access; the login shell only gives the
# server the account's own environment.
# `herdr server` stays in the foreground under launchd, as verified in
# docs/verification/runtime-backends.md under "fm-remote server birth and login-keychain access", so the final exec provides the complete supervision lifecycle.
#
# Decision, made once per launch (exit codes matter under SuccessfulExit=false:
# 0 tells launchd the job is done until something restarts it, non-zero asks
# for a retry after the throttle interval):
#   no server owns the session socket  -> exec `herdr server --session <s>`
#                                          (foreground, launchd-supervised)
#   the owner was born in the Aqua session (launchd or the Aqua remote-job
#   worker)                            -> exit 0, leave it alone
#   the owner was born anywhere else (an SSH remote attach, a shell over
#   ssh/mosh, or a birth it cannot prove), and the operator's
#   fm-remote-doctor.sh --fix authorized this start
#                                       -> `herdr server stop`, wait until the
#                                          socket is released, then exec
#                                          `herdr server --session <s>` at once
#                                          so the socket is rebound before a
#                                          reconnecting SSH attach can start
#                                          another foreign server
#   the foreign server does not release the socket in time -> exit 1
#   any other start (RunAtLoad at login, a KeepAlive restart, or an automatic
#   readiness repair) over a foreign server -> exit 0, leave it alone
# A takeover closes every pane in that session, so it happens only on the
# operator's explicit request: that --fix writes its pid and process-start identity to
# ~/.firstmate/remote-herdr-takeover-<s>, and this guard consumes that one-shot
# marker and honors it only while the authorizing doctor is still running.
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
# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"

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
  log "starting the herdr server for session $SESSION inside this launch agent (pid $$)"
  exec "$HERDR_BIN" server --session "$SESSION"
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

if fm_remote_herdr_birth_is_aqua "$BIRTH"; then
  log "session $SESSION is served by pid $OWNER born in the Aqua login session ($BIRTH); nothing to do"
  exit 0
fi

takeover_authorized() {
  local marker="${HOME:-}/.firstmate/remote-herdr-takeover-$SESSION" claimed pid='' start='' actual
  claimed="$marker.claimed.$$"
  mv -- "$marker" "$claimed" 2>/dev/null || return 1
  { IFS= read -r pid; IFS= read -r start; } < "$claimed" || true
  rm -f -- "$claimed"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$start" ] && kill -0 "$pid" 2>/dev/null || return 1
  actual=$(fm_remote_job_process_start "$pid") || return 1
  [ "$actual" = "$start" ]
}

if ! takeover_authorized; then
  log "session $SESSION is served by ${OWNER:+pid }${OWNER:-an unproven process} born outside the Aqua login session ($BIRTH); leaving it alone, because only the operator's fm-remote-doctor.sh --fix authorizes a takeover"
  exit 0
fi

log "session $SESSION is served by ${OWNER:+pid }${OWNER:-an unproven process} born outside the Aqua login session ($BIRTH); its panes cannot reach the login keychain, taking the session over"
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
