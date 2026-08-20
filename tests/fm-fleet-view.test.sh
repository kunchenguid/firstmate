#!/usr/bin/env bash
# Characterization tests for the human fleet view renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-view)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_empty_view_contract() {
  local home view
  home="$TMP_ROOT/home"
  mkdir -p "$home"/{config,data,projects,state}

  view=$(FM_HOME="$home" "$VIEW") || fail "empty fleet view should succeed"
  assert_contains "$view" "# Fleet View" "fleet view should print its title"
  assert_contains "$view" "Schema: fm-fleet-snapshot.v1" "fleet view should print the snapshot schema"
  assert_contains "$view" "No live task metadata found." "empty fleet view should disclose no live tasks"
  assert_contains "$view" "No queued backlog records found." "empty fleet view should disclose no queued records"
  pass "empty fleet view preserves absence markers"
}

test_invalid_argument_fails_closed() {
  local home err rc
  home="$TMP_ROOT/invalid"
  mkdir -p "$home"
  err="$TMP_ROOT/invalid.err"
  set +e
  FM_HOME="$home" "$VIEW" --not-a-mode 2>"$err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "invalid fleet-view argument should exit 2, got $rc"
  assert_contains "$(cat "$err")" "usage: fm-fleet-view.sh [--json]" \
    "invalid fleet-view argument should print usage"
  pass "invalid fleet-view argument is rejected with usage"
}

test_empty_view_contract
test_invalid_argument_fails_closed
