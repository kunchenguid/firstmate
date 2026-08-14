#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-verdict-lib.sh - the CI-ready scoring rule.
#
# A green verdict is valid only when at least one check completed with success
# AND none are pending, failed, cancelled, skipped, or never-run. These cases
# drive the public command, never the implementation source:
#   (a) cancelled-only conclusions are not passed
#   (b) zero checks is empty, not passed
#   (c) a genuinely all-success set is passed
#   (d) mixed success-plus-non-success is not passed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERDICT="$ROOT/bin/fm-ci-verdict-lib.sh"

score() {
  "$VERDICT" "$@" < /dev/null
}

test_cancelled_only_is_not_passed() {
  local out
  out=$(score CANCELLED)
  [ "$out" = not-passed ] || fail "cancelled-only scored as '$out', want not-passed"
  out=$(score CANCELED)
  [ "$out" = not-passed ] || fail "canceled-only scored as '$out', want not-passed"
  out=$(score SUCCESS CANCELLED)
  [ "$out" = not-passed ] || fail "success+cancelled scored as '$out', want not-passed"
  [ "$out" != passed ] || fail "cancelled conclusions must never score as passed"
  pass "cancelled-only and mixed-cancelled conclusions are not passed"
}

test_zero_checks_is_not_passed() {
  local out
  out=$(score)
  [ "$out" = empty ] || fail "zero checks scored as '$out', want empty"
  [ "$out" != passed ] || fail "zero checks must never score as passed"
  out=$(printf '\n\n' | "$VERDICT")
  [ "$out" = empty ] || fail "blank-only input scored as '$out', want empty"
  [ "$out" != passed ] || fail "blank-only input must never score as passed"
  pass "zero checks is empty, not passed"
}

test_all_success_is_passed() {
  local out
  out=$(score SUCCESS)
  [ "$out" = passed ] || fail "one success scored as '$out', want passed"
  out=$(score SUCCESS SUCCESS SUCCESS)
  [ "$out" = passed ] || fail "all-success scored as '$out', want passed"
  pass "a genuinely all-success set is passed"
}

test_skipped_pending_failed_never_run_are_not_passed() {
  local out word
  for word in SKIPPED NEUTRAL FAILURE ERROR TIMED_OUT ACTION_REQUIRED \
    STARTUP_FAILURE STALE QUEUED PENDING IN_PROGRESS WAITING REQUESTED \
    NEVER never-run; do
    out=$(score "$word")
    [ "$out" = not-passed ] || fail "$word scored as '$out', want not-passed"
    [ "$out" != passed ] || fail "$word must never score as passed"
    out=$(score SUCCESS "$word")
    [ "$out" = not-passed ] || fail "success+$word scored as '$out', want not-passed"
  done
  pass "skipped, pending, failed, and never-run conclusions are not passed"
}

test_cancelled_only_is_not_passed
test_zero_checks_is_not_passed
test_all_success_is_passed
test_skipped_pending_failed_never_run_are_not_passed

echo "all fm-ci-verdict-lib tests passed"
