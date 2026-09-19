#!/usr/bin/env bash
# fm-ci-macos-stock-bash.sh - stock macOS Bash snapshot compatibility lane.
#
# Single owner of the macos-stock-bash CI job body. Asserts stock Bash 3.2.57,
# parse-sweeps the lint file set with /bin/bash -n, installs this lane's pinned
# tasks-axi, and runs the fleet-snapshot, Bearings, public-followup, and
# watcher churn-deferral bash-3.2 regressions. TAP cardinalities stay out of
# this script and out of .github/workflows/ci.yml; a failing suite already
# exits non-zero on `not ok`.
#
# Usage:
#   fm-ci-macos-stock-bash.sh
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

die() {
  printf 'fm-ci-macos-stock-bash.sh: %s\n' "$*" >&2
  printf '::error::%s\n' "$*" >&2
  exit 1
}

case "${BASH_VERSION:-}" in
  3.2.57*) ;;
  *) die "expected stock macOS Bash 3.2.57, got ${BASH_VERSION:-<empty>}" ;;
esac
/bin/bash --version | head -1
command -v jq >/dev/null || die "jq is required"

shell_inventory="$RUNNER_TEMP/fm-shell-inventory"
bin/fm-lint.sh --list-files > "$shell_inventory"
parse_fail=0
while IFS= read -r f; do
  /bin/bash -n "$f" || {
    printf '::error::stock macOS Bash 3.2 failed to parse %s\n' "$f" >&2
    parse_fail=1
  }
done < "$shell_inventory"
[ "$parse_fail" -eq 0 ] || die "stock macOS Bash 3.2 parse sweep failed"

command -v npm >/dev/null || die "npm is required to install tasks-axi"
npm install -g tasks-axi@0.2.5 >/dev/null
PATH="$(npm prefix -g)/bin:$PATH"
export PATH
command -v tasks-axi >/dev/null || die "tasks-axi is required for the stock Bash regressions"

/bin/bash tests/fm-fleet-snapshot-view.test.sh
/bin/bash tests/fm-bearings-snapshot.test.sh
# The full public-followup suite is not a stock-bash snapshot; run only
# the empty-lock register regression under real /bin/bash 3.2.
FM_TEST_ONLY=test_first_register_succeeds_with_empty_lock_list_under_bash32 \
  /bin/bash tests/fm-public-followup.test.sh
# Same shape for the watcher's churn-deferral regression: an already-
# marked churn window expands an empty array that only stock Bash
# treats as an unbound variable under set -u.
FM_TEST_ONLY=test_turn_ended_churn_existing_marker_absorbed \
  /bin/bash tests/fm-watch-triage.test.sh
