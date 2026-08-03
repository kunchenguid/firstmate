#!/usr/bin/env bash
# Regression tests for fm-guard's stale-watcher banner: what it SAYS, which
# supervision state it says it about, and how it deduplicates.
#
# The first stale command in one FM_HOME must print the full actionable watcher
# banner.
# Repeated commands in that same stale episode should print only a concise
# reminder, while unrelated alarms such as queued wakes stay independent.
# The banner must name the condition that actually failed, and a watcher that
# ended one cycle cleanly and is awaiting re-arm must not be reported as a dead
# watcher - while a watcher that genuinely vanished still alarms at once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-stale-banner)

make_guard_case() {
  local name=$1 dir home root
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  printf '%s\n' "$dir"
}

case_home() {
  printf '%s/home\n' "$1"
}

case_root() {
  printf '%s/root\n' "$1"
}

record_live_watcher() {
  local dir=$1 pid=$2 home identity
  home=$(case_home "$dir")
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") || return 1
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
}

run_guard_case() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_guard_case_read_only() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_GUARD_READ_ONLY=1 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_guard_case_grace() {  # <case-dir> <grace-seconds>
  local dir=$1 grace=$2
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE="$grace" \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# Backdate a path's mtime by a whole number of seconds. Both readouts under test
# compare recorded timestamps, so the fixtures must set them exactly rather than
# sleeping for them.
age_path() {  # <path> <seconds-ago>
  local now
  now=$(date +%s)
  perl -e 'my $t = $ARGV[1]; utime $t, $t, $ARGV[0] or die "utime: $!"' "$1" "$((now - $2))"
}

# A clean cycle exit: the watcher published its identity-bound terminal delivery
# and released the lock. The delivery is at or after the last beat because the
# watcher beats at the top of a poll and publishes only on its way out.
record_clean_cycle_exit() {  # <case-dir> [beat-age-seconds]
  local dir=$1 age=${2:-16} home
  home=$(case_home "$dir")
  rm -rf "$home/state/.watch.lock"
  printf '4242\tpid-identity\tsignal: %s/state/task.status\n' "$home" \
    > "$home/state/.watch-deliveries.log"
  touch "$home/state/.last-watcher-beat"
  age_path "$home/state/.last-watcher-beat" "$age"
  age_path "$home/state/.watch-deliveries.log" "$age"
}

# A watcher that vanished mid-cycle: it beat, then died without publishing a
# delivery, so the newest record in the home is the beat.
record_vanished_watcher() {  # <case-dir>
  local dir=$1 home
  home=$(case_home "$dir")
  rm -rf "$home/state/.watch.lock"
  printf '4242\tpid-identity\tsignal: an older cycle\n' \
    > "$home/state/.watch-deliveries.log"
  age_path "$home/state/.watch-deliveries.log" 400
  touch "$home/state/.last-watcher-beat"
  age_path "$home/state/.last-watcher-beat" 16
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

# A watcher killed without running its exit trap leaves its own lock behind with
# a pid that is no longer alive.
record_dead_pid_lock() {  # <case-dir>
  local dir=$1 home pid
  home=$(case_home "$dir")
  pid=$(nonexistent_pid)
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "recorded-identity" > "$home/state/.watch.lock/pid-identity"
  printf '%s\n' "$pid"
}

count_text() {
  local haystack=$1 needle=$2
  awk -v needle="$needle" 'index($0, needle) { c++ } END { print c + 0 }' <<EOF
$haystack
EOF
}

test_first_stale_call_prints_full_banner() {
  local dir out
  dir=$(make_guard_case first-stale)
  out=$(run_guard_case "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale guard call did not print exactly one full banner: $out"
  assert_contains "$out" "Trust the emitted supervision protocol" \
    "full banner must keep the actionable watcher-repair instruction"
  assert_contains "$out" "WILL still run" \
    "full banner must keep the guarded-operation continuation line"
  pass "fm-guard stale banner: first stale call prints the full actionable banner"
}

test_repeated_same_episode_prints_reminder_only() {
  local dir out1 out2 marker lines
  dir=$(make_guard_case repeated-stale)
  out1=$(run_guard_case "$dir")
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner: $out1"
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "second stale call repeated the full banner: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "second stale call did not print the concise reminder"
  marker="$(case_home "$dir")/state/.guard-watcher-stale-banner"
  assert_present "$marker" "stale banner marker was not written under the owning home"
  lines=$(awk 'END { print NR + 0 }' "$marker")
  [ "$lines" -le 1 ] || fail "stale banner marker must stay bounded to one line, got $lines"
  pass "fm-guard stale banner: repeated same-episode calls print a concise reminder only"
}

test_fresh_beacon_without_live_watcher_stays_alarm() {
  local dir out
  dir=$(make_guard_case fresh-no-live)
  touch "$(case_home "$dir")/state/.last-watcher-beat"
  out=$(run_guard_case "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a fresh leftover beacon without a live watcher must still alarm: $out"
  pass "fm-guard stale banner: a fresh beacon without a live watcher remains unhealthy"
}

test_x_mode_without_live_watcher_stays_alarm() {
  local dir home out
  dir=$(make_guard_case x-mode-no-live)
  home=$(case_home "$dir")
  rm -f "$home/state/task.meta"
  : > "$home/state/x-watch.check.sh"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "X-mode relay polling needs supervision" "X-mode-only need must remain guarded"
  pass "fm-guard stale banner: X-mode polling without a live watcher remains unhealthy"
}

test_healthy_recovery_rearms_next_stale_episode() {
  local dir home out1 healthy out2 pid
  dir=$(make_guard_case healthy-recovery)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale episode did not print the full banner: $out1"

  sleep 60 &
  pid=$!
  record_live_watcher "$dir" "$pid" || fail "could not record the live watcher for recovery"
  touch "$home/state/.last-watcher-beat"
  healthy=$(run_guard_case "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -z "$healthy" ] || fail "guard should be silent after watcher recovery, got: $healthy"
  assert_absent "$home/state/.guard-watcher-stale-banner" \
    "healthy recovery must clear the stale-banner marker"

  rm -f "$home/state/.last-watcher-beat"
  rm -rf "$home/state/.watch.lock"
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "second stale episode did not re-print the full banner: $out2"
  pass "fm-guard stale banner: healthy recovery rearms the next stale episode"
}

test_concurrent_same_episode_prints_one_full_banner() {
  local dir out_dir i pids pid all full reminders
  dir=$(make_guard_case concurrent-stale)
  out_dir="$dir/outs"
  mkdir -p "$out_dir"
  pids=
  i=1
  while [ "$i" -le 30 ]; do
    (
      run_guard_case "$dir" > "$out_dir/$i.out" 2>&1
    ) &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || fail "concurrent guard subprocess failed"
  done
  all=$(cat "$out_dir"/*.out)
  full=$(count_text "$all" "WATCHER DOWN - SUPERVISION IS OFF")
  reminders=$(count_text "$all" "full banner already printed this episode")
  [ "$full" -eq 1 ] || fail "concurrent same-episode calls printed $full full banners"$'\n'"$all"
  [ "$reminders" -eq 29 ] || fail "concurrent same-episode calls printed $reminders reminders, expected 29"$'\n'"$all"
  pass "fm-guard stale banner: concurrent same-episode calls claim exactly one full banner"
}

test_home_isolation() {
  local dir_a dir_b out_a1 out_a2 out_b1
  dir_a=$(make_guard_case home-a)
  dir_b=$(make_guard_case home-b)
  out_a1=$(run_guard_case "$dir_a")
  out_b1=$(run_guard_case "$dir_b")
  out_a2=$(run_guard_case "$dir_a")
  [ "$(count_text "$out_a1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home A first stale call did not print a full banner: $out_a1"
  [ "$(count_text "$out_b1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "home B first stale call was suppressed by home A: $out_b1"
  assert_contains "$out_a2" "full banner already printed this episode" \
    "home A repeated stale call did not remember its own episode"
  pass "fm-guard stale banner: deduplication is isolated per FM_HOME"
}

test_queued_wake_warning_stays_independent() {
  local dir home out1 out2
  dir=$(make_guard_case queued-wake)
  home=$(case_home "$dir")
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first stale call did not print the full banner before queued wake case: $out1"
  printf 'signal: %s/state/task.status\n' "$home" > "$home/state/.wake-queue"
  out2=$(run_guard_case "$dir")
  assert_contains "$out2" "full banner already printed this episode" \
    "same-episode stale call should still print its concise reminder"
  assert_contains "$out2" "queued wakes pending" \
    "queued wake warning must not be suppressed by stale-banner deduplication"
  pass "fm-guard stale banner: queued-wake warning remains independent"
}

test_read_only_before_writable_does_not_consume_full_banner() {
  local dir home marker lock out_ro out_rw
  dir=$(make_guard_case read-only-before-writable)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"

  out_ro=$(run_guard_case_read_only "$dir")
  [ "$(count_text "$out_ro" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "read-only stale call should print the advisory full banner: $out_ro"
  assert_absent "$marker" "read-only stale call must not create the stale-banner marker"
  assert_absent "$lock" "read-only stale call must not create the stale-banner lock"

  out_rw=$(run_guard_case "$dir")
  [ "$(count_text "$out_rw" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "writable stale call should still receive the full banner after read-only: $out_rw"
  assert_present "$marker" "writable stale call should claim the stale-banner marker"
  pass "fm-guard stale banner: read-only before writable does not consume full banner"
}

test_read_only_during_episode_observes_without_mutating_marker() {
  local dir home marker before after out_ro
  dir=$(make_guard_case read-only-during-episode)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  out_ro=$(run_guard_case_read_only "$dir")
  after=$(cat "$marker")
  assert_contains "$out_ro" "full banner already printed this episode" \
    "read-only stale call during a claimed episode should print the concise reminder"
  [ "$after" = "$before" ] || fail "read-only stale call must not update an existing marker"
  pass "fm-guard stale banner: read-only during episode observes without mutating marker"
}

test_healthy_read_only_does_not_clear_marker() {
  local dir home marker before after healthy pid
  dir=$(make_guard_case healthy-read-only)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"

  run_guard_case "$dir" >/dev/null
  before=$(cat "$marker")
  sleep 60 &
  pid=$!
  record_live_watcher "$dir" "$pid" || fail "could not record the live watcher for read-only recovery"
  touch "$home/state/.last-watcher-beat"
  healthy=$(run_guard_case_read_only "$dir")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -z "$healthy" ] || fail "healthy read-only guard should stay silent, got: $healthy"
  assert_present "$marker" "healthy read-only guard must not clear the stale-banner marker"
  after=$(cat "$marker")
  [ "$after" = "$before" ] || fail "healthy read-only guard must not update the marker"
  pass "fm-guard stale banner: healthy read-only does not clear marker"
}

test_read_only_never_mutates_stale_banner_state_files() {
  local dir home marker lock before after no_work
  dir=$(make_guard_case read-only-state-nonmutation)
  home=$(case_home "$dir")
  marker="$home/state/.guard-watcher-stale-banner"
  lock="$home/state/.guard-watcher-stale-banner.lock"
  printf '%s\n' "sentinel-marker" > "$marker"

  before=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  run_guard_case_read_only "$dir" >/dev/null
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "stale read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "stale read-only guard updated the marker content"
  assert_absent "$lock" "stale read-only guard must not create the stale-banner lock"

  rm -f "$home/state/task.meta"
  no_work=$(run_guard_case_read_only "$dir")
  [ -z "$no_work" ] || fail "read-only guard with no in-flight work should stay silent, got: $no_work"
  after=$(find "$home/state" -maxdepth 1 -mindepth 1 -name '.guard-watcher-stale-banner*' -print | sort)
  [ "$after" = "$before" ] || fail "no-work read-only guard changed stale-banner state files"$'\n'"before: $before"$'\n'"after: $after"
  [ "$(cat "$marker")" = "sentinel-marker" ] || fail "no-work read-only guard updated the marker content"
  pass "fm-guard stale banner: read-only never mutates stale-banner state files"
}

# --- what the banner SAYS ---------------------------------------------------
#
# Regression for the 2026-08-02 self-contradicting banner: the guard rendered
# its explanation purely from beacon age ("no watcher has a fresh beacon (last
# beat: 16s ago, grace 300s)") no matter which clause of the health predicate
# actually rejected. 16s inside a 300s grace is fresh, so the stated reason was
# false and the real one - no watcher process holding the lock - was never
# printed. The banner must name the condition that failed.
test_banner_names_the_missing_watcher_process() {
  local dir home out beat_age
  dir=$(make_guard_case reason-no-lock)
  home=$(case_home "$dir")
  touch "$home/state/.last-watcher-beat"
  age_path "$home/state/.last-watcher-beat" 16
  out=$(run_guard_case_grace "$dir" 300)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a watcher-less home with work in flight must still alarm: $out"
  assert_not_contains "$out" "no watcher has a fresh beacon" \
    "the banner must not blame a beacon that is well inside the grace window"
  assert_contains "$out" "no watcher process holds the supervision lock" \
    "the banner must name the condition the health check actually rejected on"
  # The beacon age stays as context. Read it back with a tolerance rather than an
  # exact match: it is recomputed when the guard runs, seconds after the fixture.
  beat_age=$(printf '%s\n' "$out" | sed -n 's/.*last beat: \([0-9][0-9]*\)s ago.*/\1/p' | head -1)
  [ -n "$beat_age" ] || fail "the banner dropped the beacon age it still reports on: $out"
  { [ "$beat_age" -ge 16 ] && [ "$beat_age" -lt 300 ]; } \
    || fail "the banner reported a beacon age of ${beat_age}s for a 16s-old beacon inside a 300s grace: $out"
  pass "fm-guard banner: names the missing watcher process, not a fresh beacon"
}

test_banner_names_a_dead_watcher_process() {
  local dir home pid out
  dir=$(make_guard_case reason-dead-pid)
  home=$(case_home "$dir")
  pid=$(record_dead_pid_lock "$dir")
  touch "$home/state/.last-watcher-beat"
  age_path "$home/state/.last-watcher-beat" 16
  out=$(run_guard_case_grace "$dir" 300)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a dead recorded watcher must alarm: $out"
  assert_not_contains "$out" "no watcher has a fresh beacon" \
    "a dead watcher pid is not a stale-beacon failure"
  assert_contains "$out" "recorded watcher process (pid $pid) is gone" \
    "the banner must name the dead watcher process it found"
  pass "fm-guard banner: names a dead recorded watcher process"
}

# The original wording is correct for exactly one case and must survive there.
test_banner_still_blames_a_genuinely_stale_beacon() {
  local dir home out pid
  dir=$(make_guard_case reason-stale-beacon)
  home=$(case_home "$dir")
  sleep 60 &
  pid=$!
  record_live_watcher "$dir" "$pid" || fail "could not record the live watcher"
  touch "$home/state/.last-watcher-beat"
  age_path "$home/state/.last-watcher-beat" 900
  out=$(run_guard_case_grace "$dir" 300)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a live watcher with a stale beacon must alarm: $out"
  assert_contains "$out" "no watcher has a fresh beacon" \
    "a genuinely stale beacon must still be reported as the failing condition"
  pass "fm-guard banner: a genuinely stale beacon is still reported as such"
}

# --- clean cycle exit vs a dead watcher -------------------------------------
#
# bin/fm-watch.sh runs one cycle and exits after delivering an actionable wake,
# so the whole wake-handling window legitimately has no watcher process. That is
# a handoff awaiting re-arm, not absent supervision, and the guard must stop
# announcing it as "SUPERVISION IS OFF".
test_clean_cycle_exit_is_not_reported_as_supervision_off() {
  local dir out
  dir=$(make_guard_case clean-handoff)
  record_clean_cycle_exit "$dir" 16
  out=$(run_guard_case_grace "$dir" 300)
  assert_not_contains "$out" "WATCHER DOWN - SUPERVISION IS OFF" \
    "a clean cycle exit awaiting re-arm must not be announced as absent supervision"
  assert_contains "$out" "watcher handed off" \
    "a clean cycle exit must be reported as the handoff it is"
  pass "fm-guard banner: a clean cycle exit is reported as a handoff, not a dead watcher"
}

test_clean_cycle_exit_notice_is_printed_once_per_episode() {
  local dir out1 out2
  dir=$(make_guard_case clean-handoff-dedup)
  record_clean_cycle_exit "$dir" 16
  out1=$(run_guard_case_grace "$dir" 300)
  out2=$(run_guard_case_grace "$dir" 300)
  [ "$(count_text "$out1" "watcher handed off")" -eq 1 ] \
    || fail "the first guarded command in a handoff must print the notice: $out1"
  [ "$(count_text "$out2" "watcher handed off")" -eq 0 ] \
    || fail "the handoff notice must not repeat for every guarded command: $out2"
  pass "fm-guard banner: the handoff notice prints once per episode"
}

# True-positive protection: the whole point of the guard is that a genuinely
# dead watcher alarms loudly and promptly. A watcher that beat and then vanished
# published no terminal delivery, so it must still get the full banner - at the
# same beacon age that the clean-handoff case treats as benign.
test_vanished_watcher_still_alarms_at_the_same_beacon_age() {
  local dir out
  dir=$(make_guard_case vanished-watcher)
  record_vanished_watcher "$dir"
  out=$(run_guard_case_grace "$dir" 300)
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a watcher that vanished mid-cycle must still alarm immediately: $out"
  assert_not_contains "$out" "watcher handed off" \
    "a vanished watcher must never be excused as a clean handoff"
  pass "fm-guard banner: a watcher that vanished mid-cycle still alarms immediately"
}

# True-positive protection for the delayed case: a clean handoff whose re-arm
# never arrived is a real lapse once the beacon goes stale, and it must escalate
# from the handoff notice to the full banner even though the beacon mtime - and
# therefore the old episode key - never changed.
test_handoff_whose_rearm_never_came_escalates_to_the_full_banner() {
  local dir home out1 out2
  dir=$(make_guard_case handoff-rearm-never-came)
  home=$(case_home "$dir")
  record_clean_cycle_exit "$dir" 16
  out1=$(run_guard_case_grace "$dir" 300)
  [ "$(count_text "$out1" "watcher handed off")" -eq 1 ] \
    || fail "handoff notice missing before the escalation: $out1"
  # Same beacon mtime, now outside the grace window: supervision really is gone.
  out2=$(run_guard_case_grace "$dir" 5)
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "a handoff that outlived the grace window must print the full banner: $out2"
  assert_present "$home/state/.guard-watcher-stale-banner" \
    "the escalated banner must claim its own episode"
  pass "fm-guard banner: a handoff whose re-arm never came escalates to the full banner"
}

test_first_stale_call_prints_full_banner
test_banner_names_the_missing_watcher_process
test_banner_names_a_dead_watcher_process
test_banner_still_blames_a_genuinely_stale_beacon
test_clean_cycle_exit_is_not_reported_as_supervision_off
test_clean_cycle_exit_notice_is_printed_once_per_episode
test_vanished_watcher_still_alarms_at_the_same_beacon_age
test_handoff_whose_rearm_never_came_escalates_to_the_full_banner
test_repeated_same_episode_prints_reminder_only
test_fresh_beacon_without_live_watcher_stays_alarm
test_x_mode_without_live_watcher_stays_alarm
test_healthy_recovery_rearms_next_stale_episode
test_concurrent_same_episode_prints_one_full_banner
test_home_isolation
test_queued_wake_warning_stays_independent
test_read_only_before_writable_does_not_consume_full_banner
test_read_only_during_episode_observes_without_mutating_marker
test_healthy_read_only_does_not_clear_marker
test_read_only_never_mutates_stale_banner_state_files
