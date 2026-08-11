#!/usr/bin/env bash
# Regression tests for the private routines scheduler.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCAN="$ROOT/bin/fm-routine-scan.sh"
SETUP="$ROOT/bin/fm-routine-setup.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-routine-scan)
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}
write_registry() {
  local home=$1
  shift
  printf '%s\n' \
    '# Recurring routine registry.' \
    '# Format: - <id> | <cadence> | <owner> | <action> | <delivery>' \
    "$@" > "$home/data/routines.md"
}
run_scan() {
  local home=$1 date_value=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_ROUTINE_DATE="$date_value" "$SCAN"
}
file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}
file_links() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1"
  else
    stat -c %h "$1"
  fi
}
test_bootstrap_seeds_and_arms_private_routine() {
  local home registry check out active_count example_count
  home=$(make_home provision)
  registry="$home/data/routines.md"
  check="$home/state/routine-scan.check.sh"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip FM_BACKEND=tmux \
    "$BOOTSTRAP" > "$home/bootstrap.out" 2> "$home/bootstrap.err" \
    || fail "bootstrap could not provision the recurring routine"

  [ -f "$registry" ] && [ ! -L "$registry" ] || fail "bootstrap did not seed the private routine registry"
  [ "$(file_mode "$registry")" = 600 ] || fail "the seeded routine registry is not mode 0600"
  [ -f "$check" ] && [ ! -L "$check" ] || fail "bootstrap did not arm the routine check"
  [ "$(file_mode "$check")" = 700 ] || fail "the routine check is not mode 0700"
  [ "$(file_links "$check")" = 1 ] || fail "the routine check is not a single-link file"

  active_count=$(awk '$0 ~ /^- / { n++ } END { print n+0 }' "$registry")
  example_count=$(awk '$0 ~ /^# - / { n++ } END { print n+0 }' "$registry")
  [ "$active_count" -eq 0 ] || fail "the seeded registry contains active routines"
  [ "$example_count" -eq 2 ] || fail "the seeded registry does not contain two generic examples"

  bash -c '. "$1"; . "$2"; fm_custom_check_registered "$3" routine-scan' \
    _ "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-check-lib.sh" "$home/state" \
    || fail "the routine check was not registered with the custom-check trust rail"
  bash -c '. "$1"; fm_supervision_needed "$2" 300' \
    _ "$ROOT/bin/fm-supervision-lib.sh" "$home/state" \
    || fail "an routine-only home did not retain watcher supervision"

  out=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ -z "$out" ] || fail "the provisioned routine check ran commented examples"
  pass "bootstrap seeds and arms the private recurring routine"
}
test_setup_persists_canonical_path_overrides() {
  local base home data state run_dir check out expected
  base="$TMP_ROOT/path-overrides"
  home="$base/home"
  data="$base/private-data"
  state="$base/private-state"
  run_dir="$base/run"
  mkdir -p "$home" "$run_dir"

  (cd "$base" && FM_HOME=home FM_DATA_OVERRIDE=private-data \
    FM_STATE_OVERRIDE=private-state FM_ROOT_OVERRIDE="$ROOT" "$SETUP") \
    || fail "routine setup rejected relative path overrides"
  check="$state/routine-scan.check.sh"
  [ -f "$data/routines.md" ] || fail "routine setup ignored the data override"
  [ -f "$check" ] || fail "routine setup ignored the state override"

  printf '%s\n' \
    '- example-daily-check | daily | captain | check priorities | do' \
    > "$data/routines.md"
  out=$(cd "$run_dir" && FM_ROUTINE_DATE=2026-08-10 "$check")
  expected='routine-due: example-daily-check | captain | check priorities'
  [ "$out" = "$expected" ] || fail "routine check did not retain its provisioned registry path"
  [ -f "$state/.routine-fired" ] || fail "routine check did not retain its provisioned state path"
  [ ! -e "$home/state/.routine-fired" ] || fail "routine check wrote fire state under the relative runtime cwd"
  pass "routine check retains canonical data and state overrides"
}
test_routine_check_enforces_timeout() {
  local home fake_root check out rc marker
  home=$(make_home timeout)
  fake_root="$TMP_ROOT/timeout-root"
  marker="$home/scanner-started"
  mkdir -p "$fake_root/bin"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$fake_root/bin/fm-timeout-lib.sh"
  cat > "$fake_root/bin/fm-routine-scan.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_TEST_ROUTINE_STARTED:?}"
sleep 5
SH
  chmod 0755 "$fake_root/bin/fm-routine-scan.sh"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" "$SETUP" \
    || fail "routine setup could not create the timeout fixture"
  check="$home/state/routine-scan.check.sh"
  out=$(FM_TEST_ROUTINE_STARTED="$marker" FM_CHECK_TIMEOUT=1 FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    "$check" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 124 ] || fail "routine check did not report its FM_CHECK_TIMEOUT deadline"
  [ "$out" = 'routine-check-error: scanner exited 124' ] \
    || fail "routine check timeout did not emit an actionable watcher wake"
  [ -f "$marker" ] || fail "timeout fixture never started the routine scanner"

  out=$(FM_CHECK_TIMEOUT=2 FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_TEST_ROUTINE_STARTED="$marker" \
    bash -c '. "$1"; fm_run_timed 1 "$2"' _ "$ROOT/bin/fm-timeout-lib.sh" "$check" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 124 ] || fail "the watcher-style outer timeout did not stop the routine check"
  [ "$out" = 'routine-check-error: scanner interrupted' ] \
    || fail "an outer watcher timeout did not produce an actionable check line"
  pass "routine check bounds and reports scanner timeouts"
}
test_daily_fires_once_per_local_day() {
  local home out
  home=$(make_home daily)
  write_registry "$home" \
    '- daily-item | daily | captain | check priorities | do'
  out=$(run_scan "$home" 2026-08-10)
  [ "$out" = 'routine-due: daily-item | captain | check priorities' ] \
    || fail "daily item did not fire on its first day"
  out=$(run_scan "$home" 2026-08-10)
  [ -z "$out" ] || fail "daily item fired twice on the same day"
  [ "$(cat "$home/state/.routine-fired")" = 'daily-item|daily|2026-08-10' ] \
    || fail "daily fire state did not record the current period"
  out=$(run_scan "$home" 2026-08-11)
  [ "$out" = 'routine-due: daily-item | captain | check priorities' ] \
    || fail "daily item did not fire on the next day"
  pass "daily items fire once per local day"
}
test_weekly_fires_only_on_matching_weekday() {
  local home out
  home=$(make_home weekly)
  write_registry "$home" \
    '- monday-item | weekly:mon | captain | review the week | do'
  out=$(run_scan "$home" 2026-08-10)
  [ "$out" = 'routine-due: monday-item | captain | review the week' ] \
    || fail "weekly Monday item did not fire on Monday"
  out=$(run_scan "$home" 2026-08-10)
  [ -z "$out" ] || fail "weekly Monday item fired twice on Monday"
  out=$(run_scan "$home" 2026-08-11)
  [ -z "$out" ] || fail "weekly Monday item fired on Tuesday"
  out=$(run_scan "$home" 2026-08-17)
  [ "$out" = 'routine-due: monday-item | captain | review the week' ] \
    || fail "weekly Monday item did not fire on the next Monday"
  pass "weekly items fire only on their matching weekday"
}
test_weekday_is_derived_from_captured_local_date() {
  local home fakebin out
  home=$(make_home midnight-boundary)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  write_registry "$home" \
    '- monday-item | weekly:mon | captain | review the week | do'
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '+%F') printf '%s\n' '2026-08-09' ;;
  '+%u') printf '%s\n' '1' ;;
  '-d 2026-08-09 +%u'|'-j -f %Y-%m-%d 2026-08-09 +%u') printf '%s\n' '7' ;;
  *) exit 2 ;;
esac
SH
  chmod 0755 "$fakebin/date"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCAN")
  [ -z "$out" ] || fail "a Monday item fired against the captured Sunday date"
  [ ! -e "$home/state/.routine-fired" ] \
    || fail "a clock change after date capture created Sunday fire state for a Monday item"
  pass "weekly cadence uses one captured local date across midnight"
}
test_nothing_due_is_silent_and_does_not_create_fire_state() {
  local home out
  home=$(make_home silent)
  write_registry "$home" \
    '- monday-item | weekly:mon | captain | review the week | notify-on-problem'
  out=$(run_scan "$home" 2026-08-11)
  [ -z "$out" ] || fail "non-matching weekly item printed output"
  [ ! -e "$home/state/.routine-fired" ] \
    || fail "a silent scan changed fire state"
  pass "nothing due prints nothing and leaves fire state unchanged"
}
test_fire_state_prevents_repeats_after_scan_restart() {
  local home first second
  home=$(make_home restart)
  write_registry "$home" \
    '- daily-item | daily | captain | check priorities | notify'
  first=$(run_scan "$home" 2026-08-10)
  second=$(run_scan "$home" 2026-08-10)
  [ -n "$first" ] && [ -z "$second" ] \
    || fail "durable fire state did not prevent a repeat after restart"
  pass "durable fire state prevents repeats"
}
test_duplicate_id_cannot_alternate_fired_cadences() {
  local home first second
  home=$(make_home duplicate-id)
  write_registry "$home" \
    '- shared-item | daily | captain | check priorities | notify' \
    '- shared-item | weekly:mon | captain | review the week | do'
  first=$(run_scan "$home" 2026-08-10 2>/dev/null)
  second=$(run_scan "$home" 2026-08-10 2>/dev/null)
  [ "$first" = 'routine-due: shared-item | captain | check priorities' ] \
    || fail "the first duplicate-id record did not own the routine id"
  [ -z "$second" ] || fail "a duplicate id alternated cadences after its first firing"
  [ "$(cat "$home/state/.routine-fired")" = 'shared-item|daily|2026-08-10' ] \
    || fail "a duplicate id replaced the first record's durable fire state"
  pass "duplicate ids cannot alternate fired cadences"
}
test_bootstrap_seeds_and_arms_private_routine
test_setup_persists_canonical_path_overrides
test_routine_check_enforces_timeout
test_daily_fires_once_per_local_day
test_weekly_fires_only_on_matching_weekday
test_weekday_is_derived_from_captured_local_date
test_nothing_due_is_silent_and_does_not_create_fire_state
test_fire_state_prevents_repeats_after_scan_restart
test_duplicate_id_cannot_alternate_fired_cadences
