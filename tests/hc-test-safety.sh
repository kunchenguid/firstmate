#!/usr/bin/env bash
# tests/hc-test-safety.sh - shared hard guard for tests that drive a REAL
# herdr-core (`hc`). Mirrors tests/tern-test-safety.sh's role, adapted to
# Core's shape: sessions are isolated state/socket domains and the ONLY real
# sessions a test may touch are ones bin/fm-hc-lab.sh owns - named fm-hclab-*,
# holding that helper's fleet-state tripwire inside their session directory.
# The user's own sessions (default in particular) are never enumerated,
# adopted, stopped, or killed.
#
# Fails CLOSED on any ambiguity: an empty or non-fm-hclab- name, a missing lab
# directory, or a missing tripwire file refuses rather than proceeding. The
# cost of a false refusal (a leaked lab session, removed by hand or the
# ci-cleanup helper later) is recoverable; the cost of a false negative
# (killing a session domain holding the user's own terminals) is not.
set -u

# hc_test_lab_dir: the lab root bin/fm-hc-lab.sh computes for this
# environment - kept here so the guard answers "does this session's lab
# record exist" without invoking the helper.
hc_test_lab_dir() {
  printf '%s' "${FM_HC_LAB_DIR:-${TMPDIR:-/tmp}/fm-hc-lab-${UID}}"
}

# hc_test_refuse_if_unsafe: 0 (SAFE to drive) only when <session> names a
# lab-owned core session - the fm-hclab- prefix plus the session directory
# and its fleet-state tripwire both present. 1 (REFUSE) otherwise.
hc_test_refuse_if_unsafe() {  # <session>
  local name=${1:-} dir
  case "$name" in
    fm-hclab-*) : ;;
    '') echo "hc safety guard: refusing - empty session name" >&2; return 1 ;;
    *) echo "hc safety guard: refusing - session '$name' is not an fm-hclab- lab session" >&2; return 1 ;;
  esac
  case "$name" in
    *[!a-zA-Z0-9_-]*)
      echo "hc safety guard: refusing - session name '$name' has characters outside letters, digits, _ and -" >&2
      return 1 ;;
  esac
  dir="$(hc_test_lab_dir)/$name"
  [ -d "$dir" ] || {
    echo "hc safety guard: refusing - no lab directory $dir; '$name' is not this helper's session" >&2
    return 1
  }
  [ -f "$dir/fleet-state.txt" ] && [ -f "$dir/fleet-roots.txt" ] || {
    echo "hc safety guard: refusing - $dir lacks the fleet-state tripwire pair; the lab does not own '$name'" >&2
    return 1
  }
  return 0
}

# hc_test_safe_teardown: the ONLY sanctioned way for a test to tear down a
# lab core session. Guards first (hc_test_refuse_if_unsafe), then delegates
# to bin/fm-hc-lab.sh teardown, which re-checks its own guards and the fleet
# tripwire. The teardown's own result propagates - a fleet-tripwire failure
# or surviving session processes are real failures and the caller's EXIT
# trap must preserve that nonzero result rather than mask it.
hc_test_safe_teardown() {  # <root> <session>
  hc_test_refuse_if_unsafe "$2" || return 1
  "$1/bin/fm-hc-lab.sh" teardown "$2"
}
