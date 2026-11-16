#!/usr/bin/env bash
# Behavior tests for config/procevent-failure-wakes: quiet handling for a
# process-event source that keeps failing to start.
#
# A source fails to start here because its registration is damaged in place,
# which keeps its registration identity fixed, and starts again when the
# registration is repaired. Every assertion reads the public wake queue, the
# watcher's headline, or the fleet view.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-procevent-failure-wakes-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"

SOURCE_CMD="$TMP_ROOT/source.sh"
cat > "$SOURCE_CMD" <<'SH'
#!/usr/bin/env bash
printf 'result\n'
SH
chmod +x "$SOURCE_CMD"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# new_source <home> <source-id> [config-line...]: register a source in a fresh
# home. With no config line the home has no config/procevent-failure-wakes;
# a single "-" writes an empty file.
new_source() {
  local home=$1 id=$2 line
  shift 2
  mkdir -p "$home/state" "$home/config"
  if [ "$#" -gt 0 ]; then
    : > "$home/config/procevent-failure-wakes"
    for line in "$@"; do
      [ "$line" = - ] || printf '%s\n' "$line" >> "$home/config/procevent-failure-wakes"
    done
  fi
  fm_test_track_procevent_home "$home"
  pe "$home" register lavish "$id" -- "$SOURCE_CMD" >/dev/null || fail "could not register $id"
  cp "$home/state/procevent/$id.source" "$home/good.source"
  awk '/^argv:$/ { print; exit } { print }' "$home/good.source" > "$home/bad-argv.source"
  sed 's/^adapter=.*/adapter=Not_An_Adapter!/' "$home/good.source" > "$home/bad-adapter.source"
}

# The registration file is rewritten in place, so its identity and therefore
# its failure episode never change on their own.
damage() { cat "$1/bad-argv.source" > "$1/state/procevent/$2.source"; }
damage_adapter() { cat "$1/bad-adapter.source" > "$1/state/procevent/$2.source"; }
repair() { cat "$1/good.source" > "$1/state/procevent/$2.source"; }

# A failing launch always waits out the whole confirm window, so failing
# cycles use a short one. A repaired launch ends its window on the first
# evidence, so it gets a long one that a loaded host cannot outrun. A
# scenario that needs the runner's refusal reason sets FAIL_CONFIRM_SECONDS,
# because a refusal that lands after the window is not attributed to it.
reconcile() {  # <home>
  FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=${FAIL_CONFIRM_SECONDS:-1} pe "$1" reconcile 2>/dev/null || true
}
reconcile_repaired() {  # <home>
  local out
  out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=30 pe "$1" reconcile 2>/dev/null) || true
  case "$out" in *"failed=0"*) ;; *) fail "a repaired source did not start: $out" ;; esac
}

# A confirmed runner runs its source and exits; the next damaged launch must
# not find the source still owned by a live runner. A runner that exits while
# reconcile's confirm loop holds the source lock leaves its claim behind by
# design, for the next reconcile to reclaim, so a claim whose recorded owner
# (pid plus process identity, as the claim records it) is gone also counts.
wait_released() {  # <source-id>
  local _ claim="$FM_PROCEVENT_CLAIM_ROOT/$1.claim" pid identity
  for _ in $(seq 1 600); do
    [ -e "$claim" ] || return 0
    { IFS= read -r _ && IFS= read -r pid && IFS= read -r _ && IFS= read -r identity; } < "$claim" 2>/dev/null \
      && [ "$(owner_identity "$pid")" != "$identity" ] && return 0
    sleep 0.1
  done
  fail "the runner for $1 never released its claim"
}
owner_identity() {  # <pid>: the identity a claim records for a live pid, empty once it is gone
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$1" 2>/dev/null || true
}

wake_keys() {  # <home> <source-id> <kind>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v prefix="procevent:$2:$3:" \
    '$3 == "check" && index($4, prefix) == 1 { print $4 }' "$1/state/.wake-queue"
}
wake_count() { wake_keys "$@" | grep -c . || true; }
wake_payloads() {  # <home> <source-id> <kind>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v prefix="procevent:$2:$3:" \
    '$3 == "check" && index($4, prefix) == 1 { print $5 }' "$1/state/.wake-queue"
}

expect_wakes() {  # <home> <source-id> <failed> <recovered> <message>
  local failed recovered
  failed=$(wake_count "$1" "$2" launch-failed)
  recovered=$(wake_count "$1" "$2" launch-recovered)
  [ "$failed" = "$3" ] && [ "$recovered" = "$4" ] \
    || fail "$5: expected $3 failure and $4 recovery wakes, got $failed and $recovered"
}

# Repeat a failing cycle until the launch-failed wake count reaches <want>,
# because the reason a runner leaves can land just after one confirm window.
reconcile_until_failed_wakes() {  # <home> <source-id> <want>
  local _
  for _ in 1 2 3; do
    reconcile "$1" >/dev/null
    [ "$(wake_count "$1" "$2" launch-failed)" -lt "$3" ] || return 0
  done
  return 1
}

surface() {  # <home>: print the watcher headline for queued process-event wakes
  FM_HOME="$1" bash -c '. "$1/bin/fm-watch.sh"; procevent_surface_queued' _ "$ROOT"
}

fleet_view() { FM_HOME="$1" "$ROOT/bin/fm-fleet-view.sh" 2>/dev/null; }

# The shared failing sequence: two episodes of the same failure inside one
# window, each followed by a repair.
flapping_sequence() {  # <home> <source-id>
  damage "$1" "$2"
  reconcile "$1" >/dev/null
  reconcile "$1" >/dev/null
  repair "$1" "$2"
  reconcile_repaired "$1"
  wait_released "$2"
  damage "$1" "$2"
  reconcile "$1" >/dev/null
  repair "$1" "$2"
  reconcile_repaired "$1"
  wait_released "$2"
}

scenario_off_path_unchanged() {
  local home="$TMP_ROOT/off"
  new_source "$home" off-src
  flapping_sequence "$home" off-src
  # Today's rule: one wake per failure episode, and none on recovery.
  expect_wakes "$home" off-src 2 0 "with no config file the episode rule changed"
  assert_absent "$home/state/procevent/.off-src.failure-quiet" "the off path wrote a quiet record"
  assert_absent "$home/state/procevent/.off-src.launch-refusal" "the off path recorded a runner refusal"
  assert_absent "$home/state/procevent/.failure-quiet.log" "the off path wrote the quiet log"
  assert_not_contains "$(fleet_view "$home")" "Quiet Process-Event Failures" \
    "the off path changed the fleet view"
  FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json | jq -e 'has("procevent_failure_quiet") | not' >/dev/null \
    || fail "the off path added a field to the fleet snapshot"
  pe "$home" retire off-src >/dev/null 2>&1 || true
}

scenario_first_failure_wakes() {
  local home="$TMP_ROOT/first"
  new_source "$home" first-src -
  damage "$home" first-src
  reconcile_until_failed_wakes "$home" first-src 1 || fail "the first failure did not wake"
  expect_wakes "$home" first-src 1 0 "the first failure"
  assert_contains "$(surface "$home")" "process-event source failed to start: procevent:first-src:launch-failed:" \
    "the first failure lost its headline"
  repair "$home" first-src
  pe "$home" retire first-src >/dev/null 2>&1 || true
}

scenario_repeat_inside_window_and_recovery() {
  local home="$TMP_ROOT/repeat" payload view
  new_source "$home" repeat-src -
  flapping_sequence "$home" repeat-src
  # One failure wake, then one recovery wake for the failure counted after
  # it; the second episode and its recovery stay quiet inside the window.
  expect_wakes "$home" repeat-src 1 1 "repeats inside the window"
  payload=$(wake_payloads "$home" repeat-src launch-recovered)
  assert_contains "$payload" "process-event source repeat-src started again after 1 further failed launches" \
    "the recovery wake does not carry the held-back count: $payload"
  assert_contains "$(surface "$home")" "process-event source started again: procevent:repeat-src:launch-recovered:" \
    "the recovery wake lost its headline"
  # The failure after the recovery wake is counted, not dropped.
  damage "$home" repeat-src
  reconcile "$home" >/dev/null
  expect_wakes "$home" repeat-src 1 1 "a repeat after the recovery wake"
  view=$(fleet_view "$home")
  assert_contains "$view" "## Quiet Process-Event Failures" "the fleet view hides counted failures"
  # Three failing launches after the failure wake, one since the last recovery.
  assert_contains "$view" "| repeat-src | failing | 1 | 3 |" "the fleet view does not count the held-back failures: $view"
  repair "$home" repeat-src
  pe "$home" retire repeat-src >/dev/null 2>&1 || true
  assert_absent "$home/state/procevent/.repeat-src.failure-quiet" "retire kept the quiet record"
}

scenario_repeat_after_window_wakes() {
  local home="$TMP_ROOT/after" window=30 before woke
  new_source "$home" after-src repeat-seconds=$window
  damage "$home" after-src
  # The window opens at the failure wake, so it opens no earlier than
  # <before> and no later than <woke>.
  before=$(date +%s)
  reconcile_until_failed_wakes "$home" after-src 1 || fail "the first failure did not wake"
  woke=$(date +%s)
  repair "$home" after-src
  reconcile_repaired "$home"
  [ "$(date +%s)" -lt $((before + window)) ] \
    || fail "the host was too slow to look inside a ${window}s window"
  assert_contains "$(fleet_view "$home")" "| after-src | recovered |" \
    "a recovered source left the fleet view inside its window"
  wait_released after-src
  while [ "$(date +%s)" -le $((woke + window)) ]; do sleep 1; done
  reconcile_repaired "$home"
  wait_released after-src
  assert_contains "$(fleet_view "$home")" "No process-event failures are being counted without a wake." \
    "a recovered source stayed in the fleet view after its window"
  damage "$home" after-src
  reconcile "$home" >/dev/null
  expect_wakes "$home" after-src 2 0 "a new failure after the window"
  repair "$home" after-src
  pe "$home" retire after-src >/dev/null 2>&1 || true
}

scenario_different_reason_wakes() {
  local home="$TMP_ROOT/reason" FAIL_CONFIRM_SECONDS=5 reason
  new_source "$home" reason-src -
  damage "$home" reason-src
  reconcile_until_failed_wakes "$home" reason-src 1 || fail "the first failure did not wake"
  # Make sure the first reason is the argv refusal before changing it.
  reconcile "$home" >/dev/null
  expect_wakes "$home" reason-src 1 0 "the same reason again"
  reason=$(FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json \
    | jq -r '.procevent_failure_quiet[] | select(.source == "reason-src") | .reason')
  case "$reason" in launch-refused-*) ;; *) fail "the first failure was not the runner's refusal: $reason" ;; esac
  damage_adapter "$home" reason-src
  reconcile_until_failed_wakes "$home" reason-src 2 \
    || fail "a different failure reason for the same source did not wake"
  repair "$home" reason-src
  pe "$home" retire reason-src >/dev/null 2>&1 || true
}

scenario_recovered_wake_off() {
  local home="$TMP_ROOT/norecover" view
  new_source "$home" norecover-src recovered-wake=off
  flapping_sequence "$home" norecover-src
  expect_wakes "$home" norecover-src 1 0 "recovered-wake=off"
  # Two failing launches were held back after the one failure wake, and no
  # wake reported them, so the fleet view still does after the recovery.
  view=$(fleet_view "$home")
  assert_contains "$view" "| norecover-src | recovered | 0 | 2 |" \
    "the fleet view dropped the held-back failures on recovery: $view"
  pe "$home" retire norecover-src >/dev/null 2>&1 || true
}

scenario_malformed_config_keeps_defaults() {
  local home="$TMP_ROOT/malformed"
  new_source "$home" malformed-src 'repeat-seconds=0' 'repeat-seconds=abc' 'repeat-seconds=12345678901' \
    'recovered-wake=maybe' 'not a setting' '# comment' 'repeat-seconds=1=2'
  flapping_sequence "$home" malformed-src
  # Defaults: a 3600-second window and a recovery wake.
  expect_wakes "$home" malformed-src 1 1 "a malformed config"
  pe "$home" retire malformed-src >/dev/null 2>&1 || true
}

# Every scenario has its own home and source id, and a failing launch spends
# most of its time inside the confirm window, so the scenarios run at once and
# each test below reports its own scenario's result.
SCENARIOS="off_path_unchanged first_failure_wakes repeat_inside_window_and_recovery repeat_after_window_wakes different_reason_wakes recovered_wake_off malformed_config_keeps_defaults"
for scenario in $SCENARIOS; do
  ( "scenario_$scenario" ) > "$TMP_ROOT/$scenario.out" 2>&1 &
  printf '%s\n' "$!" > "$TMP_ROOT/$scenario.pid"
done

report() {  # <scenario> <pass-message>
  local rc=0
  wait "$(cat "$TMP_ROOT/$1.pid")" || rc=$?
  [ "$rc" -eq 0 ] || fail "$1: $(cat "$TMP_ROOT/$1.out")"
  pass "$2"
}

test_off_path_unchanged() { report off_path_unchanged "with no config file, failure wakes and the fleet view are unchanged"; }
test_first_failure_wakes() { report first_failure_wakes "the first failure of a source wakes at once"; }
test_repeat_inside_window_and_recovery() { report repeat_inside_window_and_recovery "repeats inside the window are counted without a wake, and recovery wakes once with the count"; }
test_repeat_after_window_wakes() { report repeat_after_window_wakes "a failure after the window wakes again"; }
test_different_reason_wakes() { report different_reason_wakes "a failure with a different reason wakes at once inside the window"; }
test_recovered_wake_off() { report recovered_wake_off "recovered-wake=off sends no recovery wake and still holds repeats back"; }
test_malformed_config_keeps_defaults() { report malformed_config_keeps_defaults "a malformed config keeps the defaults"; }

fm_test_run \
  test_off_path_unchanged \
  test_first_failure_wakes \
  test_repeat_inside_window_and_recovery \
  test_repeat_after_window_wakes \
  test_different_reason_wakes \
  test_recovered_wake_off \
  test_malformed_config_keeps_defaults
