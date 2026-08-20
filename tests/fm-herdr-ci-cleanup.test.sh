#!/usr/bin/env bash
# Characterization tests for bounded, ownership-checked Herdr CI cleanup.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CLEANUP="$ROOT/bin/fm-herdr-ci-cleanup.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-ci-cleanup)
trap fm_test_cleanup EXIT

make_fake_herdr() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
[ "${1:-}" = session ] || exit 2
case "${2:-}" in
  stop|delete) exit 0 ;;
  list) ;;
  *) exit 2 ;;
esac
case "$FM_HERDR_PHASE" in
  snapshot)
    printf '%s\n' '{"sessions":[{"name":"fm-lab-zeta","default":false},{"name":"fm-lab-alpha","default":false},{"name":"fm-lab-alpha","default":false}]}'
    ;;
  teardown)
    case "$(cat "$FM_HERDR_LIST_COUNT")" in
      0)
        printf '1\n' > "$FM_HERDR_LIST_COUNT"
        printf '%s\n' '{"sessions":[{"name":"default","default":true},{"name":"fm-lab-existing","default":false},{"name":"fm-lab-owned","default":false},{"name":"fm-lab-default","default":true},{"name":"not-a-lab","default":false}]}'
        ;;
      1|2)
        count=$(cat "$FM_HERDR_LIST_COUNT")
        printf '%s\n' "$((count + 1))" > "$FM_HERDR_LIST_COUNT"
        printf '%s\n' '{"sessions":[{"name":"fm-lab-owned","default":false}]}'
        ;;
      *)
        printf '%s\n' '{"sessions":[]}'
        ;;
    esac
    ;;
  *) exit 3 ;;
esac
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/herdr" "$fakebin/sleep"
}

test_snapshot_is_unique_and_sorted() {
  local dir fakebin snapshot output
  dir="$TMP_ROOT/snapshot"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  make_fake_herdr "$fakebin"
  snapshot="$dir/snapshot.json"
  output=$(FM_HERDR_PHASE=snapshot FM_HERDR_LOG="$dir/herdr.log" \
    PATH="$fakebin:$PATH" "$CLEANUP" snapshot "$snapshot" 2>&1) \
    || fail "snapshot command failed: $output"
  [ "$(cat "$snapshot")" = '["fm-lab-alpha","fm-lab-zeta"]' ] \
    || fail "snapshot did not write unique sorted names"
  assert_contains "$output" "wrote session snapshot to $snapshot (2 names)" \
    "snapshot did not report its bounded result"
  pass "fm-herdr-ci-cleanup snapshots unique sorted session names"
}

test_teardown_only_deletes_new_nondefault_lab_sessions() {
  local dir fakebin snapshot output
  dir="$TMP_ROOT/teardown"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  make_fake_herdr "$fakebin"
  snapshot="$dir/snapshot.json"
  printf '%s\n' '["fm-lab-existing"]' > "$snapshot"
  printf '0\n' > "$dir/list-count"
  output=$(FM_HERDR_PHASE=teardown FM_HERDR_LOG="$dir/herdr.log" \
    FM_HERDR_LIST_COUNT="$dir/list-count" PATH="$fakebin:$PATH" \
    "$CLEANUP" teardown "$snapshot" 2>&1) \
    || fail "teardown command failed: $output"
  assert_contains "$output" "deleted job-owned lab session fm-lab-owned" \
    "teardown did not delete the owned non-default lab session"
  assert_grep 'session stop fm-lab-owned --json' "$dir/herdr.log" \
    "teardown did not stop only the owned session"
  assert_grep 'session delete fm-lab-owned --json' "$dir/herdr.log" \
    "teardown did not delete only the owned session"
  assert_no_grep 'session stop fm-lab-existing' "$dir/herdr.log" \
    "teardown stopped an unowned session"
  assert_no_grep 'session delete fm-lab-existing' "$dir/herdr.log" \
    "teardown deleted an unowned session"
  assert_no_grep 'session stop fm-lab-default' "$dir/herdr.log" \
    "teardown stopped a default session"
  assert_no_grep 'session delete fm-lab-default' "$dir/herdr.log" \
    "teardown deleted a default session"
  assert_no_grep 'session stop not-a-lab' "$dir/herdr.log" \
    "teardown stopped a non-lab session"
  assert_no_grep 'session delete not-a-lab' "$dir/herdr.log" \
    "teardown deleted a non-lab session"
  pass "fm-herdr-ci-cleanup tears down only new non-default lab sessions"
}

test_snapshot_is_unique_and_sorted
test_teardown_only_deletes_new_nondefault_lab_sessions
