#!/usr/bin/env bash
# Firstmate-imposed hold expiry through the watcher's real queue interface.
# No endpoint, harness process, model call, or remote host is needed.
#
# A hold firstmate imposed on a task (fm-send --hold) is recorded in that
# task's status with an expiry. When it lapses, the watcher must raise ONE
# actionable wake naming the hold and the exact renew/release commands - and
# nothing else may wake. These tests drive the real tick with deterministic
# clock epochs:
#   1. A hold not yet due is silent, and one already waked never repeats.
#   2. A lapsed hold queues exactly one wake carrying the renew/release
#      commands; the durable marker, not the queue row, is what stops repeats.
#   3. Renewal supersedes: a new id wakes once at its own expiry.
#   4. Release ends everything silently and cleans the marker.
#   5. Crew-declared paused: waits and captain-held lines never wake here, an
#      unparseable until fails safe (lapsed, not far-future), and the scan
#      cadence bounds the fleet pass.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-imposed-holds)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

# 2030-01-02T03:04Z: far-future for a "not due" hold; U-1/U+1 bracket lapse.
U=$(fm_utc_iso_to_epoch 2030-01-02T03:04Z)
ID=aaaabbbbccccdddd
ID2=1111222233334444

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  IMPOSED_HOLD_EXPIRY=
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

imposed_status() {  # <task> <id> <until-iso> -> writes one open imposed hold
  printf 'working [at=100]: started\n' > "$STATE/$1.status"
  printf 'paused [hold=firstmate] [at=1000] [key=imposed-hold-%s]: imposed-hold-%s: hold until %s\n' \
    "$2" "$2" "$3" >> "$STATE/$1.status"
}

test_not_due_is_silent() {
  reset_case
  imposed_status worker "$ID" 2030-01-02T03:04Z
  imposed_hold_expiry_tick $((U - 1))
  [ "$(count_wakes)" = 0 ] || fail "not-yet-due hold queued a wake"
  [ -z "$IMPOSED_HOLD_EXPIRY" ] || fail "not-yet-due hold raised a reason"
  pass "a hold inside its window is silent"
}

test_lapse_queues_exactly_one_wake() {
  reset_case
  imposed_status worker "$ID" 2030-01-02T03:04Z
  imposed_hold_expiry_tick "$U"
  [ "$(count_wakes)" = 1 ] || fail "a lapsed hold did not queue its wake"
  [ "$IMPOSED_HOLD_EXPIRY" = "check: imposed hold expired: worker hold imposed-hold-$ID expired at 2030-01-02T03:04:00Z - renew it with a reason (fm-send worker --hold \"<reason>\") or release it (fm-send worker --release-hold \"<note>\")" ] \
    || fail "wake did not carry the exact expiry reason: $IMPOSED_HOLD_EXPIRY"
  # Repeat polls stay silent even with the queue row still unconsumed: the
  # durable marker, not delivery, ends the episode.
  imposed_hold_expiry_tick $((U + 1))
  imposed_hold_expiry_tick $((U + 61))
  [ "$(count_wakes)" = 1 ] || fail "lapsed hold woke more than once"
  [ -z "$IMPOSED_HOLD_EXPIRY" ] || fail "an already-waked hold re-raised a reason"
  pass "a lapsed hold queues exactly one actionable wake with renew/release commands"
}

test_marker_not_queue_row_ends_the_episode() {
  reset_case
  imposed_status worker "$ID" 2030-01-02T03:04Z
  imposed_hold_expiry_tick "$U"
  # Consume the queue row (fm-wake-drain's job) and keep polling: silent.
  printf '' > "$FM_WAKE_QUEUE"
  imposed_hold_expiry_tick $((U + 61))
  [ "$(count_wakes)" = 0 ] || fail "delivery of the wake did not end the episode"
  pass "the durable marker, not the unconsumed queue row, ends the episode"
}

test_renewal_re_arms() {
  reset_case
  imposed_status worker "$ID" 2030-01-02T03:04Z
  imposed_hold_expiry_tick "$U"
  # Renewal: a new id with a fresh window, after the wake fired.
  printf 'paused [hold=firstmate] [at=%s] [key=imposed-hold-%s]: imposed-hold-%s: renewed until 2030-01-02T03:04Z\n' \
    "$((U + 1))" "$ID2" "$ID2" >> "$STATE/worker.status"
  imposed_hold_expiry_tick $((U + 61))
  [ "$(count_wakes)" = 2 ] || fail "renewed hold did not wake at its own expiry"
  printf '%s' "$IMPOSED_HOLD_EXPIRY" | grep -F "imposed-hold-$ID2" >/dev/null \
    || fail "renewal wake named the superseded hold: $IMPOSED_HOLD_EXPIRY"
  imposed_hold_expiry_tick $((U + 130))
  [ "$(count_wakes)" = 2 ] || fail "renewed hold repeated its wake"
  pass "a renewal supersedes and wakes once at its own new expiry"
}

test_release_is_silent_and_cleans_up() {
  reset_case
  imposed_status worker "$ID" 2030-01-02T03:04Z
  imposed_hold_expiry_tick "$U"
  printf 'resolved [at=%s] [key=imposed-hold-%s]: imposed-hold-%s: released by firstmate: resume\n' \
    "$((U + 1))" "$ID" "$ID" >> "$STATE/worker.status"
  imposed_hold_expiry_tick $((U + 61))
  [ "$(count_wakes)" = 1 ] || fail "released hold still woke"
  [ -z "$IMPOSED_HOLD_EXPIRY" ] || fail "released hold raised a reason"
  [ ! -e "$STATE/.imposed-hold-woke-worker" ] \
    || fail "release left the wake marker behind"
  pass "release ends the episode silently and removes the marker"
}

test_never_wakes_crew_or_captain_records() {
  reset_case
  printf 'paused [at=1000]: crew-declared wait until 2030-01-02T03:04Z\n' > "$STATE/crew.status"
  printf 'captain-held [at=1000] [key=x]: transferred to the captain\n' > "$STATE/held.status"
  printf 'working [at=100]: plain work\n' > "$STATE/plain.status"
  imposed_hold_expiry_tick "$U"
  imposed_hold_expiry_tick $((U + 61))
  [ "$(count_wakes)" = 0 ] || fail "crew pause or captain hold woke the expiry tick"
  [ -z "$IMPOSED_HOLD_EXPIRY" ] || fail "crew pause or captain hold raised a reason"
  pass "crew-declared pauses, captain-held lines, and verbless tasks never wake here"
}

test_unparseable_until_fails_safe() {
  reset_case
  printf 'paused [hold=firstmate] [at=1000] [key=imposed-hold-%s]: imposed-hold-%s: no time stated\n' \
    "$ID" "$ID" > "$STATE/worker.status"
  imposed_hold_expiry_tick 2000
  [ "$(count_wakes)" = 1 ] || fail "a hold with no readable until never woke"
  printf '%s' "$IMPOSED_HOLD_EXPIRY" | grep -F 'expired with no time recorded' >/dev/null \
    || fail "missing-until wake did not say so: $IMPOSED_HOLD_EXPIRY"
  pass "a hold whose until cannot be read wakes immediately as lapsed"
}

test_scan_cadence_bounds_the_pass() {
  reset_case
  imposed_status worker "$ID" 2030-01-02T03:04Z
  # A scan just ran (marker at U): the next poll inside the cadence window
  # must not rescan, so the lapse surfaces only at the next cadence step.
  imposed_hold_expiry_tick $((U - 61))
  [ "$(count_wakes)" = 0 ] || fail "pre-cadence scan woke a hold inside its window"
  imposed_hold_expiry_tick $((U - 30))
  [ "$(count_wakes)" = 0 ] || fail "scan ignored the cadence marker"
  imposed_hold_expiry_tick "$U"
  [ "$(count_wakes)" = 1 ] || fail "cadence-bounded scan missed the lapse"
  pass "the scan runs at most once per cadence window"
}

test_invalid_scan_settings_fall_back() {
  local value
  for value in bogus 0 08 9999999999; do
    reset_case
    imposed_status worker "$ID" 2030-01-02T03:04Z
    FM_IMPOSED_HOLD_SCAN_SECS="$value" bash -c '
      . "$1/bin/fm-watch.sh"
      imposed_hold_expiry_tick "$(($2 - 1))"
      imposed_hold_expiry_tick "$2"
      [ ! -s "$FM_WAKE_QUEUE" ] || exit 1
      imposed_hold_expiry_tick "$(($2 + 60))"
      [ -s "$FM_WAKE_QUEUE" ]
    ' _ "$ROOT" "$U" || fail "invalid interval $value did not fall back to sixty seconds"
  done
  pass "invalid scan settings fall back to sixty seconds"
}

test_early_renewal_and_release_never_wake() {
  reset_case
  imposed_status worker "$ID" 2030-01-02T03:04Z
  printf '%s\n' "$(status_hold_imposed_line "$ID2" 2030-01-02T04:04Z 'renew before lapse')" >> "$STATE/worker.status"
  imposed_hold_expiry_tick "$U"
  [ "$(count_wakes)" = 0 ] || fail "superseded hold woke at its old expiry"
  printf '%s\n' "$(status_hold_release_line "$ID2" 'resume before lapse')" >> "$STATE/worker.status"
  imposed_hold_expiry_tick $((U + 4000))
  [ "$(count_wakes)" = 0 ] || fail "early-released hold woke"
  pass "renewing and releasing before expiry suppress the old alarm"
}

test_queued_wake_covers_missing_marker() {
  reset_case
  imposed_status worker "$ID" 2030-01-02T03:04Z
  imposed_hold_expiry_tick "$U"
  rm -f "$STATE/.imposed-hold-woke-worker"
  imposed_hold_expiry_tick $((U + 61))
  [ "$(count_wakes)" = 1 ] || fail "missing marker duplicated an already-queued wake"
  pass "an already-queued wake repairs a missing dedup marker"
}

test_two_lapsed_holds_wake_one_at_a_time() {
  reset_case
  imposed_status a-worker "$ID" 2030-01-02T03:04Z
  imposed_status z-worker "$ID2" 2030-01-02T02:04Z
  imposed_hold_expiry_tick $((U + 61))
  [ "$(count_wakes)" = 1 ] || fail "both lapsed holds woke in one cycle"
  printf '%s' "$IMPOSED_HOLD_EXPIRY" | grep -F 'z-worker' >/dev/null \
    || fail "the earliest lapse did not go first: $IMPOSED_HOLD_EXPIRY"
  imposed_hold_expiry_tick $((U + 130))
  [ "$(count_wakes)" = 2 ] || fail "the second lapsed hold never woke"
  printf '%s' "$IMPOSED_HOLD_EXPIRY" | grep -F 'a-worker' >/dev/null \
    || fail "second wake named the wrong task: $IMPOSED_HOLD_EXPIRY"
  pass "one wake per cycle, earliest lapse first"
}

# The tick hands the fold only the lines that can open or close a hold. A hold
# and its release must read the same wherever they sit in a long log, through
# a binary line, and the narrowed copy must not outlive the pass.
test_hold_buried_in_a_long_log_reads_the_same() {
  local i
  reset_case
  {
    for i in $(seq 1 400); do printf 'working [at=%s]: step %s of imposed-holding the door\n' "$i" "$i"; done
    printf 'working [at=401]: binary \0 payload\n'
    printf 'paused [hold=firstmate] [at=1000] [key=imposed-hold-%s]: imposed-hold-%s: hold until 2030-01-02T03:04Z\n' \
      "$ID" "$ID"
    for i in $(seq 1 400); do printf 'working [at=%s]: later step %s\n' "$((1000 + i))" "$i"; done
  } > "$STATE/worker.status"
  for i in $(seq 1 400); do printf 'working [at=%s]: no hold was ever imposed here\n' "$i"; done \
    > "$STATE/bystander.status"
  imposed_hold_expiry_tick $((U - 1))
  [ "$(count_wakes)" = 0 ] || fail "a buried hold inside its window queued a wake"
  imposed_hold_expiry_tick $((U + 60))
  [ "$(count_wakes)" = 1 ] || fail "a lapsed hold buried in a long log did not wake"
  printf '%s' "$IMPOSED_HOLD_EXPIRY" | grep -F "worker hold imposed-hold-$ID" >/dev/null \
    || fail "buried hold wake named the wrong hold: $IMPOSED_HOLD_EXPIRY"
  printf 'resolved [at=%s] [key=imposed-hold-%s]: imposed-hold-%s: released by firstmate: resume\n' \
    "$((U + 61))" "$ID" "$ID" >> "$STATE/worker.status"
  for i in $(seq 1 50); do printf 'working [at=%s]: after release %s\n' "$((U + 61 + i))" "$i"; done \
    >> "$STATE/worker.status"
  imposed_hold_expiry_tick $((U + 200))
  [ "$(count_wakes)" = 1 ] || fail "a buried release still woke"
  [ ! -e "$STATE/.imposed-hold-woke-worker" ] || fail "a buried release left the wake marker behind"
  set -- "$STATE"/.imposed-holds-lines.*
  [ ! -e "$1" ] || fail "the pass left its narrowed copy behind: $1"
  pass "a hold and its release read the same when buried in a long log"
}

fm_test_run \
  test_not_due_is_silent \
  test_lapse_queues_exactly_one_wake \
  test_marker_not_queue_row_ends_the_episode \
  test_renewal_re_arms \
  test_release_is_silent_and_cleans_up \
  test_never_wakes_crew_or_captain_records \
  test_unparseable_until_fails_safe \
  test_scan_cadence_bounds_the_pass \
  test_invalid_scan_settings_fall_back \
  test_early_renewal_and_release_never_wake \
  test_queued_wake_covers_missing_marker \
  test_two_lapsed_holds_wake_one_at_a_time \
  test_hold_buried_in_a_long_log_reads_the_same
