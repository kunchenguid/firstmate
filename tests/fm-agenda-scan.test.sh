#!/usr/bin/env bash
# Regression tests for the private business-agenda scheduler.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCAN="$ROOT/bin/fm-agenda-scan.sh"
SETUP="$ROOT/bin/fm-agenda-setup.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-agenda-scan)
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
    '# Business agenda registry.' \
    '# Format: - <id> | <cadence> | <owner> | <action> | <delivery>' \
    "$@" > "$home/data/business-agenda.md"
}
run_scan() {
  local home=$1 date_value=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_AGENDA_DATE="$date_value" "$SCAN"
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
test_bootstrap_seeds_and_arms_private_agenda() {
  local home registry check out active_count todo_count expected
  home=$(make_home provision)
  registry="$home/data/business-agenda.md"
  check="$home/state/agenda-scan.check.sh"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip FM_BACKEND=tmux \
    "$BOOTSTRAP" > "$home/bootstrap.out" 2> "$home/bootstrap.err" \
    || fail "bootstrap could not provision the business agenda"

  [ -f "$registry" ] && [ ! -L "$registry" ] || fail "bootstrap did not seed the private agenda registry"
  [ "$(file_mode "$registry")" = 600 ] || fail "the seeded agenda registry is not mode 0600"
  [ -f "$check" ] && [ ! -L "$check" ] || fail "bootstrap did not arm the agenda check"
  [ "$(file_mode "$check")" = 700 ] || fail "the agenda check is not mode 0700"
  [ "$(file_links "$check")" = 1 ] || fail "the agenda check is not a single-link file"

  active_count=$(awk '$0 ~ /^- / { n++ } END { print n+0 }' "$registry")
  todo_count=$(awk '$0 ~ /^# TODO: - / { n++ } END { print n+0 }' "$registry")
  [ "$active_count" -eq 4 ] || fail "the seeded registry does not contain four active captain routines"
  [ "$todo_count" -eq 2 ] || fail "the seeded registry does not contain two TODO placeholders"

  bash -c '. "$1"; . "$2"; fm_custom_check_registered "$3" agenda-scan' \
    _ "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-check-lib.sh" "$home/state" \
    || fail "the agenda check was not registered with the custom-check trust rail"
  bash -c '. "$1"; fm_supervision_needed "$2" 300' \
    _ "$ROOT/bin/fm-supervision-lib.sh" "$home/state" \
    || fail "an agenda-only home did not retain watcher supervision"

  out=$(FM_AGENDA_DATE=2026-08-10 "$check")
  expected=$(cat <<'EOF'
agenda-due: seller-outreach-followup | seller-outreach | draft the daily follow-up
agenda-due: operations-monitoring | monitoring | check active operational monitors
agenda-due: business-processes-update | business-processes | draft the weekly update
agenda-due: captain-priorities-review | captain | review weekly business priorities
EOF
)
  [ "$out" = "$expected" ] || fail "the provisioned agenda check did not run the seeded routines"
  pass "bootstrap seeds and arms the private business agenda"
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
    || fail "agenda setup rejected relative path overrides"
  check="$state/agenda-scan.check.sh"
  [ -f "$data/business-agenda.md" ] || fail "agenda setup ignored the data override"
  [ -f "$check" ] || fail "agenda setup ignored the state override"

  out=$(cd "$run_dir" && FM_AGENDA_DATE=2026-08-10 "$check")
  expected=$(cat <<'EOF'
agenda-due: seller-outreach-followup | seller-outreach | draft the daily follow-up
agenda-due: operations-monitoring | monitoring | check active operational monitors
agenda-due: business-processes-update | business-processes | draft the weekly update
agenda-due: captain-priorities-review | captain | review weekly business priorities
EOF
)
  [ "$out" = "$expected" ] || fail "agenda check did not retain its provisioned registry path"
  [ -f "$state/.agenda-fired" ] || fail "agenda check did not retain its provisioned state path"
  [ ! -e "$home/state/.agenda-fired" ] || fail "agenda check wrote fire state under the relative runtime cwd"
  pass "agenda check retains canonical data and state overrides"
}
test_agenda_check_enforces_timeout() {
  local home fake_root check out rc marker
  home=$(make_home timeout)
  fake_root="$TMP_ROOT/timeout-root"
  marker="$home/scanner-started"
  mkdir -p "$fake_root/bin"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$fake_root/bin/fm-timeout-lib.sh"
  cat > "$fake_root/bin/fm-agenda-scan.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_TEST_AGENDA_STARTED:?}"
sleep 5
SH
  chmod 0755 "$fake_root/bin/fm-agenda-scan.sh"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" "$SETUP" \
    || fail "agenda setup could not create the timeout fixture"
  check="$home/state/agenda-scan.check.sh"
  out=$(FM_TEST_AGENDA_STARTED="$marker" FM_CHECK_TIMEOUT=1 FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    "$check" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 124 ] || fail "agenda check did not report its FM_CHECK_TIMEOUT deadline"
  [ "$out" = 'agenda-check-error: scanner exited 124' ] \
    || fail "agenda check timeout did not emit an actionable watcher wake"
  [ -f "$marker" ] || fail "timeout fixture never started the agenda scanner"

  out=$(FM_CHECK_TIMEOUT=2 FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_TEST_AGENDA_STARTED="$marker" \
    bash -c '. "$1"; fm_run_timed 1 "$2"' _ "$ROOT/bin/fm-timeout-lib.sh" "$check" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 124 ] || fail "the watcher-style outer timeout did not stop the agenda check"
  [ "$out" = 'agenda-check-error: scanner interrupted' ] \
    || fail "an outer watcher timeout did not produce an actionable check line"
  pass "agenda check bounds and reports scanner timeouts"
}
test_daily_fires_once_per_local_day() {
  local home out
  home=$(make_home daily)
  write_registry "$home" \
    '- daily-item | daily | seller-outreach | draft the daily follow-up | notify'
  out=$(run_scan "$home" 2026-08-10)
  [ "$out" = 'agenda-due: daily-item | seller-outreach | draft the daily follow-up' ] \
    || fail "daily item did not fire on its first day"
  out=$(run_scan "$home" 2026-08-10)
  [ -z "$out" ] || fail "daily item fired twice on the same day"
  [ "$(cat "$home/state/.agenda-fired")" = 'daily-item|daily|2026-08-10' ] \
    || fail "daily fire state did not record the current period"
  out=$(run_scan "$home" 2026-08-11)
  [ "$out" = 'agenda-due: daily-item | seller-outreach | draft the daily follow-up' ] \
    || fail "daily item did not fire on the next day"
  pass "daily items fire once per local day"
}
test_weekly_fires_only_on_matching_weekday() {
  local home out
  home=$(make_home weekly)
  write_registry "$home" \
    '- monday-item | weekly:mon | business-processes | draft the weekly update | notify'
  out=$(run_scan "$home" 2026-08-10)
  [ "$out" = 'agenda-due: monday-item | business-processes | draft the weekly update' ] \
    || fail "weekly Monday item did not fire on Monday"
  out=$(run_scan "$home" 2026-08-10)
  [ -z "$out" ] || fail "weekly Monday item fired twice on Monday"
  out=$(run_scan "$home" 2026-08-11)
  [ -z "$out" ] || fail "weekly Monday item fired on Tuesday"
  out=$(run_scan "$home" 2026-08-17)
  [ "$out" = 'agenda-due: monday-item | business-processes | draft the weekly update' ] \
    || fail "weekly Monday item did not fire on the next Monday"
  pass "weekly items fire only on their matching weekday"
}
test_nothing_due_is_silent_and_does_not_create_fire_state() {
  local home out
  home=$(make_home silent)
  write_registry "$home" \
    '- monday-item | weekly:mon | monitoring | check the monitor | notify-on-problem'
  out=$(run_scan "$home" 2026-08-11)
  [ -z "$out" ] || fail "non-matching weekly item printed output"
  [ ! -e "$home/state/.agenda-fired" ] \
    || fail "a silent scan changed fire state"
  pass "nothing due prints nothing and leaves fire state unchanged"
}
test_fire_state_prevents_repeats_after_scan_restart() {
  local home first second
  home=$(make_home restart)
  write_registry "$home" \
    '- daily-item | daily | monitoring | check the monitor | notify'
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
    '- shared-item | daily | monitoring | check the daily monitor | notify' \
    '- shared-item | weekly:mon | captain | review the weekly monitor | do'
  first=$(run_scan "$home" 2026-08-10 2>/dev/null)
  second=$(run_scan "$home" 2026-08-10 2>/dev/null)
  [ "$first" = 'agenda-due: shared-item | monitoring | check the daily monitor' ] \
    || fail "the first duplicate-id record did not own the agenda id"
  [ -z "$second" ] || fail "a duplicate id alternated cadences after its first firing"
  [ "$(cat "$home/state/.agenda-fired")" = 'shared-item|daily|2026-08-10' ] \
    || fail "a duplicate id replaced the first record's durable fire state"
  pass "duplicate ids cannot alternate fired cadences"
}
test_bootstrap_seeds_and_arms_private_agenda
test_setup_persists_canonical_path_overrides
test_agenda_check_enforces_timeout
test_daily_fires_once_per_local_day
test_weekly_fires_only_on_matching_weekday
test_nothing_due_is_silent_and_does_not_create_fire_state
test_fire_state_prevents_repeats_after_scan_restart
test_duplicate_id_cannot_alternate_fired_cadences
