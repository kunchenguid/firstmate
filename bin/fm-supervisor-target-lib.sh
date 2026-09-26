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

# An explicit target must carry an explicit supported backend, or be inherited
# from a Herdr pane. Never reinterpret an old firstmate:0 or %pane fallback.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    discover_supervisor_backend >/dev/null || return 1
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  echo "error: no Herdr supervisor pane identity; set FM_SUPERVISOR_BACKEND=herdr and FM_SUPERVISOR_TARGET=session:pane" >&2
  return 1
}

discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    [ "$FM_SUPERVISOR_BACKEND" = herdr ] || {
      echo "error: unsupported supervisor backend '$FM_SUPERVISOR_BACKEND'; only Herdr is supported" >&2
      return 1
    }
    printf 'herdr'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  echo "error: no supported supervisor backend identity" >&2
  return 1
}
