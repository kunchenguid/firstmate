#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a REFRESH: no stale-artifact clear);
#     - otherwise clears any prior away session's stale escalation artifacts
#       (fm_afk_clear_stale_artifacts) for a direct, non-prepared start, then
#       execs bin/fm-supervise-daemon.sh in the foreground. A prepared start was
#       already cleared transactionally by bin/fm-afk-launch.sh.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and fm_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process differs by harness/backend and is owned elsewhere:
#   - Harnesses with a native in-pane tracked-background tool (e.g. claude, grok)
#     run this directly via that tool on most backends, so the daemon inherits
#     the captain pane's env and auto-discovers it. EXCEPTION: claude on the
#     herdr backend must NOT use this path - the in-pane background job leaves
#     a footer token that herdr's own claude agent-detection ruleset misreads as
#     "working" for the life of the session, structurally wedging the away-mode
#     busy guard (data/firstmate-afk-daemon-wedged-investigation/report.md,
#     2026-08-26; see .agents/skills/afk/SKILL.md for the routing rule).
#   - Harnesses with NO native background mechanism (e.g. pi), and claude on
#     herdr per the exception above, run this THROUGH bin/fm-afk-launch.sh,
#     which creates a non-visible tracked terminal per backend (herdr tab/
#     workspace, tmux detached session) and passes the captain pane in as
#     FM_SUPERVISOR_TARGET so injection targets it, not the daemon's own new
#     pane.
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
set -eu

FM_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LOCK="$FM_AFK_STATE/.supervise-daemon.lock"
FM_AFK_DAEMON="$FM_AFK_START_DIR/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_START_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_AFK_START_DIR/fm-supervisor-target-lib.sh"

fm_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The claude+herdr exception, enforced here too: bin/fm-afk-launch.sh's own
# start-native guard only covers entry THROUGH the launcher. This script is
# also a documented direct entry point (the second half of the native two-step,
# and a bare direct call), so the same wedge is reachable by skipping the
# launcher entirely.
#
# The hazard is PHYSICAL: the daemon hosting itself in the very pane it will
# inject escalations into (self-injection). On claude+herdr that pane's footer
# then carries the background-shell token for the life of the session, herdr's
# claude detection reads it as "the agent is working", and every escalation
# defers forever. So the signal is a same-pane comparison, not the presence of
# any environment knob: fm_afk_start_own_pane resolves where THIS process is
# actually running (raw $TMUX_PANE / $HERDR_ENV+$HERDR_PANE_ID, deliberately
# ignoring the FM_SUPERVISOR_TARGET override), while discover_supervisor_target
# resolves where injection will actually land (override first, exactly as
# inject_msg does). The launcher's terminal-backed path stays permitted because
# it runs in its OWN separate pane and targets the captain's - different panes,
# no self-injection.
#
# fm_afk_start_own_backend / fm_afk_start_own_pane: this process's RAW identity.
# Distinct from discover_supervisor_backend/discover_supervisor_target on
# purpose - those answer "where do escalations go", which an operator may
# override; these answer "where am I", which nothing may override. Both return
# non-zero when this process is in no pane at all.
fm_afk_start_own_backend() {
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  return 1
}

fm_afk_start_own_pane() {
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  return 1
}

fm_afk_start_native_refused() {
  local harness own_backend own_pane target
  harness=$("$FM_AFK_START_DIR/fm-harness.sh" 2>/dev/null) || harness=unknown
  [ "$harness" = claude ] || return 1

  # Resolve backend FIRST and narrow the "cannot check myself" diagnostic to
  # when it is actually true: herdr provably absent (no TMUX_PANE, no
  # HERDR_ENV+HERDR_PANE_ID) or resolved to a different backend is not
  # ambiguity, it is proof there is nothing to warn about - permit silently.
  own_backend=$(fm_afk_start_own_backend) || return 1
  [ "$own_backend" = herdr ] || return 1

  own_pane=$(fm_afk_start_own_pane) || {
    echo "afk: resolved this process's own backend as herdr but could not resolve its own pane, so the claude+herdr self-injection guard cannot check itself; permitting this start rather than blocking on unknown state" >&2
    return 1
  }

  target=$(discover_supervisor_target) || {
    echo "afk: cannot resolve the escalation injection target, so the claude+herdr self-injection guard cannot check itself; permitting this start rather than blocking on unknown state" >&2
    return 1
  }

  [ "$own_pane" = "$target" ] || return 1
  return 0
}

# fm_afk_clear_stale_artifacts: on a FRESH away-session entry (the daemon is not
# already running), drop the previous away session's leftover escalation-delivery
# artifacts so they cannot surface as stale escalations under the new session.
# These are session-scoped by timing: a fresh entry owns a new supervision
# session and the new daemon has not produced anything yet, so anything present
# here belongs to a PRIOR session. This never drops a genuinely-pending
# escalation - the delivery buffer is a transient cache, and any condition still
# true (a crew still blocked, a check still firing) is re-derived and re-escalated
# fresh by the daemon's heartbeat catch-all scan and the durable
# state/.wake-queue replay (see docs/herdr-backend.md "Away-mode stale-artifact
# lifecycle" and bin/fm-supervise-daemon.sh's escalate_add/inject_wedge_alarm).
# NOT called on a refresh (daemon already alive), so the current session's own
# buffered escalations are preserved.
fm_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" 2>/dev/null
}

daemon_lock_owner() {
  local owner
  if [ -L "$FM_AFK_LOCK" ]; then
    owner=$(readlink "$FM_AFK_LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$FM_AFK_LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$FM_AFK_LOCK" ] || return 1
  printf '%s\n' "$FM_AFK_LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$FM_AFK_DAEMON"*|*"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  local owner pid
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  daemon_pid_matches "$pid" "$owner"
}

fm_afk_flag_write() {  # <state-dir>
  local state=$1 lock="$1/.cursor-park-owner.lock" pending attempt=0 status=1
  mkdir -p "$state" || return 1
  [ ! -d "$state/.afk" ] || return 1
  pending=$(mktemp "$state/.afk.pending.XXXXXX") || return 1
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  while [ "$attempt" -lt 50 ]; do
    attempt=$((attempt + 1))
    if fm_lock_try_acquire "$lock"; then
      mv "$pending" "$state/.afk" && status=0
      fm_lock_release "$lock"
      rm -f "$pending" 2>/dev/null || true
      return "$status"
    fi
    [ "$attempt" -lt 50 ] && sleep 0.1
  done
  rm -f "$pending" 2>/dev/null || true
  return 1
}

# Write (or verify) the lifecycle flag on the path that has decided to proceed.
# Shared by the refresh and fresh branches of fm_afk_start_main so neither
# writes it before that decision is made.
fm_afk_start_ensure_flag() {
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    [ -f "$FM_AFK_STATE/.afk" ] || { echo "afk: launcher-prepared state is missing" >&2; return 1; }
  else
    fm_afk_flag_write "$FM_AFK_STATE" || { echo "afk: failed to write away-mode flag" >&2; return 1; }
  fi
}

fm_afk_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-afk-start.sh}")" >&2; return 2 ;;
  esac

  mkdir -p "$FM_AFK_STATE"

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    fm_afk_start_ensure_flag || return 1
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  # Only a genuine FRESH start reaches here (a refresh of an already-live,
  # already-safely-hosted daemon returned above, untouched). Decide BEFORE
  # writing any lifecycle state, so a refusal leaves nothing to roll back.
  if fm_afk_start_native_refused; then
    echo "afk: refusing to host the away daemon in the same pane it injects into on claude+herdr: a claude background shell renders in that pane's footer, herdr reads that as the agent working, so the away daemon defers forever and away mode silently delivers nothing" >&2
    echo "afk: use 'bin/fm-afk-launch.sh start' instead (non-visible daemon terminal)" >&2
    return 1
  fi

  fm_afk_start_ensure_flag || return 1

  if fm_pid_alive "$pid" && [ -n "$pid" ]; then
    fm_lock_remove_path "$FM_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  if [ "${FM_AFK_STATE_PREPARED:-0}" != 1 ]; then
    fm_afk_clear_stale_artifacts "$FM_AFK_STATE"
  fi

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  exec "$FM_AFK_DAEMON"
}

# Run only when executed, not when sourced (tests source fm_afk_clear_stale_artifacts
# and the lock helpers directly).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_start_main "$@"
fi
