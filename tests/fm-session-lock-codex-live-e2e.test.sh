#!/usr/bin/env bash
# Token-free live guard for Codex's held thread writer lock.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CODEX_SESSION_LOCK_LIVE codex flock
version=$(codex --version 2>&1)
thread=${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}
if [ -z "$thread" ]; then
  printf 'skip: live: %s has no active thread marker in this shell\n' "$version"
  exit 0
fi

# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
root=$(fm_codex_state_root) || fail "$version: state root is unavailable"
fm_codex_writer_lock_state "$thread" "$root" \
  || fail "$version: this live thread does not hold its writer flock under $root"
identity=$(fm_session_identity) || fail "$version: this live thread has no session identity"
[ "$identity" = "codex:$thread:$root" ] \
  || fail "$version: identity '$identity' did not bind the live thread and state root"
fm_codex_writer_lock_state "$thread" "$root/nonexistent-root"
[ "$?" -eq 1 ] || fail "$version: a different state root appeared to hold this thread"
pass "$version: live Codex thread writer flock identifies this session and its state root"
