#!/usr/bin/env bash
# Regression tests for fm-guard's watcher-down banner deduplication.
#
# The first stale command in one FM_HOME must print the full actionable watcher
# banner.
# Repeated commands in that same stale episode should print only a concise
# reminder, while unrelated alarms such as queued wakes stay independent.
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

# These cases exercise the persistent-watcher model (a live pid is the real
# liveness signal), so pin the model rather than letting the host test runner's
# ambient harness ancestry pick it.
run_guard_case() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

run_guard_case_read_only() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=persistent \
    FM_GUARD_READ_ONLY=1 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# The Claude Stop auto-arm model: the watcher runs only between turns, so a fresh
# beacon with no live watcher process is the healthy mid-turn state.
run_guard_case_autoarm() {
  local dir=$1
  FM_ROOT_OVERRIDE="$(case_root "$dir")" \
    FM_HOME="$(case_home "$dir")" \
    FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=autoarm \
    "$ROOT/bin/fm-guard.sh" 2>&1
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

test_autoarm_fresh_beacon_without_watcher_is_healthy() {
  local dir out
  dir=$(make_guard_case autoarm-fresh)
  # A fresh beacon and NO live watcher: the healthy mid-turn state under the
  # Claude Stop auto-arm model, where the watcher only runs between turns.
  touch "$(case_home "$dir")/state/.last-watcher-beat"
  out=$(run_guard_case_autoarm "$dir")
  [ -z "$out" ] \
    || fail "auto-arm model with a fresh beacon and no live watcher must stay silent, got: $out"
  pass "fm-guard stale banner: auto-arm fresh beacon without a live watcher is healthy"
}

test_autoarm_stale_beacon_alarms_with_correct_reason() {
  local dir out
  dir=$(make_guard_case autoarm-stale)
  # No beacon at all -> a genuine supervision lapse even under the auto-arm model.
  out=$(run_guard_case_autoarm "$dir")
  [ "$(count_text "$out" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "auto-arm model with an absent/stale beacon must alarm: $out"
  assert_contains "$out" "no watcher has a fresh beacon" \
    "auto-arm stale-beacon banner must name the stale-beacon reason"
  pass "fm-guard stale banner: auto-arm stale beacon alarms with the true reason"
}

test_autoarm_stale_episode_is_stable() {
  local dir out1 out2
  dir=$(make_guard_case autoarm-stable-episode)
  out1=$(run_guard_case_autoarm "$dir")
  out2=$(run_guard_case_autoarm "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first auto-arm stale call did not print the full banner: $out1"
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "auto-arm stale episode re-printed the full banner instead of deduping: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "second auto-arm stale call did not print the concise reminder"
  pass "fm-guard stale banner: auto-arm stale episode stays one episode across calls"
}

test_persistent_no_watcher_banner_names_missing_process() {
  local dir out
  dir=$(make_guard_case persistent-no-watcher-reason)
  # A fresh beacon with no live watcher under the persistent model: the real
  # failing condition is the missing process, not a stale beacon.
  touch "$(case_home "$dir")/state/.last-watcher-beat"
  out=$(run_guard_case "$dir")
  assert_contains "$out" "no live watcher process holds this home lock" \
    "persistent no-watcher banner must name the missing watcher process"
  assert_not_contains "$out" "no watcher has a fresh beacon" \
    "persistent no-watcher banner must not blame the fresh beacon"
  pass "fm-guard stale banner: persistent no-watcher banner names the true reason"
}

test_persistent_no_watcher_episode_survives_beacon_touch() {
  local dir home out1 out2
  dir=$(make_guard_case persistent-no-watcher-episode)
  home=$(case_home "$dir")
  touch "$home/state/.last-watcher-beat"
  out1=$(run_guard_case "$dir")
  [ "$(count_text "$out1" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 1 ] \
    || fail "first persistent no-watcher call did not print the full banner: $out1"
  # The beacon mtime advancing with NO live watcher must not split the continuous
  # down-episode. The old beacon-mtime episode key re-printed the full banner
  # here; the reason-based key keeps it a single episode. Separate the touches by
  # a second so the mtime genuinely changes at whole-second stat granularity.
  sleep 1
  touch "$home/state/.last-watcher-beat"
  out2=$(run_guard_case "$dir")
  [ "$(count_text "$out2" "WATCHER DOWN - SUPERVISION IS OFF")" -eq 0 ] \
    || fail "advancing the beacon mtime with no live watcher re-printed the banner: $out2"
  assert_contains "$out2" "full banner already printed this episode" \
    "same no-watcher episode did not print the concise reminder after a beacon touch"
  pass "fm-guard stale banner: a no-watcher episode survives a beacon mtime change"
}

test_first_stale_call_prints_full_banner
test_repeated_same_episode_prints_reminder_only
test_autoarm_fresh_beacon_without_watcher_is_healthy
test_autoarm_stale_beacon_alarms_with_correct_reason
test_autoarm_stale_episode_is_stable
test_persistent_no_watcher_banner_names_missing_process
test_persistent_no_watcher_episode_survives_beacon_touch
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
