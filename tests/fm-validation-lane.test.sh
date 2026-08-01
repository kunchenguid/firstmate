#!/usr/bin/env bash
# Behavior tests for the home-local no-mistakes validation lane.
#
# These cases execute the public scheduler and its generated watcher check in
# disposable state directories.  Delivery and crew-state reads are fixture
# binaries, so they never attach to a live runtime or start a validation run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LANE="$ROOT/bin/fm-validation-lane.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-lane)
PRIOR_START='2026-08-01T12:00#1'
NEXT_START='2026-08-01T12:00#2'

make_case() {
  local name=$1 dir
  dir=$TMP_ROOT/$name
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  : > "$dir/send.log"
  cat > "$dir/fakebin/send" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "${*:2}" >> "$FM_TEST_SEND_LOG"
[ -z "${FM_TEST_SEND_DELAY:-}" ] || sleep "$FM_TEST_SEND_DELAY"
printf '%s\n' "${FM_TEST_SEND_OUTPUT:-}"
exit "${FM_TEST_SEND_RC:-0}"
SH
cat > "$dir/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_CREW_STATE_RC:-0}" -ne 0 ]; then
  printf '%s\n' "${FM_TEST_CREW_STATE_ERROR:-fixture crew-state failure}" >&2
  exit "$FM_TEST_CREW_STATE_RC"
fi
line=${FM_TEST_CREW_STATE:-state: done · source: run-step · prior validation}
if [ "${1:-}" = --validation-lane ]; then
  state=${line#state: }
  state=${state%% ·*}
  source=${line#*source: }
  source=${source%% ·*}
  if [ "$source" = run-step ]; then
    kind=${FM_TEST_CREW_RUN_KIND:-full}
  else
    kind=${FM_TEST_CREW_RUN_KIND:-absent}
  fi
  if [ "$kind" = full ]; then
    run_id=${FM_TEST_CREW_RUN_ID:-prior}
  else
    run_id=
  fi
  if [ "${FM_TEST_CREW_RUN_START+x}" = x ]; then
    run_start=$FM_TEST_CREW_RUN_START
  elif [ "$source" = run-step ]; then
    run_start=2026-08-01T12:00#1
  else
    run_start=
  fi
  printf 'fm-crew-validation-v2\nstate=%s\nsource=%s\nrun-kind=%s\nrun-id=%s\nrun-start=%s\n' \
    "$state" "$source" "$kind" "$run_id" "$run_start"
else
  printf '%s\n' "$line"
fi
SH
  cat > "$dir/fakebin/register" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_REGISTER_RC:-0}" -ne 0 ]; then
  exit "$FM_TEST_REGISTER_RC"
fi
exec "$FM_TEST_REGISTER_REAL" "$@"
SH
  chmod +x "$dir/fakebin/send" "$dir/fakebin/crew-state" "$dir/fakebin/register"
  printf '%s\n' "$dir"
}

run_lane() {  # <case-dir> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_VALIDATION_LANE_REGISTER_BIN="$dir/fakebin/register" \
    FM_TEST_REGISTER_REAL="$ROOT/bin/fm-check-register.sh" \
    FM_TEST_SEND_LOG="$dir/send.log" "$LANE" "$@"
}

hash_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

owner_state() {  # <holder|release> <task> <kind> <run-id|none> <run-start|none> <state> <started> [queued...]
  local owner=$1 task=$2 kind=$3 run_id=$4 run_start=$5 state=$6 started=$7 queued token=none start_token=none
  shift 7
  [ "$kind" != full ] || token=$(hash_text "$run_id")
  [ "$run_start" = none ] || start_token=$(hash_text "$run_start")
  printf 'fm-validation-lane-v2\n%s=%s\n' "$owner" "$task"
  printf 'reservation-kind=%s\nreservation-run=%s\n' "$kind" "$token"
  printf 'reservation-start=%s\n' "$start_token"
  printf 'reservation-state=%s\nreservation-started=%s\n' "$state" "$started"
  for queued in "$@"; do
    printf 'queued=%s\n' "$queued"
  done
}

assert_state() {  # <case-dir> <expected-content> <message>
  local actual
  actual=$(cat "$1/home/state/validation-lane" 2>/dev/null || true)
  [ "$actual" = "$2" ] || fail "$3 (got: $actual)"
}

test_enqueue_reserves_and_delivers_first_task() {
  local dir out
  dir=$(make_case first)
  out=$(run_lane "$dir" enqueue alpha)
  assert_contains "$out" "released alpha" "first enqueue did not release alpha"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0)" "first task was not recorded as holder"
  [ -x "$dir/home/state/validation-lane.check.sh" ] || fail "watcher check was not installed"
  [ -f "$dir/home/state/validation-lane.check-trust" ] || fail "watcher check was not registered"
  assert_contains "$(cat "$dir/send.log")" "alpha|Validation slot reserved." "release did not use the send boundary"
  pass "validation lane: first enqueue reserves and delivers through registered watcher state"
}

test_queue_is_fifo_and_terminal_check_releases_next() {
  local dir out
  dir=$(make_case fifo)
  run_lane "$dir" enqueue alpha >/dev/null
  out=$(run_lane "$dir" enqueue beta)
  assert_contains "$out" "queued beta" "second task was not queued"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0 beta)" "queue did not preserve alpha then beta"
  FM_TEST_CREW_STATE='state: working · source: run-step · validating' \
    FM_TEST_CREW_RUN_ID=run-alpha FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check > "$dir/check-working.out"
  [ ! -s "$dir/check-working.out" ] || fail "working holder released its slot"
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green' \
    FM_TEST_CREW_RUN_ID=run-alpha FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check > "$dir/check-terminal.out"
  assert_contains "$(cat "$dir/check-terminal.out")" "released beta" "terminal holder did not release beta"
  assert_state "$dir" "$(owner_state holder beta full run-alpha "$NEXT_START" terminal 0)" "beta was not promoted from the FIFO queue"
  [ "$(wc -l < "$dir/send.log" | tr -d '[:space:]')" = 2 ] || fail "release delivered an unexpected number of messages"
  pass "validation lane: queued work releases in FIFO order only after a terminal run-step"
}

test_status_log_terminal_does_not_free_a_slot() {
  local dir
  dir=$(make_case status-log)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  FM_TEST_CREW_STATE='state: done · source: status-log · stale event' run_lane "$dir" check > "$dir/check.out"
  [ ! -s "$dir/check.out" ] || fail "status-log terminal result released its slot"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0 beta)" "status-log result changed validation ownership"
  pass "validation lane: only an authoritative run-step terminal result frees a slot"
}

test_empty_lane_retires_its_watcher_artifacts() {
  local dir
  dir=$(make_case retire)
  run_lane "$dir" enqueue alpha >/dev/null
  FM_TEST_CREW_STATE='state: done · source: run-step · checks green' \
    FM_TEST_CREW_RUN_ID=run-alpha run_lane "$dir" check > "$dir/check.out"
  [ ! -e "$dir/home/state/validation-lane" ] || fail "empty lane state was not retired"
  [ ! -e "$dir/home/state/validation-lane.check.sh" ] || fail "empty lane check was not retired"
  [ ! -e "$dir/home/state/validation-lane.check-trust" ] || fail "empty lane trust was not retired"
  pass "validation lane: an empty lane retires its watcher artifacts"
}

test_failed_delivery_remains_pending_and_is_retried() {
  local dir out
  dir=$(make_case retry)
  FM_TEST_SEND_RC=7 FM_TEST_SEND_OUTPUT='fixture transport down' run_lane "$dir" enqueue alpha > "$dir/enqueue.out"
  out=$(cat "$dir/enqueue.out")
  assert_contains "$out" "release failed for alpha: fixture transport down" "failed delivery was not loud"
  assert_state "$dir" "$(owner_state release alpha full prior "$PRIOR_START" terminal 0)" "failed delivery lost its durable release reservation"
  FM_TEST_SEND_RC=7 FM_TEST_SEND_OUTPUT='fixture transport down' run_lane "$dir" enqueue beta >/dev/null
  assert_state "$dir" "$(owner_state release alpha full prior "$PRIOR_START" terminal 0 beta)" "failed head was skipped when beta queued"
  out=$(run_lane "$dir" check)
  assert_contains "$out" "released alpha" "pending release was not retried"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0 beta)" "retry did not retain FIFO ordering"
  pass "validation lane: failed delivery stays loud and preserves the queue head for retry"
}

test_generated_check_executes_scheduler_without_live_runtime() {
  local dir out
  dir=$(make_case generated-check)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_TEST_SEND_LOG="$dir/send.log" \
    FM_TEST_CREW_STATE='state: failed · source: run-step · validation failed' \
    FM_TEST_CREW_RUN_ID=run-alpha FM_TEST_CREW_RUN_START="$NEXT_START" \
    "$dir/home/state/validation-lane.check.sh")
  assert_contains "$out" "released beta" "generated watcher check did not release the next task"
  assert_state "$dir" "$(owner_state holder beta full run-alpha "$NEXT_START" terminal 0)" "generated watcher check did not commit beta as holder"
  pass "validation lane: registered watcher check releases a terminal holder through fixture transport"
}

test_terminal_status_event_releases_and_queues_a_wake() {
  local dir out status drained
  dir=$(make_case watcher)
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$dir/home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$dir/home/state/.pr-check-migration-v1"
  chmod 0600 "$dir/home/state/.pr-check-migration-scan-v1" "$dir/home/state/.pr-check-migration-v1"
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  touch "$dir/home/state/.last-check"
  printf 'done: implementation complete\n' > "$dir/home/state/alpha.status"
  status=0
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_TEST_SEND_LOG="$dir/send.log" \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green' \
    FM_TEST_CREW_RUN_ID=run-alpha FM_TEST_CREW_RUN_START="$NEXT_START" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 5 > "$dir/checkpoint.out" 2> "$dir/checkpoint.err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  out=$(cat "$dir/checkpoint.out")
  assert_contains "$out" "check: $dir/home/state/validation-lane.check.sh: released beta" "watcher did not surface validation release"
  assert_state "$dir" "$(owner_state holder beta full run-alpha "$NEXT_START" terminal 0)" "watcher check did not commit beta as holder"
  drained=$(FM_HOME="$dir/home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tcheck\t' "watcher release wake was not queued"
  assert_contains "$drained" 'released beta' "queued watcher wake lost release diagnostic"
  pass "validation lane: terminal status event runs the authenticated release check"
}

test_terminal_status_event_surfaces_and_retries_lane_failure() {
  local dir out status drained
  dir=$(make_case watcher-failure)
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$dir/home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$dir/home/state/.pr-check-migration-v1"
  chmod 0600 "$dir/home/state/.pr-check-migration-scan-v1" "$dir/home/state/.pr-check-migration-v1"
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  touch "$dir/home/state/.last-check"
  printf 'done: implementation complete\n' > "$dir/home/state/alpha.status"
  status=0
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_TEST_SEND_LOG="$dir/send.log" FM_TEST_CREW_STATE_RC=7 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 5 > "$dir/failed.out" 2> "$dir/failed.err" || status=$?
  expect_code 0 "$status" "failing lane event checkpoint exit"
  out=$(cat "$dir/failed.out")
  assert_contains "$out" \
    "check: $dir/home/state/validation-lane.check.sh failed (exit 1): validation-lane: cannot read reservation state for alpha" \
    "watcher did not surface the lane check failure"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0 beta)" \
    "lane check failure changed validation ownership"
  [ ! -e "$dir/home/state/.seen-alpha_status" ] || fail "lane check failure consumed its retry signal"
  drained=$(FM_HOME="$dir/home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tcheck\t' "lane check failure wake was not queued"
  assert_contains "$drained" 'cannot read reservation state for alpha' \
    "lane check failure wake lost its diagnostic"
  status=0
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_TEST_SEND_LOG="$dir/send.log" \
    FM_TEST_CREW_STATE='state: done · source: run-step · checks green' \
    FM_TEST_CREW_RUN_ID=run-alpha FM_TEST_CREW_RUN_START="$NEXT_START" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 5 > "$dir/retry.out" 2> "$dir/retry.err" || status=$?
  expect_code 0 "$status" "retried lane event checkpoint exit"
  assert_contains "$(cat "$dir/retry.out")" "released beta" \
    "unconsumed terminal event did not retry the lane check"
  assert_state "$dir" "$(owner_state holder beta full run-alpha "$NEXT_START" terminal 0)" \
    "retried lane check did not transfer validation ownership"
  pass "validation lane: terminal event failures stay loud and retryable"
}

test_periodic_lane_failure_is_loud() {
  local dir out status
  dir=$(make_case periodic-failure)
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$dir/home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$dir/home/state/.pr-check-migration-v1"
  chmod 0600 "$dir/home/state/.pr-check-migration-scan-v1" "$dir/home/state/.pr-check-migration-v1"
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  status=0
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_VALIDATION_LANE_SEND_BIN="$dir/fakebin/send" \
    FM_VALIDATION_LANE_CREW_STATE_BIN="$dir/fakebin/crew-state" \
    FM_TEST_SEND_LOG="$dir/send.log" FM_TEST_CREW_STATE_RC=7 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds 5 > "$dir/checkpoint.out" 2> "$dir/checkpoint.err" || status=$?
  expect_code 0 "$status" "failing periodic lane checkpoint exit"
  out=$(cat "$dir/checkpoint.out")
  assert_contains "$out" \
    "check: $dir/home/state/validation-lane.check.sh failed (exit 1): validation-lane: cannot read reservation state for alpha" \
    "periodic lane failure was silent"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0 beta)" \
    "periodic lane failure changed validation ownership"
  pass "validation lane: periodic check failures stay loud"
}

test_prior_terminal_run_cannot_clear_a_new_reservation() {
  local dir out
  dir=$(make_case stale-terminal)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  out=$(run_lane "$dir" check)
  [ -z "$out" ] || fail "prior terminal run released a new reservation"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0 beta)" "prior terminal run changed the lane"
  out=$(FM_TEST_CREW_RUN_ID=new-run FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check)
  assert_contains "$out" "released beta" "new terminal run identity did not release the next task"
  assert_state "$dir" "$(owner_state holder beta full new-run "$NEXT_START" terminal 0)" "new run did not transfer the slot"
  pass "validation lane: completion is bound to a post-reservation run identity"
}

test_same_run_state_changes_do_not_start_reservation() {
  local dir out
  dir=$(make_case same-run-state)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  FM_TEST_CREW_STATE='state: working · source: run-step · validating' \
    run_lane "$dir" check > "$dir/working.out"
  [ ! -s "$dir/working.out" ] || fail "same run working state released the reservation"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0 beta)" \
    "same run state change marked the reservation started"
  out=$(run_lane "$dir" check)
  [ -z "$out" ] || fail "same run terminal state released the reservation"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0 beta)" \
    "same run terminal state changed validation ownership"
  pass "validation lane: same run state changes cannot prove a new start"
}

test_post_reservation_transition_binds_coarse_run_completion() {
  local dir out
  dir=$(make_case transition)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  FM_TEST_CREW_STATE='state: working · source: run-step · validating' \
    FM_TEST_CREW_RUN_KIND=coarse FM_TEST_CREW_RUN_START="$NEXT_START" \
    run_lane "$dir" check > "$dir/active.out"
  [ ! -s "$dir/active.out" ] || fail "active coarse run released the slot"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 1 beta)" "post-reservation transition was not recorded"
  out=$(FM_TEST_CREW_RUN_KIND=coarse FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check)
  assert_contains "$out" "released beta" "terminal coarse transition did not release the next task"
  assert_state "$dir" "$(owner_state holder beta coarse none "$NEXT_START" terminal 0)" "coarse transition did not transfer the slot"
  pass "validation lane: post-reservation run transition binds coarse completion"
}

test_run_start_binds_coarse_completion_between_checks() {
  local dir out
  dir=$(make_case coarse-between-checks)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  out=$(FM_TEST_CREW_RUN_KIND=coarse FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check)
  assert_contains "$out" "released beta" "coarse run completed between checks did not release the next task"
  assert_state "$dir" "$(owner_state holder beta coarse none "$NEXT_START" terminal 0)" "coarse run-start evidence did not transfer the slot"
  pass "validation lane: run-start evidence binds completion between watcher checks"
}

test_run_start_binds_unavailable_completion_between_checks() {
  local dir out
  dir=$(make_case unavailable-between-checks)
  FM_TEST_CREW_RUN_KIND=unavailable run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  out=$(FM_TEST_CREW_RUN_KIND=unavailable FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check)
  assert_contains "$out" "released beta" "run with unavailable identity completed between checks did not release the next task"
  assert_state "$dir" "$(owner_state holder beta unavailable none "$NEXT_START" terminal 0)" "unavailable run-start evidence did not transfer the slot"
  pass "validation lane: run-start evidence binds unavailable completion"
}

test_absent_reservation_binds_new_unavailable_run_start() {
  local dir out
  dir=$(make_case absent-to-unavailable)
  FM_TEST_CREW_STATE='state: unknown · source: none · no run' \
    FM_TEST_CREW_RUN_KIND=absent FM_TEST_CREW_RUN_START='' run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  out=$(FM_TEST_CREW_RUN_KIND=unavailable FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check)
  assert_contains "$out" "released beta" "new unavailable run-start did not release an absent reservation"
  assert_state "$dir" "$(owner_state holder beta unavailable none "$NEXT_START" terminal 0)" "new unavailable run-start did not transfer the slot"
  pass "validation lane: absent reservation binds a new unavailable run start"
}

test_unavailable_empty_evidence_keeps_head_queued() {
  local dir status=0 out
  dir=$(make_case unavailable-empty)
  FM_TEST_CREW_RUN_KIND=unavailable FM_TEST_CREW_RUN_START='' \
    run_lane "$dir" enqueue alpha > "$dir/enqueue.out" 2> "$dir/enqueue.err" || status=$?
  expect_code 1 "$status" "unavailable empty reservation evidence"
  assert_contains "$(cat "$dir/enqueue.err")" "without comparable run evidence" "unavailable empty evidence was not diagnosed"
  assert_state "$dir" $'fm-validation-lane-v2\nqueued=alpha' "unavailable empty evidence did not retain the FIFO head"
  [ ! -s "$dir/send.log" ] || fail "unavailable empty evidence delivered the FIFO head"
  [ -f "$dir/home/state/validation-lane.check-trust" ] || fail "unavailable empty evidence did not retain its watcher"
  out=$(FM_TEST_CREW_RUN_KIND=unavailable FM_TEST_CREW_RUN_START="$PRIOR_START" run_lane "$dir" check)
  assert_contains "$out" "released alpha" "comparable evidence did not release the retained FIFO head"
  assert_state "$dir" "$(owner_state holder alpha unavailable none "$PRIOR_START" terminal 0)" "comparable evidence did not preserve reservation ownership"
  pass "validation lane: unavailable empty evidence retains the watched FIFO head"
}

test_unavailable_empty_terminal_retains_started_holder() {
  local dir out
  dir=$(make_case unavailable-empty-terminal)
  run_lane "$dir" enqueue alpha >/dev/null
  run_lane "$dir" enqueue beta >/dev/null
  FM_TEST_CREW_STATE='state: working · source: run-step · validating' \
    FM_TEST_CREW_RUN_ID=run-alpha FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check > "$dir/active.out"
  [ ! -s "$dir/active.out" ] || fail "active run released the holder"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 1 beta)" "active run was not recorded for the holder"
  out=$(FM_TEST_CREW_RUN_KIND=unavailable FM_TEST_CREW_RUN_START='' run_lane "$dir" check)
  [ -z "$out" ] || fail "unavailable empty terminal evidence released the holder"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 1 beta)" "unavailable empty terminal evidence changed the holder"
  [ "$(wc -l < "$dir/send.log" | tr -d '[:space:]')" = 1 ] || fail "unavailable empty terminal evidence sent the queued task"
  out=$(FM_TEST_CREW_RUN_KIND=unavailable FM_TEST_CREW_RUN_START="$NEXT_START" run_lane "$dir" check)
  assert_contains "$out" "released beta" "comparable terminal evidence did not release the retained holder"
  pass "validation lane: unavailable empty terminal evidence retains a started holder"
}

test_concurrent_releasers_have_one_sender() {
  local dir first_pid second_pid first_status=0 second_status=0 sends out
  dir=$(make_case one-sender)
  FM_TEST_SEND_RC=7 run_lane "$dir" enqueue alpha >/dev/null
  : > "$dir/send.log"
  FM_TEST_SEND_DELAY=0.2 run_lane "$dir" check > "$dir/first.out" &
  first_pid=$!
  FM_TEST_SEND_DELAY=0.2 run_lane "$dir" check > "$dir/second.out" &
  second_pid=$!
  wait "$first_pid" || first_status=$?
  wait "$second_pid" || second_status=$?
  expect_code 0 "$first_status" "first concurrent releaser"
  expect_code 0 "$second_status" "second concurrent releaser"
  sends=$(wc -l < "$dir/send.log" | tr -d '[:space:]')
  [ "$sends" = 1 ] || fail "concurrent release sent $sends messages"
  out=$(cat "$dir/first.out" "$dir/second.out")
  [ "$(printf '%s\n' "$out" | grep -c '^released alpha$')" = 1 ] || fail "concurrent release reported multiple senders"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0)" "concurrent release corrupted ownership"
  pass "validation lane: concurrent releasers serialize one sender"
}

test_duplicate_enqueue_repairs_registration_and_pending_delivery() {
  local dir status=0 out
  dir=$(make_case registration-retry)
  FM_TEST_REGISTER_RC=9 run_lane "$dir" enqueue alpha > "$dir/first.out" 2> "$dir/first.err" || status=$?
  expect_code 1 "$status" "transient registration failure"
  assert_state "$dir" "$(owner_state release alpha full prior "$PRIOR_START" terminal 0)" "registration failure lost the reservation"
  [ ! -s "$dir/send.log" ] || fail "registration failure delivered before the watcher was repaired"
  out=$(run_lane "$dir" enqueue alpha)
  assert_contains "$out" "released alpha" "duplicate enqueue did not resume pending delivery"
  [ -f "$dir/home/state/validation-lane.check-trust" ] || fail "duplicate enqueue did not repair watcher registration"
  assert_state "$dir" "$(owner_state holder alpha full prior "$PRIOR_START" terminal 0)" "registration retry did not commit the holder"
  pass "validation lane: duplicate enqueue repairs registration and resumes release"
}

test_enqueue_reserves_and_delivers_first_task
test_queue_is_fifo_and_terminal_check_releases_next
test_status_log_terminal_does_not_free_a_slot
test_empty_lane_retires_its_watcher_artifacts
test_failed_delivery_remains_pending_and_is_retried
test_generated_check_executes_scheduler_without_live_runtime
test_terminal_status_event_releases_and_queues_a_wake
test_terminal_status_event_surfaces_and_retries_lane_failure
test_periodic_lane_failure_is_loud
test_prior_terminal_run_cannot_clear_a_new_reservation
test_same_run_state_changes_do_not_start_reservation
test_post_reservation_transition_binds_coarse_run_completion
test_run_start_binds_coarse_completion_between_checks
test_run_start_binds_unavailable_completion_between_checks
test_absent_reservation_binds_new_unavailable_run_start
test_unavailable_empty_evidence_keeps_head_queued
test_unavailable_empty_terminal_retains_started_holder
test_concurrent_releasers_have_one_sender
test_duplicate_enqueue_repairs_registration_and_pending_delivery
