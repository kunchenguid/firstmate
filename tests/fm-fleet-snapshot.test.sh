#!/usr/bin/env bash
# Characterization tests for the read-only structured fleet snapshot.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-contract)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_empty_local_snapshot_contract() {
  local home out
  home="$TMP_ROOT/home"
  mkdir -p "$home"/{config,data,projects,state}

  out=$(FM_HOME="$home" "$SNAPSHOT" --local-json) \
    || fail "empty local snapshot should succeed"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks | length) == 0
      and .secondmate_current.collection == "skipped-local-only"
  ' >/dev/null || fail "empty local snapshot contract changed: $out"
  pass "empty local snapshot preserves the stable schema and absence markers"
}

test_invalid_mode_fails_closed() {
  local home err rc
  home="$TMP_ROOT/invalid"
  mkdir -p "$home"
  err="$TMP_ROOT/invalid.err"
  set +e
  FM_HOME="$home" "$SNAPSHOT" --not-a-mode 2>"$err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "invalid snapshot mode should exit 2, got $rc"
  assert_contains "$(cat "$err")" "usage: fm-fleet-snapshot.sh --json" \
    "invalid snapshot mode should print usage"
  pass "invalid snapshot mode is rejected with usage"
}

test_empty_local_snapshot_contract
test_invalid_mode_fails_closed
