#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# discover_supervisor_rex_target: the "<session-uuid>:<block-uuid>" of the Rex
# pane this process runs in, only when bin/backends/rex.sh's
# fm_backend_rex_launcher_identity PROVES it: REX_BLOCK is live on the Rex
# server, inside REX_SESSION, and that block's child process is an ancestor of
# this one. REX_* alone never counts, because it leaks into every descendant
# (a tmux server started from a Rex pane included) and would then name
# someone else's pane. Needs bin/fm-backend.sh already sourced.
discover_supervisor_rex_target() {
  [ -n "${REX_BLOCK:-}" ] && [ -n "${REX_SESSION:-}" ] || return 1
  declare -F fm_backend_source >/dev/null 2>&1 || return 1
  fm_backend_source rex >/dev/null 2>&1 || return 1
  fm_backend_rex_supervisor_target 2>/dev/null
}

# discover_supervisor_rex_server: the Rex server a rex supervisor target lives
# on (bin/backends/rex.sh's fm_backend_rex_server order), so a launcher can hand
# it to a daemon running in a terminal of its own as FM_REX_SERVER.
discover_supervisor_rex_server() {
  declare -F fm_backend_source >/dev/null 2>&1 || return 1
  fm_backend_source rex >/dev/null 2>&1 || return 1
  fm_backend_rex_server 2>/dev/null
}

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - uses the exact tmux target
#      forms owned by bin/fm-backend.sh's fm_backend_target_exists header, or a
#      herdr "<session>:<pane-id>" target, or a rex "<session-uuid>:<block-uuid>"
#      target (paired with discover_supervisor_backend to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. A structurally proven Rex pane (discover_supervisor_rex_target) - checked
#      after both, again innermost-first, so inherited REX_* under tmux or herdr
#      never wins.
#   5. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
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
  local rex_target
  if rex_target=$(discover_supervisor_rex_target); then
    printf '%s' "$rex_target"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. A structurally proven Rex pane - rex.
#   5. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
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
  if discover_supervisor_rex_target >/dev/null; then
    printf 'rex'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
