#!/usr/bin/env bash
# tests/harness-binary-helpers.sh - the single harness-binary resolver for the opt-in
# real-harness drift guards.
#
# Both guards launch every INSTALLED harness for real and fail naming the
# harness and version, so both have to launch the SAME binary bin/fm-spawn.sh
# would launch. Two copies of this resolution diverged once already and made
# one guard report a drift the other could not see, so the resolution lives
# here and each guard calls it.
#
# Sourcing it requires nothing but the repo root; it pulls in the verified
# cursor resolver itself when the caller has not already sourced it.
set -u

FM_TEST_HARNESS_BINARY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v fm_cursor_resolve_binary >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$FM_TEST_HARNESS_BINARY_DIR/bin/fm-cursor-lib.sh"
fi

# fm_test_resolve_harness_binary: echo the executable a real launch of
# <harness> would run, or return 1 when it is not installed here.
#
# cursor is resolved FIRST and never through a bare PATH lookup. It installs as
# `cursor-agent` plus the legacy alias `agent`, its user-local install is
# routinely absent from a non-interactive PATH, and a `cursor` that IS on PATH
# is routinely the editor launcher rather than the agent (observed on a
# developer machine, where it answered a `--trust` launch with an Electron
# warning and exited, which made the guard report a drift that did not exist).
# fm_cursor_resolve_binary is the verified owner fm-spawn itself uses, so this
# both rejects an unrelated executable named `agent` exactly as a real launch
# would and never mistakes the editor launcher for the agent.
#
# kimi is not required to be on PATH: its installer drops a user-local binary,
# which fm-spawn falls back to and so does this.
fm_test_resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}
