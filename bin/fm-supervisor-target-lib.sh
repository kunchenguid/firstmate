#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - shared resolution of the away-mode daemon's
# supervisor pane (the pane running firstmate itself, where escalations land).
#
# One owner for a single contract: "what counts as a trustworthy supervisor
# target, and how is it resolved". Both bin/fm-supervise-daemon.sh (which injects
# the escalation) and bin/fm-afk-start.sh (which refuses /afk fast when no
# injectable target can be verified) source this file, so the rules never drift.
#
# Sourced, never executed. Pure functions plus two default constants; it reads
# only the environment (FM_SUPERVISOR_TARGET/BACKEND overrides, TMUX_PANE, the
# HERDR_* markers) and never mutates state, so it is safe under `set -e`.
#
# The blind-fallback case is why this exists: when firstmate's own CLI runs
# OUTSIDE tmux (no TMUX_PANE) with no override and no herdr markers, the only
# thing left is the legacy "firstmate:0" guess - which is the CREWMATE tmux
# session, not firstmate's input. Injecting there wedges the daemon silently
# (state/.subsuper-inject-wedged). discover_supervisor_target signals that case
# with a non-zero return; supervisor_target_is_trustworthy is the predicate
# callers use to refuse activation before any damage is done.

# The legacy tmux fallback target/backend, used only when nothing trustworthy is
# detected. Guarded so a caller (or test) that pre-set them wins, and so
# re-sourcing is idempotent. "firstmate:0" is a tmux session:window name, so the
# bare fallback assumes tmux - matching the daemon's pre-herdr-support behavior
# byte-for-byte when run outside both tmux and herdr.
: "${FM_SUPERVISOR_TARGET_DEFAULT:=firstmate:0}"
: "${FM_SUPERVISOR_BACKEND_DEFAULT:=tmux}"

# Auto-discover the supervisor pane. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - caller passes it in;
#      may be a tmux target or a herdr "<session>:<pane-id>" target (paired
#      with discover_supervisor_backend, below, to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by
#      the daemon when the /afk skill launches it from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process
#      it manages a pane for (docs/herdr-backend.md); the daemon composes the
#      "<session>:<pane-id>" target string the herdr adapter expects from
#      $HERDR_SESSION (defaulting to "default", mirroring
#      bin/backends/herdr.sh's fm_backend_herdr_session) and $HERDR_PANE_ID.
#      Checked after $TMUX_PANE so a tmux pane nested inside herdr still
#      resolves to tmux, matching fm_backend_detect's innermost-first rule.
#   4. firstmate:0 - legacy tmux fallback (a blind guess; may not resolve, or
#      worse, may resolve to a crewmate session). The caller must treat the
#      non-zero return as "no trustworthy target" and refuse, not proceed.
# Returns the resolved target on stdout; returns 1 if only the blind fallback is
# left (no override, no TMUX_PANE, no HERDR_ENV/HERDR_PANE_ID).
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# Auto-discover the supervisor's BACKEND - independent of the target string
# above, so an explicit FM_SUPERVISOR_TARGET override still needs to know which
# primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback above.
# Returns the resolved backend on stdout; returns 1 if only the fallback is left.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}

# supervisor_target_is_trustworthy: 0 when a real supervisor target can be
# resolved from an explicit override or the running environment (TMUX_PANE or
# herdr markers), non-zero when the only thing left is the blind firstmate:0
# fallback. This is the single guard callers use to refuse away-mode activation
# instead of injecting escalations into an unverifiable (and possibly crewmate)
# pane. It reuses discover_supervisor_target's return code so the "trustworthy
# source" contract lives in exactly one place.
supervisor_target_is_trustworthy() {
  discover_supervisor_target >/dev/null 2>&1
}
