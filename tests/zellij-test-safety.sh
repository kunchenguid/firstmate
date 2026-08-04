#!/usr/bin/env bash
# tests/zellij-test-safety.sh - shared hard guard against a real-zellij test's
# cleanup ever touching the machine's real "firstmate" session (the default
# session name bin/backends/zellij.sh uses for actual firstmate task tabs) or
# running a fleet-wide destructive command. Mirrors
# tests/herdr-test-safety.sh's guard, adapted to zellij's session model and
# the safety rule this task was given directly (never `kill-all-sessions`,
# the same discipline PR #199 established for herdr after two live-fleet
# kills - see tests/herdr-test-safety.sh's incident note).
#
# Zellij's own risk shape differs from herdr's: there is no ambient
# `server stop`-style command that silently resolves to "whatever session is
# currently running" - `zellij kill-session <name>` and
# `zellij delete-session <name>` both take an explicit, required name. So the
# realistic failure mode here is not env-var-routing unreliability (herdr's
# root cause) but a test accidentally reusing (and then killing) the real
# "firstmate" session name, or a caller reaching for the fleet-wide
# `kill-all-sessions`/`delete-all-sessions` commands. This guard defends
# against both: it refuses to touch a session unless the caller can name it
# explicitly, that name is NOT "firstmate" (the real default), and it is
# currently listed as a session this test itself is responsible for.
#
# Fails CLOSED: any ambiguity (an empty name, the literal default name, a
# failed/empty session list, a name that does not resolve) refuses rather
# than proceeding, because the cost of a false refusal (a leaked test
# session, cleaned up by hand later) is trivially recoverable, while the cost
# of a false negative (deleting the real session) is not.
set -u

# zellij_refuse_if_unsafe: 0 (SAFE to proceed) only if <name> is non-empty,
# is NOT the literal "firstmate" default session name, and IS currently
# listed as an active zellij session. 1 (REFUSE) on anything else.
zellij_refuse_if_unsafe() {  # <name>
  local name=$1 listed
  [ -n "$name" ] || { echo "zellij safety guard: refusing - empty session name" >&2; return 1; }
  if [ "$name" = firstmate ]; then
    echo "zellij safety guard: refusing - name is literally 'firstmate' (the real default session a live fleet may use)" >&2
    return 1
  fi
  listed=$(zellij list-sessions --short --no-formatting 2>/dev/null | grep -qxF "$name" && echo yes || echo no)
  if [ "$listed" != yes ]; then
    echo "zellij safety guard: refusing - session '$name' not found in 'zellij list-sessions'" >&2
    return 1
  fi
  return 0
}

# zellij_safe_delete: the ONLY sanctioned way for a test to tear down an
# isolated session it created. Guards first (zellij_refuse_if_unsafe), then
# uses the explicit-by-name `delete-session --force` form (kills if running,
# then deletes in one call) - NEVER `kill-all-sessions` or
# `delete-all-sessions`. Best-effort past the guard (a session already gone
# must not fail the caller's cleanup trap) - but the guard itself is NOT
# best-effort: a refusal here means cleanup leaves the isolated, throwaway,
# never-"firstmate" session running rather than risk the wrong target.
zellij_safe_delete() {  # <name>
  local name=$1
  zellij_refuse_if_unsafe "$name" || return 1
  zellij delete-session "$name" --force >/dev/null 2>&1 || true
}
