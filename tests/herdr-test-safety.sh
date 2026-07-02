#!/usr/bin/env bash
# tests/herdr-test-safety.sh - shared hard guard against a real-herdr test's
# cleanup ever stopping/deleting the machine's DEFAULT herdr session. Source
# this from any test file that starts an isolated herdr session and must tear
# it down.
#
# Root cause this guards against (docs/herdr-backend.md "Session targeting: the
# --session flag, not HERDR_SESSION alone"): on the installed herdr 0.7.1
# client, NEITHER an exported HERDR_SESSION NOR an inline `HERDR_SESSION="$x"`
# prefix reliably routes a CLI subcommand to the named session once another
# herdr server (e.g. the captain's live default session) is already bound on
# the machine - it silently falls back to whatever server IS running instead
# of the requested one. This bit production twice on 2026-07-02:
# tests/fm-backend-herdr-smoke.test.sh's `herdr server stop` (fully unscoped)
# and tests/fm-backend-autodetect-smoke.test.sh's
# `HERDR_SESSION="$SESSION" herdr server stop` (inline-prefixed - which looked
# safer but was verified to be exactly as vulnerable) both killed the
# captain's live default herdr server instead of their own isolated throwaway
# session, twice, on two different runs.
#
# The fix is two independent layers, because either alone is not enough:
#
#   1. Never call the ambient `herdr server stop` (it takes NO target at all -
#      it always acts on "whatever server is running", resolved ambiently).
#      Use `herdr session stop <name>` instead: <name> is a REQUIRED
#      positional argument, so herdr cannot resolve it ambiguously - herdr's
#      own help text says to literally type "default" to affect the default
#      session, making an accidental hit structurally much harder. --session
#      <name> is appended too, for defense in depth (verified empirically to
#      work in trailing position for every herdr subcommand tried, including
#      `session stop`/`session delete`; see docs/herdr-backend.md).
#   2. herdr_refuse_if_default: a READ-ONLY pre-check, run immediately before
#      ANY stop/delete, that queries `herdr session list --json` (which
#      enumerates every session, each carrying its own `default` flag) and
#      refuses outright if <name> is literally "default", is not currently
#      listed, or IS flagged default:true. This is the "hard guard" layer:
#      it does not trust that layer 1's explicit targeting worked: it
#      independently re-verifies from a fresh read before every destructive
#      call.
#
# Fails CLOSED: any ambiguity (a failed/empty session list, a name that does
# not resolve) refuses rather than proceeding, because the cost of a false
# refusal (a leaked test session, cleaned up by hand later) is trivially
# recoverable, while the cost of a false negative (stopping the wrong server)
# is not.
set -u

# herdr_refuse_if_default: 0 (SAFE to proceed) only if <name> is a currently-
# listed, non-default session. 1 (REFUSE) on anything else.
herdr_refuse_if_default() {  # <name>
  local name=$1 info flag
  [ -n "$name" ] || { echo "herdr safety guard: refusing - empty session name" >&2; return 1; }
  if [ "$name" = default ]; then
    echo "herdr safety guard: refusing - name is literally 'default'" >&2
    return 1
  fi
  info=$(herdr session list --json 2>/dev/null) || { echo "herdr safety guard: refusing - 'herdr session list --json' failed, cannot verify" >&2; return 1; }
  flag=$(printf '%s' "$info" | jq -r --arg n "$name" '.sessions[]? | select(.name == $n) | .default' 2>/dev/null)
  if [ "$flag" = "false" ]; then
    return 0
  fi
  echo "herdr safety guard: refusing - session '$name' not found in 'herdr session list', or flagged default (default=${flag:-<not found>})" >&2
  return 1
}

# herdr_safe_stop_and_delete: the ONLY sanctioned way for a test to tear down
# an isolated session it created. Guards first (herdr_refuse_if_default), then
# uses the explicit-by-name `session stop`/`session delete` forms (never the
# ambient `server stop`), with --session appended too. Best-effort past the
# guard (a session already gone, or never fully started, must not fail the
# caller's cleanup trap) - but the guard itself is NOT best-effort: a refusal
# here means cleanup_all leaves the (isolated, throwaway, never-default)
# session running rather than risk the wrong target.
herdr_safe_stop_and_delete() {  # <name>
  local name=$1
  herdr_refuse_if_default "$name" || return 1
  herdr session stop "$name" --session "$name" --json >/dev/null 2>&1 || true
  sleep 0.5
  herdr_refuse_if_default "$name" || return 1
  herdr session delete "$name" --session "$name" --json >/dev/null 2>&1 || true
}
