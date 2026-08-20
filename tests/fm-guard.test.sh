#!/usr/bin/env bash
# Characterization coverage for fm-guard's idle-home cleanup path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard)

test_idle_guard_clears_stale_banner_without_warning() {
  local home root output status marker
  home="$TMP_ROOT/home"
  root="$TMP_ROOT/root"
  marker="$home/state/.guard-watcher-stale-banner"
  mkdir -p "$home/state" "$home/config" "$root"
  printf '%s\n' watcher-down > "$marker"

  set +e
  # shellcheck disable=SC2153
  output=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-guard.sh" 2>&1)
  status=$?
  set -e

  expect_code 0 "$status" "idle guard must succeed"
  [ -z "$output" ] || fail "idle guard must stay silent, got: $output"
  assert_absent "$marker" "idle guard must clear a stale watcher-banner marker"
  pass "fm-guard clears stale-banner state and stays silent when supervision is unnecessary"
}

test_idle_guard_clears_stale_banner_without_warning
echo "# fm-guard.test.sh: all assertions passed"
