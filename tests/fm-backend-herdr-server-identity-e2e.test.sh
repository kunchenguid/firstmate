#!/usr/bin/env bash
# tests/fm-backend-herdr-server-identity-e2e.test.sh - real-herdr regression
# test for the 2026-08-01 incident: fm_backend_herdr_server_ensure addressed a
# server purely by SESSION NAME, and a single misreported liveness probe was
# enough to make it invoke `herdr ... server` again against an ALREADY-alive
# session - reproduced against the real binary by forcing exactly one
# `status --json` probe to misreport: the session was unreachable for the
# remainder of server_ensure's 10s poll before recovering, a real disruptive
# restart of a server nothing was wrong with. fm-spawn.sh's own workspace
# PLACEMENT was already fixed by commit f0d7cbe ("place workers in the
# launching workspace"); this suite covers what that commit did not touch:
# server_ensure's own autostart decision, and ordinary send/read binding.
#
# Every scenario below drives the REAL bin/backends/herdr.sh functions
# in-process (never a rewritten copy) against an isolated, non-default lab
# session. Only fm_backend_herdr_cli itself is wrapped, to (a) log every call
# so a scenario can assert "server" was never invoked, and (b) inject one
# controlled fault at a time (a misreported liveness probe, or an ambiguous
# session-list result) - never a bypass of bin/fm-herdr-lab.sh's safety net,
# since every call still carries the lab's own explicit --session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}
assert_not_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane

SESSION="fm-lab-server-identity-$$"
export HERDR_SESSION="$SESSION"
CLEANED=0
# Idempotent: fail() cleans up before exiting and the EXIT trap fires after
# it, so a second teardown would otherwise report the already-consumed
# fleet-state tripwire as if the lab had gone wrong.
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# container_ensure both starts this isolated session's real server and gives
# us a real workspace to hang a "launcher pane" off of.
CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
WSID=${CONTAINER#*:}

LAB_SOCKET=$(herdr session list --json --session "$SESSION" 2>/dev/null \
  | jq -r --arg s "$SESSION" '.sessions[]? | select(.name == $s) | .socket_path')
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's real socket path"

# A real pane inside the primary workspace, standing in for "the captain's own
# pane" / firstmate's own launcher identity.
LAUNCH_OUT=$(herdr tab create --workspace "$WSID" --cwd /tmp --label captain-shell --no-focus --session "$SESSION" 2>/dev/null) \
  || fail "could not create the launcher pane"
LAUNCH_PANE=$(printf '%s' "$LAUNCH_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$LAUNCH_PANE" ] || fail "launcher pane creation did not return a pane id"

CALL_LOG=$(mktemp "${TMPDIR:-/tmp}/fm-herdr-server-identity-log.XXXXXX")
POISON_MODE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-herdr-server-identity-mode.XXXXXX")
POISON_USED_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-herdr-server-identity-used.XXXXXX")

eval "$(declare -f fm_backend_herdr_cli | sed '1s/fm_backend_herdr_cli/fm_backend_herdr_cli_real/')"

set_poison_mode() { printf '%s' "$1" > "$POISON_MODE_FILE"; : > "$POISON_USED_FILE"; }
poison_was_used() { [ -s "$POISON_USED_FILE" ]; }

# fm_backend_herdr_cli (test double): logs every call unit-separated, then
# injects at most one controlled fault per the current poison mode before
# falling through to the REAL implementation for everything else. State
# lives in files, not shell variables: fm_backend_herdr_server_ensure calls
# this through command substitution ($( )), which forks a subshell, so a
# plain variable write here would never be visible to the caller afterward.
fm_backend_herdr_cli() {  # <session> <herdr-subcommand-and-args...>
  local sess=$1 mode
  shift
  { printf '%s' "$sess"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$CALL_LOG"
  mode=$(cat "$POISON_MODE_FILE" 2>/dev/null || true)
  case "$mode" in
    status-once)
      if [ ! -s "$POISON_USED_FILE" ] && [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
        printf 'used\n' > "$POISON_USED_FILE"
        printf '{"server":{"running":false}}'
        return 0
      fi
      ;;
    sessionlist-ambiguous)
      # The real session IS genuinely healthy, so the plain status probe
      # must also be forced false here (every time, not just once) or it
      # would short-circuit before the ambiguity check is ever reached.
      if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
        printf '{"server":{"running":false}}'
        return 0
      fi
      if [ "${1:-}" = session ] && [ "${2:-}" = list ] && [ "${3:-}" = --json ]; then
        printf '{"sessions":[{"name":"%s","running":true,"socket_path":"/fake/a.sock"},{"name":"%s","running":true,"socket_path":"/fake/b.sock"}]}' "$sess" "$sess"
        return 0
      fi
      ;;
  esac
  fm_backend_herdr_cli_real "$sess" "$@"
}

# --- 1. own-pane identity short-circuit: never restart a session firstmate's
#        own pane already proves is live, even when the liveness probe misses -

export HERDR_ENV=1 HERDR_PANE_ID="$LAUNCH_PANE" HERDR_SOCKET_PATH="$LAB_SOCKET"
: > "$CALL_LOG"
set_poison_mode status-once
fm_backend_herdr_server_ensure "$SESSION"
status=$?
[ "$status" -eq 0 ] || fail "server_ensure must succeed when firstmate's own pane already proves the session is live"
! poison_was_used || fail "the own-pane short-circuit must never even reach the liveness probe it would otherwise be misled by"
assert_not_contains_local "$(cat "$CALL_LOG")" $'\x1f''server'$'\n' \
  "the own-pane short-circuit must never invoke 'herdr ... server' - that is the disruptive restart from the 2026-08-01 incident"
pass "real herdr: server_ensure's own-pane identity proof skips the liveness probe entirely and never restarts an already-live session"

# --- 2. no ancestry: a misreported probe must not restart an already-alive
#        session either - the authoritative session registry catches it -----

unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
: > "$CALL_LOG"
set_poison_mode status-once
fm_backend_herdr_server_ensure "$SESSION"
status=$?
[ "$status" -eq 0 ] || fail "server_ensure must still succeed via the session registry when the probe alone misreports"
poison_was_used || fail "sanity: the liveness probe should have been consulted (and poisoned) with no own-pane identity to short-circuit on"
assert_contains_local "$(cat "$CALL_LOG")" $'\x1f''session'$'\x1f''list'$'\x1f''--json' \
  "server_ensure did not consult the authoritative session registry before concluding it was safe to start a server"
assert_not_contains_local "$(cat "$CALL_LOG")" $'\x1f''server'$'\n' \
  "a misreported liveness probe must never cause a second server to be started against an already-registered, already-running session"
pass "real herdr: even with no launcher identity to bind to, a misreported liveness probe does not restart a session the registry shows is already running"

# --- 3. ambiguous ownership refuses loudly and never starts anything -------

: > "$CALL_LOG"
set_poison_mode sessionlist-ambiguous
err=$(fm_backend_herdr_server_ensure "$SESSION" 2>&1)
status=$?
[ "$status" -ne 0 ] || fail "server_ensure must refuse, not guess, when the session registry shows more than one registration under this name"
assert_contains_local "$err" "2 herdr sessions are already registered" "the ambiguity refusal did not explain itself"
assert_not_contains_local "$(cat "$CALL_LOG")" $'\x1f''server'$'\n' \
  "an ambiguous registration must never be resolved by starting yet another server"
pass "real herdr: server_ensure refuses loudly on an ambiguous session registry instead of guessing or starting another server"

set_poison_mode none

# --- 4. ordinary send/read binds to firstmate's own pane identity: a claimed
#        pane in a DIFFERENT session must refuse to touch this session's real
#        task pane, not silently read/write it -------------------------------

TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-identity-e2e /tmp) || fail "create_task failed"
read -r _TASK_TAB TASK_PANE <<EOF
$TASK_IDS
EOF
[ -n "$TASK_PANE" ] || fail "create_task did not return a pane id"
TARGET="$SESSION:$TASK_PANE"

export HERDR_ENV=1 HERDR_PANE_ID="$LAUNCH_PANE" HERDR_SESSION=someother-session HERDR_SOCKET_PATH="$LAB_SOCKET"
if fm_backend_herdr_capture "$TARGET" 20 >/dev/null 2>"$CALL_LOG.err"; then
  fail "capture must refuse when firstmate's own pane claims a different session than the target"
fi
assert_contains_local "$(cat "$CALL_LOG.err")" "someother-session" \
  "the cross-session send/read refusal did not name the mismatched session"
pass "real herdr: capture refuses to address a target session that firstmate's own pane does not verifiably belong to"

export HERDR_SESSION="$SESSION"
fm_backend_herdr_send_text_line "$TARGET" "echo identity-e2e-ok" || fail "send_text_line failed with a genuinely matching launcher identity"
sleep 0.5
out=$(fm_backend_herdr_capture "$TARGET" 20) || fail "capture failed with a genuinely matching launcher identity"
case "$out" in
  *identity-e2e-ok*) : ;;
  *) fail "real herdr: send/capture did not work with a genuinely matching launcher identity"$'\n'"$out" ;;
esac
pass "real herdr: send/capture still work normally once firstmate's own pane verifiably matches the target session"

unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
rm -f "$CALL_LOG" "$CALL_LOG.err" "$POISON_MODE_FILE" "$POISON_USED_FILE"
cleanup_all
trap - EXIT
pass "real herdr: isolated lab session removed and default fleet session unchanged"
