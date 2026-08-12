#!/usr/bin/env bash
# Regression tests for the private routines scheduler.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCAN="$ROOT/bin/fm-routine-scan.sh"
SETUP="$ROOT/bin/fm-routine-setup.sh"
WATCH="$ROOT/bin/fm-watch.sh"
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
    '# Format: - <id> | <cadence> | <owner> | <action>' \
    "$@" > "$home/data/routines.md"
}
run_scan() {
  local home=$1 date_value=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_ROUTINE_DATE="$date_value" "$SCAN"
}
run_bounded_watcher() {
  local home=$1 out=$2 fakebin=$3
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=1 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_ROUTINE_WATCH_TEST_DELAY_BEFORE_ACK="${FM_ROUTINE_WATCH_TEST_DELAY_BEFORE_ACK:-0}" \
      PATH="$fakebin:$PATH" "$WATCH" > "$out"
}
ack_watcher_cycle() {
  local state=$1 err sequence generation
  err="$state/.test-wake-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation"
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
  local base home data state run_dir check out expected generation
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
    '- example-daily-check | daily | captain | check priorities' \
    > "$data/routines.md"
  out=$(cd "$run_dir" && FM_ROUTINE_DATE=2026-08-10 "$check")
  expected='routine-due: example-daily-check | captain | check priorities'
  [ "$out" = "$expected" ] || fail "routine check did not retain its provisioned registry path"
  [ -f "$state/.routine-pending" ] || fail "routine check did not retain its provisioned pending state path"
  generation=$(cat "$state/.routine-generation")
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/routine-scan.check.sh:routine-generation:$generation" "$out" \
    || fail "routine check could not publish its pending wake"
  "$check" --ack --generation "$generation" >/dev/null \
    || fail "routine check could not acknowledge its pending state"
  [ -f "$state/.routine-fired" ] || fail "routine check did not retain its provisioned fire state path"
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
test_watcher_surfaces_missing_registry_as_a_check_wake() {
  local home fakebin rc
  home=$(make_home missing-registry)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && exit 0
exit 1
SH
  chmod 0755 "$fakebin/tmux"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the missing-registry fixture"
  rm -f -- "$home/data/routines.md"

  run_bounded_watcher "$home" "$home/watch.out" "$fakebin"
  rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher treated a missing registry as a fatal receipt failure"
  grep -q 'routine-check-error: scanner exited 1' "$home/watch.out" \
    || fail "the missing registry did not surface as an actionable check wake"
  pass "watcher surfaces a missing routine registry as a check wake"
}
test_watcher_surfaces_missing_registry_with_empty_pending_state() {
  local home fakebin rc
  home=$(make_home missing-registry-empty-pending)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && exit 0
exit 1
SH
  chmod 0755 "$fakebin/tmux"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the empty-pending fixture"
  rm -f -- "$home/data/routines.md"
  : > "$home/state/.routine-pending"

  run_bounded_watcher "$home" "$home/watch.out" "$fakebin"
  rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher accepted empty pending state as a routine scan"
  grep -q 'routine-check-error: scanner exited 1' "$home/watch.out" \
    || fail "empty pending state did not surface a missing-registry check wake"
  pass "watcher surfaces a missing registry with empty pending state"
}
test_daily_fires_once_per_local_day() {
  local home out
  home=$(make_home daily)
  write_registry "$home" \
    '- daily-item | daily | captain | check priorities'
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
    '- monday-item | weekly:mon | captain | review the week'
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
    '- monday-item | weekly:mon | captain | review the week'
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
    '- monday-item | weekly:mon | captain | review the week'
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
    '- daily-item | daily | captain | check priorities'
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
    '- shared-item | daily | captain | check priorities' \
    '- shared-item | weekly:mon | captain | review the week'
  first=$(run_scan "$home" 2026-08-10 2>/dev/null)
  second=$(run_scan "$home" 2026-08-10 2>/dev/null)
  [ "$first" = 'routine-due: shared-item | captain | check priorities' ] \
    || fail "the first duplicate-id record did not own the routine id"
  [ -z "$second" ] || fail "a duplicate id alternated cadences after its first firing"
  [ "$(cat "$home/state/.routine-fired")" = 'shared-item|daily|2026-08-10' ] \
    || fail "a duplicate id replaced the first record's durable fire state"
  pass "duplicate ids cannot alternate fired cadences"
}
test_deferred_check_acknowledges_after_wake() {
  local home check first second ack third generation out rc
  home=$(make_home deferred)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the deferred check"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- deferred-item | daily | captain | check priorities'
  first=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ "$first" = 'routine-due: deferred-item | captain | check priorities' ] \
    || fail "the deferred check did not emit its due wake"
  [ ! -e "$home/state/.routine-fired" ] \
    || fail "the deferred check committed fire state before acknowledgement"
  [ -f "$home/state/.routine-pending" ] \
    || fail "the deferred check did not retain pending fire state"
  second=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ "$second" = "$first" ] \
    || fail "pending due output was not repeatable before acknowledgement"
  generation=$(awk -F '|' 'NR == 1 { print $6 }' "$home/state/.routine-pending")
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$first" \
    || fail "the routine due wake could not enter the existing wake rail"
  [ -s "$home/state/.wake-queue" ] || fail "the routine due wake was not durable"
  if out=$(FM_ROUTINE_DATE=2026-08-10 "$check" --ack 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "bare routine acknowledgement bypassed generation binding"
  case "$out" in
    *'routine acknowledgement requires a generation'*) ;;
    *) fail "bare routine acknowledgement lacked an actionable diagnostic: $out" ;
  esac
  ack=$(FM_ROUTINE_DATE=2026-08-10 "$check" --ack --generation "$generation")
  [ -z "$ack" ] || fail "routine acknowledgement produced check output"
  [ "$(cat "$home/state/.routine-fired")" = 'deferred-item|daily|2026-08-10' ] \
    || fail "routine acknowledgement did not commit fire state"
  [ ! -e "$home/state/.routine-pending" ] \
    || fail "routine acknowledgement left pending fire state"
  third=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ -z "$third" ] || fail "acknowledged routine fired again"
  pass "routine fire state commits after wake acknowledgement"
}
test_ack_requires_durable_generation_wake() {
  local home check first generation out rc
  home=$(make_home ack-publication)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the acknowledgement fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- publication-bound-item | daily | captain | require a published wake'
  first=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  generation=$(awk -F '|' 'NR == 1 { print $6 }' "$home/state/.routine-pending")
  if out=$(FM_ROUTINE_DATE=2026-08-10 "$check" --ack --generation "$generation" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "acknowledgement bypassed durable wake publication"
  case "$out" in
    *'routine acknowledgement has no durable wake:'*) ;;
    *) fail "unpublished acknowledgement lacked an actionable diagnostic: $out" ;;
  esac
  [ ! -e "$home/state/.routine-fired" ] || fail "unpublished acknowledgement committed fire state"
  if out=$(FM_ROUTINE_WAKE_QUEUE_LOCK_HELD=1 FM_ROUTINE_DATE=2026-08-10 \
    "$check" --ack --generation "$generation" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "caller-controlled queue lock flag bypassed publication proof"
  case "$out" in
    *'lacks verified wake queue lock ownership'*) ;;
    *) fail "unverified queue lock ownership lacked an actionable diagnostic: $out" ;;
  esac
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$first" \
    || fail "the publication fixture could not append its durable wake"
  "$check" --ack --generation "$generation" \
    || fail "acknowledgement rejected its durable generation wake"
  [ "$(cat "$home/state/.routine-fired")" = 'publication-bound-item|daily|2026-08-10' ] \
    || fail "the published generation did not commit fire state"
  pass "routine acknowledgement requires durable wake publication"
}
test_ack_rejects_partial_generation_wake() {
  local home check first generation partial out rc expected_fired
  home=$(make_home partial-publication)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the partial-publication fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- item-a | daily | captain | first published item' \
    '- item-b | daily | captain | second published item'
  first=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  generation=$(awk -F '|' 'NR == 1 { print $6 }' "$home/state/.routine-pending")
  partial='routine-due: item-a | captain | first published item'
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$partial" \
    || fail "the partial wake could not be published"
  if out=$(FM_ROUTINE_DATE=2026-08-10 "$check" --ack --generation "$generation" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "partial generation wake acknowledged all pending routines"
  case "$out" in
    *'routine acknowledgement wake omitted pending routine: item-b'*) ;;
    *) fail "partial wake lacked an actionable diagnostic: $out" ;;
  esac
  [ ! -e "$home/state/.routine-fired" ] || fail "partial wake committed fire state"
  [ -f "$home/state/.routine-pending" ] || fail "partial wake discarded pending state"
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$first" \
    || fail "the complete wake could not be published"
  "$check" --ack --generation "$generation" \
    || fail "complete generation wake did not acknowledge pending routines"
  expected_fired=$(printf '%s\n' 'item-a|daily|2026-08-10' 'item-b|daily|2026-08-10')
  [ "$(cat "$home/state/.routine-fired")" = "$expected_fired" ] \
    || fail "complete wake did not commit the full fire state"
  pass "routine acknowledgement requires complete generation publication"
}
test_unpublished_pending_binds_to_first_successful_wake() {
  local home check first second generation retry
  home=$(make_home unpublished-pending)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the unpublished-pending fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- retry-item | daily | captain | retry publication'
  first=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ -f "$home/state/.routine-pending" ] || fail "the first scan did not retain pending state"
  second=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ "$second" = "$first" ] || fail "the pending item did not retry before publication"
  generation=$(cat "$home/state/.routine-generation")
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$second" \
    || fail "the first successful retry wake could not be published"
  "$check" --ack --generation "$generation" \
    || fail "the unpublished pending item did not bind to the successful wake"
  [ ! -e "$home/state/.routine-pending" ] || fail "the published retry left pending state"
  [ "$(cat "$home/state/.routine-fired")" = 'retry-item|daily|2026-08-10' ] \
    || fail "the published retry did not commit fire state"
  retry=$(FM_ROUTINE_DATE=2026-08-10 "$check" --ack --generation "$generation")
  [ -z "$retry" ] || fail "retry acknowledgement produced output"
  [ "$(cat "$home/state/.routine-fired")" = 'retry-item|daily|2026-08-10' ] \
    || fail "retry acknowledgement changed fire state"
  pass "unpublished pending routines bind on first successful wake"
}
test_fired_pending_replay_is_suppressed() {
  local home check first generation second
  home=$(make_home fired-pending-replay)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the replay fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- replayed-item | daily | captain | do not replay'
  first=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  generation=$(awk -F '|' 'NR == 1 { print $6 }' "$home/state/.routine-pending")
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$first" \
    || fail "the replay fixture could not publish its wake"
  printf '%s\n' 'replayed-item|daily|2026-08-10' > "$home/state/.routine-fired"
  second=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ -z "$second" ] || fail "a fired pending routine replayed after acknowledgement publication"
  [ ! -e "$home/state/.routine-pending" ] || fail "replayed pending state was not cleared"
  pass "fired pending routines are suppressed after a crash"
}
test_pending_generation_stays_bound_after_rescan() {
  local home check first second third generation
  home=$(make_home pending-generation)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the pending-generation fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- stable-item | daily | captain | preserve its wake'
  first=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  generation=$(awk -F '|' 'NR == 1 { print $6 }' "$home/state/.routine-pending")
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$first" \
    || fail "the first routine wake could not enter the wake rail"
  second=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ "$second" = "$first" ] || fail "the pending routine changed during a rescan"
  [ "$(awk -F '|' 'NR == 1 { print $6 }' "$home/state/.routine-pending")" = "$generation" ] \
    || fail "the rescan relabeled the pending routine generation"
  "$check" --ack --generation "$generation" \
    || fail "the original routine wake could not acknowledge its pending record"
  third=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ -z "$third" ] || fail "a handled routine wake fired again after a rescan"
  pass "pending routine records retain their published generation"
}
test_deferred_publication_does_not_refire_after_restart() {
  local home check first second generation
  home=$(make_home publication-restart)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the publication fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- publication-item | daily | captain | survive restart routine-check-error: literal'
  first=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ "$first" = 'routine-due: publication-item | captain | survive restart routine-check-error: literal' ] \
    || fail "the publication fixture did not emit its due wake"
  generation=$(cat "$home/state/.routine-generation")
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$first" \
    || fail "the publication fixture could not append its durable wake"
  [ ! -e "$home/state/.routine-fired" ] \
    || fail "the publication fixture promoted fire state before its wake was handled"
  ack_watcher_cycle "$home/state" \
    || fail "the durable publication could not be handled after restart"
  second=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  [ -z "$second" ] || fail "a handled routine wake fired again after restart"
  [ "$(cat "$home/state/.routine-fired")" = 'publication-item|daily|2026-08-10' ] \
    || fail "the handled wake did not promote routine fire state"
  pass "a handled routine wake does not fire again after restart"
}
test_ack_fails_when_routine_state_lock_is_held() {
  local home check lock_ready lock_pid rc out generation
  home=$(make_home ack-lock)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the lock fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- locked-item | daily | captain | check priorities'
  FM_ROUTINE_DATE=2026-08-10 "$check" >/dev/null \
    || fail "the lock fixture did not create pending state"
  lock_ready="$home/lock-ready"
  FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; sleep 5' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/.routine-fired.lock" "$lock_ready" &
  lock_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$lock_ready" ] && break
    sleep 0.01
  done
  [ -f "$lock_ready" ] || fail "the lock fixture did not acquire routine state lock"
  generation=$(awk -F '|' 'NR == 1 { print $6 }' "$home/state/.routine-pending")
  if out=$(FM_ROUTINE_DATE=2026-08-10 "$check" --ack --generation "$generation" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "routine acknowledgement succeeded without its state lock"
  case "$out" in
    *'could not acquire routine state lock'*) ;;
    *) fail "routine lock contention did not produce an actionable diagnostic: $out" ;;
  esac
  pass "routine acknowledgement fails closed when state is locked"
}
test_watcher_acknowledges_only_after_complete_scan() {
  local home fake_root fakebin rc fired_expected
  home=$(make_home watch-ack)
  fake_root="$TMP_ROOT/watch-ack-root"
  fakebin="$TMP_ROOT/watch-ack-fakebin"
  mkdir -p "$fake_root/bin" "$fakebin"
  cp "$ROOT/bin/fm-pr-lib.sh" "$fake_root/bin/fm-pr-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$fake_root/bin/fm-timeout-lib.sh"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && exit 0
exit 1
SH
  chmod 0755 "$fakebin/tmux"
  cat > "$fake_root/bin/fm-routine-scan.sh" <<'SH'
#!/usr/bin/env bash
set -u
umask 077
  printf '%s\n' \
  'item-a|daily|2026-08-10|captain|check priorities|1' \
  'item-b|daily|2026-08-10|captain|review the week|1' > "$FM_STATE_OVERRIDE/.routine-pending"
chmod 0600 "$FM_STATE_OVERRIDE/.routine-pending"
printf '%s\n' 'routine-due: item-a | captain | check priorities'
sleep 5
SH
  chmod 0755 "$fake_root/bin/fm-routine-scan.sh"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" "$SETUP" \
    || fail "routine setup could not arm the watcher acknowledgement fixture"
  run_bounded_watcher "$home" "$home/watch1.out" "$fakebin"
  rc=$?
  [ "$rc" -eq 0 ] || fail "an interrupted routine check did not surface a wake"
  grep -q 'routine-due: item-a' "$home/watch1.out" \
    || fail "the emitted routine line was not surfaced"
  grep -q 'routine-check-error:' "$home/watch1.out" \
    || fail "the interrupted routine check did not report its failure"
  [ -f "$home/state/.routine-pending" ] \
    || fail "an interrupted scan acknowledged its unemitted routines"
  grep -q '^item-b|daily|2026-08-10|' "$home/state/.routine-pending" \
    || fail "the unemitted routine was dropped from pending state"
  [ ! -e "$home/state/.routine-fired" ] \
    || fail "an interrupted scan committed fire state"
  ack_watcher_cycle "$home/state" \
    || fail "the interrupted routine wake could not be acknowledged"

  cp "$ROOT/bin/fm-routine-scan.sh" "$fake_root/bin/fm-routine-scan.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$fake_root/bin/fm-wake-lib.sh"
  write_registry "$home" \
    '- item-a | daily | captain | check priorities' \
    '- item-b | daily | captain | review the week'
  run_bounded_watcher "$home" "$home/watch2.out" "$fakebin"
  rc=$?
  [ "$rc" -eq 0 ] || fail "the recovered routine scan did not surface its wake"
  grep -q 'routine-due: item-a' "$home/watch2.out" \
    || fail "the retained routine did not re-surface after recovery"
  grep -q 'routine-due: item-b' "$home/watch2.out" \
    || fail "the unemitted routine did not surface after recovery"
  [ ! -e "$home/state/.routine-pending" ] \
    || fail "a complete scan left pending fire state"
  fired_expected=$(printf '%s\n' 'item-a|daily|2026-08-10' 'item-b|daily|2026-08-10')
  [ "$(cat "$home/state/.routine-fired")" = "$fired_expected" ] \
    || fail "acknowledged fire state does not match the surfaced routines"
  pass "watcher acknowledges routines only after a complete scan"
}
test_recovery_does_not_acknowledge_stale_routine_generation() {
  local home check first generation second
  home=$(make_home stale-generation)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the generation fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- item-a | daily | captain | first routine'
  first=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  generation=$(cat "$home/state/.routine-generation")
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/routine-scan.check.sh:routine-generation:$generation" "$first" \
    || fail "the stale-generation wake could not enter the wake rail"
  printf '%s\n' \
    'item-a|daily|2026-08-10|captain|first routine|2' \
    'item-b|daily|2026-08-10|captain|second routine|2' > "$home/state/.routine-pending"
  write_registry "$home" \
    '- item-a | daily | captain | first routine' \
    '- item-b | daily | captain | second routine'
  ack_watcher_cycle "$home/state" \
    || fail "the stale-generation wake could not be recovered"
  [ -f "$home/state/.routine-pending" ] \
    || fail "recovery consumed newer pending routine state"
  [ ! -s "$home/state/.routine-fired" ] \
    || fail "recovery fired newer pending routine state"
  second=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  case "$second" in
    *'routine-due: item-b | captain | second routine'*) ;;
    *) fail "newer pending routine did not resurface after stale recovery: $second" ;;
  esac
  pass "recovery binds routine acknowledgement to its scan generation"
}
test_normal_acknowledgement_uses_its_scan_generation() {
  local home fakebin check later_pid rc
  home=$(make_home normal-generation-race)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && exit 0
exit 1
SH
  chmod 0755 "$fakebin/tmux"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the normal-ack race fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- item-a | daily | captain | first routine'
  (
    for _ in $(seq 1 300); do
      [ -s "$home/state/.wake-queue" ] || { sleep 0.01; continue; }
      write_registry "$home" \
        '- item-a | daily | captain | first routine' \
        '- item-b | daily | captain | second routine'
      FM_ROUTINE_DATE=2026-08-10 "$check" > "$home/later-scan.out" 2>&1
      exit $?
    done
    exit 1
  ) &
  later_pid=$!
  export FM_ROUTINE_DATE=2026-08-10
  export FM_ROUTINE_WATCH_TEST_DELAY_BEFORE_ACK=1
  run_bounded_watcher \
    "$home" "$home/watch.out" "$fakebin"
  rc=$?
  unset FM_ROUTINE_DATE
  unset FM_ROUTINE_WATCH_TEST_DELAY_BEFORE_ACK
  wait "$later_pid" || fail "the later routine scan did not run during acknowledgement"
  [ "$rc" -eq 0 ] || fail "the watcher did not complete the normal-ack race fixture"
  [ "$(cat "$home/state/.routine-fired")" = 'item-a|daily|2026-08-10' ] \
    || fail "normal acknowledgement did not promote its own scan generation"
  grep -q '^item-b|daily|2026-08-10|' "$home/state/.routine-pending" \
    || fail "normal acknowledgement discarded later pending routine work"
  pass "normal acknowledgement remains bound to its scan generation"
}
test_ack_rejects_dangling_pending_symlink() {
  local home check out rc generation
  home=$(make_home dangling-pending)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the dangling-state fixture"
  check="$home/state/routine-scan.check.sh"
  ln -s "$home/state/missing-pending" "$home/state/.routine-pending"
  generation=1
  if out=$(FM_ROUTINE_DATE=2026-08-10 "$check" --ack --generation "$generation" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "acknowledgement accepted a dangling pending symlink"
  case "$out" in
    *'pending routine state is unavailable:'*) ;;
    *) fail "dangling pending symlink lacked an actionable diagnostic: $out" ;
  esac
  pass "acknowledgement rejects dangling pending state"
}
test_symlink_registry_is_rejected_at_scan_boundary() {
  local home outside out rc
  home=$(make_home symlink-registry)
  outside="$TMP_ROOT/outside-routines.md"
  write_registry "$home" \
    '- outside-item | daily | captain | should not run'
  mv "$home/data/routines.md" "$outside"
  ln -s "$outside" "$home/data/routines.md"
  out=$(run_scan "$home" 2026-08-10 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the scanner followed a symlinked registry"
  case "$out" in
    *'routine-scan: registry is a symlink:'*) ;;
    *) fail "the symlinked registry diagnostic was missing: $out" ;;
  esac
  [ ! -e "$home/state/.routine-fired" ] \
    || fail "the symlinked registry created fire state"
  pass "routine scanner rejects symlinked registries"
}
test_symlink_fired_state_cannot_suppress_due_routine() {
  local home outside out rc
  home=$(make_home symlink-fired)
  outside="$TMP_ROOT/outside-fired-state"
  write_registry "$home" \
    '- protected-item | daily | captain | must surface'
  printf '%s\n' 'protected-item|daily|2026-08-10' > "$outside"
  ln -s "$outside" "$home/state/.routine-fired"
  out=$(run_scan "$home" 2026-08-10 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the scanner followed a symlinked fired state"
  case "$out" in
    *'routine-scan: fired routine state is unavailable:'*) ;;
    *) fail "the symlinked fired-state diagnostic was missing: $out" ;;
  esac
  case "$out" in
    *'routine-due: protected-item'*) fail "external fired state suppressed a due routine: $out" ;;
  esac
  pass "routine scanner rejects symlinked fired state"
}
test_hardlink_fired_state_cannot_suppress_due_routine() {
  local home outside out rc
  home=$(make_home hardlink-fired)
  outside="$TMP_ROOT/outside-hardlink-fired-state"
  write_registry "$home" \
    '- protected-item | daily | captain | must surface'
  printf '%s\n' 'protected-item|daily|2026-08-10' > "$outside"
  ln "$outside" "$home/state/.routine-fired"
  out=$(run_scan "$home" 2026-08-10 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the scanner accepted a hardlinked fired state"
  case "$out" in
    *'routine-scan: fired routine state is unavailable:'*) ;;
    *) fail "the hardlinked fired-state diagnostic was missing: $out" ;;
  esac
  case "$out" in
    *'routine-due: protected-item'*) fail "external hardlinked state suppressed a due routine: $out" ;;
  esac
  pass "routine scanner rejects hardlinked fired state"
}
test_hardlink_registry_is_rejected_at_scan_boundary() {
  local home outside out rc
  home=$(make_home hardlink-registry)
  outside="$TMP_ROOT/outside-hardlink-routines.md"
  write_registry "$home" \
    '- outside-item | daily | captain | should not run'
  mv "$home/data/routines.md" "$outside"
  ln "$outside" "$home/data/routines.md"
  out=$(run_scan "$home" 2026-08-10 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the scanner accepted a hardlinked registry"
  case "$out" in
    *'routine-scan: registry is not a regular file:'*) ;;
    *) fail "the hardlinked registry diagnostic was missing: $out" ;;
  esac
  case "$out" in
    *'routine-due: outside-item'*) fail "the scanner consumed a hardlinked registry: $out" ;;
  esac
  pass "routine scanner rejects hardlinked registries"
}
test_hardlink_pending_is_rejected_before_recovery() {
  local home check outside out rc
  home=$(make_home hardlink-pending)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the hardlinked-pending fixture"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    '- pending-item | daily | captain | recover safely'
  FM_ROUTINE_DATE=2026-08-10 "$check" >/dev/null \
    || fail "the pending fixture did not create pending state"
  outside="$TMP_ROOT/outside-hardlink-pending"
  mv "$home/state/.routine-pending" "$outside"
  ln "$outside" "$home/state/.routine-pending"
  out=$(FM_ROUTINE_DATE=2026-08-10 "$check" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the scanner accepted hardlinked pending state"
  case "$out" in
    *'routine-check-error: scanner exited 1'*) ;;
    *) fail "the hardlinked pending state did not surface an actionable error: $out" ;
  esac
  pass "routine scanner rejects hardlinked pending state"
}
test_check_surfaces_registry_diagnostics() {
  local home check out
  home=$(make_home diagnostics)
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" \
    || fail "routine setup could not create the diagnostic check"
  check="$home/state/routine-scan.check.sh"
  write_registry "$home" \
    'not a routine row' \
    '- malformed-extra | daily | captain | should not run |' \
    '- duplicate-item | daily | captain | check priorities' \
    '- duplicate-item | daily | captain | check again'
  out=$(FM_ROUTINE_DATE=2026-08-10 "$check")
  case "$out" in
    *'routine-scan: ignoring malformed registry line'*) ;;
    *) fail "malformed registry diagnostics were not surfaced: $out" ;;
  esac
  case "$out" in
    *'routine-scan: ignoring duplicate registry id: duplicate-item'*) ;;
    *) fail "duplicate registry diagnostics were not surfaced: $out" ;;
  esac
  case "$out" in
    *'routine-due: malformed-extra'*) fail "a trailing empty registry field was accepted: $out" ;;
  esac
  case "$out" in
    *'routine-due: duplicate-item | captain | check priorities'*) ;;
    *) fail "valid routine output was lost with registry diagnostics: $out" ;;
  esac
  pass "routine check surfaces registry diagnostics"
}
test_bootstrap_seeds_and_arms_private_routine
test_setup_persists_canonical_path_overrides
test_routine_check_enforces_timeout
test_watcher_surfaces_missing_registry_as_a_check_wake
test_watcher_surfaces_missing_registry_with_empty_pending_state
test_daily_fires_once_per_local_day
test_weekly_fires_only_on_matching_weekday
test_weekday_is_derived_from_captured_local_date
test_nothing_due_is_silent_and_does_not_create_fire_state
test_fire_state_prevents_repeats_after_scan_restart
test_duplicate_id_cannot_alternate_fired_cadences
test_deferred_check_acknowledges_after_wake
test_ack_requires_durable_generation_wake
test_ack_rejects_partial_generation_wake
test_unpublished_pending_binds_to_first_successful_wake
test_fired_pending_replay_is_suppressed
test_pending_generation_stays_bound_after_rescan
test_deferred_publication_does_not_refire_after_restart
test_ack_fails_when_routine_state_lock_is_held
test_watcher_acknowledges_only_after_complete_scan
test_recovery_does_not_acknowledge_stale_routine_generation
test_normal_acknowledgement_uses_its_scan_generation
test_ack_rejects_dangling_pending_symlink
test_symlink_registry_is_rejected_at_scan_boundary
test_symlink_fired_state_cannot_suppress_due_routine
test_hardlink_fired_state_cannot_suppress_due_routine
test_hardlink_registry_is_rejected_at_scan_boundary
test_hardlink_pending_is_rejected_before_recovery
test_check_surfaces_registry_diagnostics
