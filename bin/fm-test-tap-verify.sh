#!/usr/bin/env bash
# fm-test-tap-verify.sh - prove a TAP-planned suite actually finished.
#
# The stock macOS Bash job used to hard-code expected `ok` counts in
# .github/workflows/ci.yml, so every added test in those suites had to edit the
# workflow. This helper is the replacement: the suite declares its own plan,
# and the helper checks that the run matched it.
#
# A suite declares its plan by calling fm_test_run (tests/lib.sh) with the
# test function names. That prints a TAP plan `1..N` (N is the number of
# names, so adding a test is adding a name, not bumping a numeral), runs
# each function (each must emit exactly one `ok - ` line), then prints
# `FM_TEST_COMPLETE`.
#
# This script runs TEST_SCRIPT under the Bash that is running this helper
# and verifies:
#   - the process exit status is 0
#   - output contains exactly one TAP plan line `1..N` with N >= 1
#   - output contains exactly one `FM_TEST_COMPLETE` line
#   - there are zero `not ok` lines
#   - the number of `ok - ` lines equals N
#
# An early `exit 0` under Bash 3.2 that skips remaining tests therefore fails:
# either the plan is missing, the completion marker is missing, or the ok
# count does not match the plan. That is the guarantee the hard-coded counts
# used to provide.
#
# Usage:
#   fm-test-tap-verify.sh TEST_SCRIPT
#   fm-test-tap-verify.sh -h|--help
#
# The suite's stdout and stderr are replayed unchanged, then a one-line
# summary is printed. Non-zero exit means the completeness check failed.
set -eu

usage() {
  cat <<'EOF'
Usage: fm-test-tap-verify.sh TEST_SCRIPT
       fm-test-tap-verify.sh -h|--help

Run TEST_SCRIPT under the Bash running this helper and require a TAP
plan 1..N, N `ok - ` lines, zero `not ok` lines, FM_TEST_COMPLETE, and
exit status 0.
EOF
}

count_matches() {  # <extended-regex> <file>
  local pattern=$1 file=$2 n
  n=$(grep -c -E "$pattern" "$file" 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

fail_verify() {  # <message>
  local msg=$1
  printf '::error::%s\n' "$msg"
  printf 'fm-test-tap-verify: %s\n' "$msg" >&2
  exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

SCRIPT=$1
[ -f "$SCRIPT" ] || fail_verify "not a file: $SCRIPT"

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-test-tap-verify.XXXXXX") || exit 1
trap 'rm -f "$OUT"' EXIT

set +e
"$BASH" "$SCRIPT" >"$OUT" 2>&1
STATUS=$?
set -e

cat "$OUT"

PLAN_COUNT=$(count_matches '^1\.\.[1-9][0-9]*$' "$OUT")
OK_COUNT=$(count_matches '^ok - ' "$OUT")
NOT_OK_COUNT=$(count_matches '^not ok' "$OUT")
COMPLETE_COUNT=$(count_matches '^FM_TEST_COMPLETE$' "$OUT")
PLAN_LINE=$(grep -E '^1\.\.[1-9][0-9]*$' "$OUT" 2>/dev/null || true)
PLANNED=${PLAN_LINE#1..}
case "$PLANNED" in
  ''|*[!0-9]*) PLANNED=0 ;;
esac

LABEL=${SCRIPT##*/}

if [ "$STATUS" -ne 0 ]; then
  fail_verify "$LABEL exited $STATUS (planned $PLANNED, ok $OK_COUNT, not ok $NOT_OK_COUNT, complete $COMPLETE_COUNT)"
fi
if [ "$PLAN_COUNT" -ne 1 ]; then
  fail_verify "$LABEL must print exactly one TAP plan 1..N, got $PLAN_COUNT (ok $OK_COUNT, complete $COMPLETE_COUNT)"
fi
if [ "$COMPLETE_COUNT" -ne 1 ]; then
  fail_verify "$LABEL exited 0 without a single FM_TEST_COMPLETE (planned $PLANNED, ok $OK_COUNT); an early exit must fail"
fi
if [ "$NOT_OK_COUNT" -ne 0 ]; then
  fail_verify "$LABEL printed $NOT_OK_COUNT not-ok line(s) (planned $PLANNED, ok $OK_COUNT)"
fi
if [ "$OK_COUNT" -ne "$PLANNED" ]; then
  fail_verify "$LABEL planned $PLANNED ok lines, got $OK_COUNT"
fi

printf 'fm-test-tap-verify: %s: %s planned, %s ok, complete, exit 0\n' \
  "$LABEL" "$PLANNED" "$OK_COUNT"
