#!/usr/bin/env bash
# tests/thurbox-test-safety.sh - shared hard guard for thurbox backend tests.
#
# Mirrors tests/{herdr,zellij,cmux}-test-safety.sh in purpose, but the rule it
# enforces is STRICTER than any of theirs, for a reason specific to thurbox's
# shape: a thurbox test must never reach a REAL thurbox at all.
#
# Why the other backends can be gentler. herdr and zellij each let a test spin
# up an isolated, throwaway SESSION and tear only that down; cmux has no
# throwaway session, so its guard settles for "never close a workspace this
# test did not create". thurbox has neither escape hatch, and two verified
# properties make a real-CLI test actively unsafe:
#
#   1. THURBOX_CONFIG_DIR/THURBOX_DATA_DIR relocate a thurbox instance's config
#      and its SQLite database, but NOT its tmux socket. So even a perfectly
#      isolated test database creates its windows on the SAME tmux server that
#      holds the operator's real sessions.
#   2. Creating the first session in an instance also spawns thurbox's own
#      `automation-heartbeat` window on that shared socket - a background
#      `while true; do thurbox-cli automation tick; sleep 60; done` loop that
#      no `session delete --force` reclaims, because it is not a session. A
#      test suite that created sessions would leak one of those per run into
#      the operator's live tmux server.
#
# Both were observed in the live verification pass (docs/thurbox-backend.md
# "Isolation and its limit"), which is also why that pass was done by hand,
# once, with an explicit manual cleanup - and not turned into a test.
#
# The rule, therefore: the thurbox CLI a test runs MUST be a stub inside the
# test's own temp root. Fails CLOSED - an unset, non-existent, or
# outside-the-fixture binary refuses rather than proceeding, because the cost
# of a false refusal (a skipped test) is trivially recoverable while the cost
# of a false negative (mutating the operator's live sessions) is not.
set -u

# thurbox_refuse_if_unsafe: 0 (SAFE to proceed) only when FM_THURBOX_BIN names
# an executable file located INSIDE <fixture-root>. 1 (REFUSE) otherwise.
#
# The containment check is done on resolved absolute paths, so neither a
# relative path nor a `..` traversal out of the fixture can smuggle in the real
# CLI. `thurbox-cli` found merely on PATH is never acceptable: that is the
# operator's own installation by definition.
thurbox_refuse_if_unsafe() {  # <fixture-root>
  local root=$1 bin real_root real_bin
  bin=${FM_THURBOX_BIN:-}
  [ -n "$root" ] || { echo "thurbox safety guard: refusing - empty fixture root" >&2; return 1; }
  [ -n "$bin" ] || { echo "thurbox safety guard: refusing - FM_THURBOX_BIN is unset, so the adapter would run the REAL thurbox-cli from PATH against the operator's live sessions" >&2; return 1; }
  [ -x "$bin" ] || { echo "thurbox safety guard: refusing - FM_THURBOX_BIN '$bin' is not an executable file" >&2; return 1; }
  real_root=$(cd "$root" 2>/dev/null && pwd -P) || { echo "thurbox safety guard: refusing - fixture root '$root' is not a readable directory" >&2; return 1; }
  real_bin=$(cd "$(dirname "$bin")" 2>/dev/null && pwd -P)/$(basename "$bin") || { echo "thurbox safety guard: refusing - cannot resolve FM_THURBOX_BIN '$bin'" >&2; return 1; }
  case "$real_bin" in
    "$real_root"/*) : ;;
    *)
      echo "thurbox safety guard: refusing - FM_THURBOX_BIN '$real_bin' is outside the test fixture '$real_root'; a thurbox test must never run a real thurbox-cli (see this file's header)" >&2
      return 1
      ;;
  esac
  return 0
}
