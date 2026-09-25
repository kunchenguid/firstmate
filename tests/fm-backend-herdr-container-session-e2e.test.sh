#!/usr/bin/env bash
# tests/fm-backend-herdr-container-session-e2e.test.sh - real-herdr end-to-end
# proof for the container session-binding fix (PR #2's HERDR_SOCKET_PATH
# detection fallback + the session-resolution completeness gap).
#
# PR #2 taught bin/fm-backend.sh's fm_backend_detect() to report "herdr" for a
# container that only has HERDR_SOCKET_PATH forwarded (no HERDR_ENV/HERDR_SESSION),
# but left every downstream operational call in bin/backends/herdr.sh resolving
# its target purely by HERDR_SESSION (default "default"), independent of that
# socket. This suite proves the closed gap against a REAL herdr binary: a
# devcontainer-shaped process that has ONLY HERDR_SOCKET_PATH set (HERDR_SESSION
# and HERDR_ENV both absent, exactly the detection fallback's precondition)
# resolves fm_backend_herdr_session() to the socket's OWN session, and an
# operational call chain resolved that way (fm_backend_herdr_container_ensure,
# same as a real spawn) reaches the already-running server behind that socket
# instead of silently starting a brand-new, disconnected one.
#
# Safety: this suite runs against its own isolated, named, throwaway
# HERDR_SESSION (never the default session), created and torn down only
# through tests/herdr-test-safety.sh's guarded helpers (bin/fm-herdr-lab.sh),
# mirroring tests/fm-backend-herdr-smoke.test.sh. The container-shaped call
# below asserts the socket-derived session name matches the real lab session
# BEFORE making any operational call, so a regression can never silently fall
# back to touching this machine's actual "default" session. Skips cleanly when
# herdr (or jq) is not installed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# A Herdr pane identity inherited from the terminal this test was launched in
# must not leak into the "only HERDR_SOCKET_PATH is set" scenario below.
herdr_forget_inherited_pane

SESSION="fm-lab-container-session-$$"
export HERDR_SESSION="$SESSION"
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# Stand up the isolated lab session's real server (normal host-side operation,
# HERDR_SESSION set explicitly - not the scenario under test yet).
fm_backend_herdr_server_ensure "$SESSION" \
  || fail "could not bring up the isolated lab session's real herdr server"

SOCKET=$(fm_backend_herdr_socket_path "$SESSION")
[ -n "$SOCKET" ] || fail "could not resolve the isolated lab session's real control-socket path"
[ -S "$SOCKET" ] || fail "resolved socket path '$SOCKET' is not actually a socket"
pass "real herdr: resolved the isolated lab session's real control-socket path"

# --- fm_backend_herdr_session: derives the exact lab session from the socket alone ---
#
# This is the devcontainer shape: HERDR_ENV and HERDR_SESSION both absent,
# only HERDR_SOCKET_PATH forwarded/mounted - exactly fm_backend_detect's
# HERDR_SOCKET_PATH fallback precondition (bin/fm-backend.sh).
DERIVED=$(unset HERDR_ENV HERDR_SESSION; HERDR_SOCKET_PATH="$SOCKET" fm_backend_herdr_session)
[ "$DERIVED" = "$SESSION" ] \
  || fail "fm_backend_herdr_session should derive '$SESSION' from its real socket path alone, got '$DERIVED'"
pass "real herdr: fm_backend_herdr_session derives the exact lab session name from a real HERDR_SOCKET_PATH alone"

# --- the operational call chain this env resolves to reaches the SAME live
# --- server, not a fresh disconnected one ---
BEFORE_SOCKET=$SOCKET

# Reproduce the exact devcontainer env (only HERDR_SOCKET_PATH set) and run
# the same operational entry point a real spawn uses
# (fm_backend_herdr_container_ensure, which internally resolves its session
# via fm_backend_herdr_session when none is passed - bin/backends/herdr.sh).
# The derived-session equality check runs FIRST and unconditionally refuses
# before any operational call, so a regression here can never fall through to
# operating on this machine's real "default" session.
CONTAINER_OUT=$(
  unset HERDR_ENV HERDR_SESSION
  export HERDR_SOCKET_PATH="$SOCKET"
  CONTAINER_SES=$(fm_backend_herdr_session)
  if [ "$CONTAINER_SES" != "$SESSION" ]; then
    echo "derived session '$CONTAINER_SES' does not match the real lab session '$SESSION'; refusing the operational call for safety" >&2
    exit 9
  fi
  fm_backend_herdr_container_ensure /tmp
) || fail "the container-shaped fm_backend_herdr_session -> fm_backend_herdr_container_ensure chain failed (rc $?)"

case "$CONTAINER_OUT" in
  "$SESSION":*) : ;;
  *) fail "container_ensure resolved through the container-shaped env did not target the lab session, got '$CONTAINER_OUT'" ;;
esac
pass "real herdr: container_ensure resolved purely from HERDR_SOCKET_PATH targets the exact real lab session"

AFTER_SOCKET=$(fm_backend_herdr_socket_path "$SESSION")
[ "$AFTER_SOCKET" = "$BEFORE_SOCKET" ] \
  || fail "the lab session's control-socket path changed after the container-shaped call ($BEFORE_SOCKET -> $AFTER_SOCKET): its server was restarted rather than reused"
pass "real herdr: the container-shaped call reused the already-running server's exact socket, never starting a fresh disconnected one"

cleanup_all
trap - EXIT
