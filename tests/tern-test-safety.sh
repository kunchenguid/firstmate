#!/usr/bin/env bash
# tests/tern-test-safety.sh - shared hard guard against a real-Tern test's
# cleanup ever touching a session or block that is not one the test itself
# just created. Mirrors tests/zellij-test-safety.sh's/tests/cmux-test-safety.sh's
# guard, adapted to Tern's shape: there is one running Tern window (the same
# real window the captain, and a firstmate primary hosted in a Tern block,
# work in), and sessions, tabs and blocks inside it are plain 64-bit integer
# ids with human names. The safety rule is therefore: only ever touch a
# session whose NAME carries the fm-test- prefix and whose id this test
# created, never a session that hosts the block this test itself runs in
# ($TERN_PANE), and never enumerate-and-close.
#
# Fails CLOSED: any ambiguity (an empty or non-numeric id, a name without the
# fm-test- prefix, a session that is not currently listed under exactly that
# name, a session hosting the caller's own block, an unreadable listing)
# refuses rather than proceeding, because the cost of a false refusal (a
# leaked test session, cleaned up by hand later) is recoverable, while the
# cost of a false negative (closing the captain's live session) is not.
#
# Ids are read from `tern ls --json` with every integer id quoted first, so
# a 64-bit id above 2^53 is compared as text and never rounded by a jq that
# converts numbers to doubles.
set -u

# tern_test_ls_json: `tern ls --json` with every "id" integer turned into a
# string. Fails (non-zero, no output) when the listing is unavailable.
tern_test_ls_json() {
  local out
  out=$(tern ls --json 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed -E 's/("id"[[:space:]]*:[[:space:]]*)([0-9]+)/\1"\2"/g'
}

# tern_refuse_if_unsafe: 0 (SAFE to proceed) only if <session_id> is a plain
# integer, <want_name> carries the fm-test- prefix, the session is CURRENTLY
# LISTED under exactly <want_name>, and no block of that session is the
# caller's own ($TERN_PANE). 1 (REFUSE) on anything else.
tern_refuse_if_unsafe() {  # <session_id> <want_name>
  local sid=$1 want_name=$2 listing name own
  case "$sid" in
    ''|*[!0-9]*) echo "tern safety guard: refusing - session id '$sid' is not a plain integer" >&2; return 1 ;;
  esac
  case "$want_name" in
    fm-test-*) : ;;
    *) echo "tern safety guard: refusing - session name '$want_name' does not carry the fm-test- prefix" >&2; return 1 ;;
  esac
  listing=$(tern_test_ls_json) || { echo "tern safety guard: refusing - 'tern ls --json' failed" >&2; return 1; }
  name=$(printf '%s' "$listing" | jq -r --arg id "$sid" '.sessions[]? | select(.id == $id) | .name' 2>/dev/null)
  if [ "$name" != "$want_name" ]; then
    echo "tern safety guard: refusing - session $sid name '${name:-<not found>}' does not match expected '$want_name'" >&2
    return 1
  fi
  if [ -n "${TERN_PANE:-}" ]; then
    own=$(printf '%s' "$listing" | jq -r --arg id "$sid" --arg pane "$TERN_PANE" \
      '.sessions[]? | select(.id == $id) | .tabs[]?.blocks[]? | select(.id == $pane) | .id' 2>/dev/null)
    if [ -n "$own" ]; then
      echo "tern safety guard: refusing - session $sid hosts this test's own block $TERN_PANE" >&2
      return 1
    fi
  fi
  return 0
}

# tern_safe_kill_session: the ONLY sanctioned way for a test to tear down a
# session it created. Guards first (tern_refuse_if_unsafe), then kills that one
# session by explicit id - never a bulk or enumerate-based kill. Best-effort
# past the guard (a session already gone must not fail the caller's cleanup
# trap) - but the guard itself is NOT best-effort: a refusal leaves the
# throwaway fm-test- session open rather than risk the wrong target.
tern_safe_kill_session() {  # <session_id> <want_name>
  tern_refuse_if_unsafe "$1" "$2" || return 1
  tern kill session "$1" >/dev/null 2>&1 || true
}
