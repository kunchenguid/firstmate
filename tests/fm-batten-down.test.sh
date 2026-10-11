#!/usr/bin/env bash
# tests/fm-batten-down.test.sh - the batten-down check (bin/fm-batten-down.sh)
# and its gate on away entry (bin/fm-afk-launch.sh enter): a healthy machine
# passes and enters, each failing check refuses entry with its own actionable
# line and writes no record, --skip-batten-down enters anyway, and the cache
# report lists idle caches without deleting them. Machine readings come from the
# script's FM_TEST_SEAM inputs so no case depends on this host's health.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BATTEN="$ROOT/bin/fm-batten-down.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
unset PI_CODING_AGENT FM_PI_HARNESS CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI ATLASSIAN_AGENT_TYPE ROVODEV_CLI FM_BATTEN_DOWN FM_GUARD_GRACE
unset FM_BATTEN_DOWN_MIN_FREE_GB FM_BATTEN_DOWN_MAX_LOAD FM_BATTEN_DOWN_MAX_SWAP_GB FM_BATTEN_DOWN_MIN_MIDWAY_HOURS FM_BATTEN_DOWN_MIDWAY FM_BATTEN_DOWN_MIDWAY_COOKIE
export CLAUDECODE=1 FM_TEST_HARNESS=claude

TMP_ROOT=$(fm_test_tmproot batten-down)

# A home with a healthy machine reading: 500 GB free, load 1.5, 1 GB swap,
# a Midway cookie valid for 20 h (read only when midway=on), no work under
# way, and an empty temp root.
make_home() {  # <name> -> prints the home path
  local home="$TMP_ROOT/$1" now
  mkdir -p "$home/state" "$home/config" "$home/tmp" "$home/user"
  : > "$home/config/supervision-host-off"
  now=$(date +%s)
  printf '#HttpOnly_midway-auth.amazon.com\tFALSE\t/\tTRUE\t%s\tsession\tvalue\n' $((now + 72000)) > "$home/cookie"
  printf '%s\n' "$home"
}

run_batten() {  # <home> [env assignments...] -> sets OUT and RC
  local home=$1
  shift
  OUT=$(env HOME="$home/user" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_SEAM=1 FM_BATTEN_DOWN_TEST_FREE_KB=$((500 * 1048576)) FM_BATTEN_DOWN_TEST_LOAD=1.5 \
    FM_BATTEN_DOWN_TEST_SWAP_MB=1024 FM_BATTEN_DOWN_TMP_ROOT="$home/tmp" \
    FM_BATTEN_DOWN_MIDWAY_COOKIE="$home/cookie" "$@" "$BATTEN" 2>&1)
  RC=$?
}

run_enter() {  # <home> <enter-args...> -- [env assignments...] -> sets OUT and RC
  local home=$1 args=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  OUT=$(env HOME="$home/user" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_SEAM=1 FM_BATTEN_DOWN_TEST_FREE_KB=$((500 * 1048576)) FM_BATTEN_DOWN_TEST_LOAD=1.5 \
    FM_BATTEN_DOWN_TEST_SWAP_MB=1024 FM_BATTEN_DOWN_TMP_ROOT="$home/tmp" \
    FM_BATTEN_DOWN_MIDWAY_COOKIE="$home/cookie" "$@" "$LAUNCH" enter ${args[@]+"${args[@]}"} 2>&1)
  RC=$?
}

case_healthy_machine_passes_and_enters() {
  local home
  home=$(make_home pass)
  run_batten "$home"
  expect_code 0 "$RC" "healthy check"
  assert_contains "$OUT" 'batten-down check: shipshape for the night' "a healthy machine did not pass"
  assert_contains "$OUT" 'ok    disk: 500.0 GB free' "the disk line is missing"
  assert_not_contains "$OUT" 'midway:' "the Midway check ran without being turned on"
  run_batten "$home" FM_BATTEN_DOWN_MIDWAY=on
  assert_contains "$OUT" 'ok    midway: session lasts' "the opted-in midway line is missing"
  assert_contains "$OUT" 'ok    watcher: not needed' "an idle home should not need a watcher"
  run_enter "$home" --words 'redrive the reviews'
  expect_code 0 "$RC" "healthy enter"
  assert_present "$home/state/.afk-contract" "a passing check did not let away mode enter"
  assert_contains "$OUT" 'batten-down check: shipshape for the night' "enter did not show the passing report"
  pass "a healthy machine passes the batten-down check and enters away mode"
}

assert_refused() {  # <label> <expected-line> [env assignments...]
  local label=$1 line=$2 home
  shift 2
  home=$(make_home "refuse-$label")
  run_batten "$home" "$@"
  expect_code 1 "$RC" "$label check"
  assert_contains "$OUT" 'batten-down check: FAILED' "$label did not fail the check"
  assert_contains "$OUT" "$line" "$label did not name its failure"
  assert_contains "$OUT" '--skip-batten-down' "$label did not name the override"
  run_enter "$home" --words 'redrive the reviews' -- "$@"
  expect_code 4 "$RC" "$label enter"
  assert_absent "$home/state/.afk-contract" "$label still wrote an away record"
  assert_contains "$OUT" 'away mode was not entered; no record was written' "$label refusal was not explained"
  pass "away entry refuses on $label and writes no record"
}

case_each_failure_refuses_entry() {
  local home now fakebin
  assert_refused 'low disk' 'FAIL  disk: 40.0 GB free on' FM_BATTEN_DOWN_TEST_FREE_KB=$((40 * 1048576))
  assert_refused 'high load' 'FAIL  load: 1-minute load 700.2 (maximum 64)' FM_BATTEN_DOWN_TEST_LOAD=700.2 FM_BATTEN_DOWN_MAX_LOAD=64
  assert_refused 'large swap' 'FAIL  swap: 60.0 GB in use (maximum 40 GB); only a reboot reclaims swap' FM_BATTEN_DOWN_TEST_SWAP_MB=61440
  assert_refused 'missing midway' 'FAIL  midway: no session cookie at /nonexistent/cookie; run mwinit, then /afk again' \
    FM_BATTEN_DOWN_MIDWAY=on FM_BATTEN_DOWN_MIDWAY_COOKIE=/nonexistent/cookie

  home=$(make_home no-midway)
  run_batten "$home" FM_BATTEN_DOWN_MIDWAY_COOKIE=/nonexistent/cookie
  expect_code 0 "$RC" "midway off by default"
  assert_not_contains "$OUT" 'midway:' "the Midway check ran without being turned on"
  pass "the Midway check is off unless config turns it on"

  home=$(make_home short-midway)
  now=$(date +%s)
  printf '#HttpOnly_midway-auth.amazon.com\tFALSE\t/\tTRUE\t%s\tsession\tvalue\n' $((now + 7200)) > "$home/cookie"
  run_batten "$home" FM_BATTEN_DOWN_MIDWAY=on
  expect_code 1 "$RC" "short midway"
  assert_contains "$OUT" 'FAIL  midway: session lasts only 2.0 h (minimum 10 h); run mwinit' "a session ending in 2 h was not refused"
  printf '#HttpOnly_midway-auth.amazon.com\tFALSE\t/\tTRUE\t%s\tsession\tvalue\n' $((now - 60)) > "$home/cookie"
  run_batten "$home" FM_BATTEN_DOWN_MIDWAY=on
  expect_code 1 "$RC" "expired midway"
  assert_contains "$OUT" 'FAIL  midway: the session expired at' "an expired session was not refused"
  pass "a Midway session that ends inside the window or already ended fails the check"

  home=$(make_home stale-watcher)
  fm_write_meta "$home/state/busy.meta" 'window=x:1'
  : > "$home/state/.last-watcher-beat"
  fm_touch_epoch $(( $(date +%s) - 4000 )) "$home/state/.last-watcher-beat"
  run_batten "$home"
  expect_code 1 "$RC" "stale watcher"
  assert_contains "$OUT" 'FAIL  watcher: beacon' "a stale beacon with work under way was not refused"
  : > "$home/state/.last-watcher-beat"
  run_batten "$home"
  expect_code 0 "$RC" "fresh watcher"
  assert_contains "$OUT" 'ok    watcher: beacon' "a fresh beacon was not accepted"
  pass "a stale watcher beacon fails while work is under way and a fresh one passes"

  home=$(make_home small-volume)
  run_batten "$home" FM_BATTEN_DOWN_TEST_FREE_KB=$((30 * 1048576)) FM_BATTEN_DOWN_TEST_TOTAL_KB=$((256 * 1048576))
  expect_code 0 "$RC" "small volume"
  assert_contains "$OUT" 'ok    disk: 30.0 GB free' "30 GB free on a 256 GB volume was refused"
  assert_contains "$OUT" '(minimum 25.6 GB)' "the default floor is not 10% of the volume"
  run_batten "$home" FM_BATTEN_DOWN_TEST_FREE_KB=$((15 * 1048576)) FM_BATTEN_DOWN_TEST_TOTAL_KB=$((128 * 1048576))
  expect_code 1 "$RC" "tiny volume"
  assert_contains "$OUT" 'FAIL  disk: 15.0 GB free' "15 GB free passed the 20 GB absolute floor"
  assert_contains "$OUT" '(minimum 20.0 GB)' "the default floor dropped below 20 GB"
  pass "the default disk floor is 10% of the volume and never under 20 GB"

  home=$(make_home config)
  printf '# tuned\nmin_free_gb=600\n' > "$home/config/batten-down"
  run_batten "$home"
  expect_code 1 "$RC" "configured disk floor"
  assert_contains "$OUT" '(minimum 600 GB)' "config/batten-down did not set the disk floor"
  printf 'min_free_gb=10\n' > "$home/config/batten-down"
  run_batten "$home" FM_BATTEN_DOWN_TEST_FREE_KB=$((15 * 1048576)) FM_BATTEN_DOWN_TEST_TOTAL_KB=$((900 * 1048576))
  expect_code 0 "$RC" "configured floor below the relative default"
  assert_contains "$OUT" '(minimum 10 GB)' "min_free_gb did not replace the relative default"
  printf 'min_free_gb=lots\n' > "$home/config/batten-down"
  run_batten "$home"
  expect_code 1 "$RC" "invalid config"
  assert_contains "$OUT" "min_free_gb 'lots' is not a number" "an invalid config value was not refused"
  pass "config/batten-down sets the thresholds and an invalid value fails its check"
}

case_override_enters_anyway() {
  local home
  home=$(make_home override)
  run_enter "$home" --words 'redrive the reviews' --skip-batten-down -- FM_BATTEN_DOWN_TEST_FREE_KB=1024
  expect_code 0 "$RC" "override enter"
  assert_present "$home/state/.afk-contract" "--skip-batten-down did not enter away mode"
  assert_contains "$OUT" 'batten-down check skipped by --skip-batten-down' "the override was not announced"
  assert_equals 'redrive the reviews' "$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" words)" "the override changed the recorded words"
  pass "--skip-batten-down enters away mode on a failing machine and records the words unchanged"
}

case_cache_report_lists_and_deletes_nothing() {
  local home
  home=$(make_home caches)
  mkdir -p "$home/tmp/old-dd" "$home/tmp/fresh-dd" "$home/tmp/bzl-old"
  printf 'x\n' > "$home/tmp/old-dd/file"
  fm_touch_epoch $(( $(date +%s) - 20000 )) "$home/tmp/old-dd" "$home/tmp/bzl-old"
  run_batten "$home"
  expect_code 0 "$RC" "cache report"
  assert_contains "$OUT" 'reclaimable build caches (largest first; nothing was deleted):' "the cache report header is missing"
  assert_contains "$OUT" "$home/tmp/old-dd  (build dir idle 3h+" "an idle -dd dir was not listed"
  assert_contains "$OUT" "$home/tmp/bzl-old" "an idle bzl- dir was not listed"
  assert_not_contains "$OUT" "$home/tmp/fresh-dd" "a fresh build dir was listed"
  assert_present "$home/tmp/old-dd/file" "the report deleted a cache"
  pass "the cache report lists idle caches with how to reclaim them and deletes nothing"
}

case_refresh_while_away_only_warns() {
  local home
  home=$(make_home refresh)
  run_enter "$home" --words 'redrive the reviews'
  expect_code 0 "$RC" "first entry"
  run_enter "$home" --words 'redrive the reviews, then rest' -- FM_BATTEN_DOWN_TEST_FREE_KB=$((40 * 1048576))
  expect_code 0 "$RC" "words replaced while away"
  assert_contains "$OUT" 'FAIL  disk: 40.0 GB free' "the failing check was not shown on a refresh"
  assert_contains "$OUT" 'warning: already away, so the failed checks above do not block this update' "the refresh did not explain the warning"
  assert_equals 'redrive the reviews, then rest' "$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" words)" "new words while away were not recorded"
  pass "while already away, new words land and failed checks only warn"
}

case_off_switch() {
  local home
  home=$(make_home off)
  run_batten "$home" FM_BATTEN_DOWN=off FM_BATTEN_DOWN_TEST_FREE_KB=1
  expect_code 0 "$RC" "off switch"
  assert_contains "$OUT" 'batten-down check: skipped (FM_BATTEN_DOWN=off)' "FM_BATTEN_DOWN=off did not skip"
  pass "FM_BATTEN_DOWN=off skips the check for one run"
}

case_healthy_machine_passes_and_enters
case_each_failure_refuses_entry
case_override_enters_anyway
case_cache_report_lists_and_deletes_nothing
case_refresh_while_away_only_warns
case_off_switch
