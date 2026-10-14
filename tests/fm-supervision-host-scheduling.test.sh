#!/usr/bin/env bash
# Behavior tests for scheduling across long supervision-host and main turns.
# Runs the real host, arm, watcher, and hook with the shared fake harness.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-fixture.sh"

# --- scheduled checks keep running while main owns the turn -------------------
#
# The live gap (2026-10-13): a scheduled alert reached its check 16m54s late
# because the successor cycle a main-only pass-through leaves for main closed on
# the next event and nothing restarted it until main's turn ended. The arm that
# owns that cycle now restarts its own watcher after a close nobody is waiting
# on (bin/fm-watch-arm.sh, "Scheduling continuation"), so completed check
# sweeps carry on while the events stay queued for main.

test_scheduled_checks_continue_while_main_owns_repeated_closes() {
  local home n saved left_arm drained
  home=$(make_primary_home hook-sched-main-turn)
  register_sweep_check "$home"
  saved=$FM_CHECK_INTERVAL
  export FM_CHECK_INTERVAL=1
  start_hook_session "$home"
  export FM_CHECK_INTERVAL=$saved
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "scheduled checks: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  wait_until 150 sweeps_reach "$home" 2 || fail "scheduled checks: the parked cycle never swept its check"
  : > "$home/emit.1"
  wait_until 250 hook_exited "$home" || fail "scheduled checks: the first event never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "scheduled checks (first close)"
  assert_re '	pass-through	attended	main-only	check:' "$home/state/.supervision-host.log" "fixture: the first event was not a main-only pass-through"
  # Main is now in its long turn and drains nothing. Three more events close
  # the cycle in turn, each leaving earlier ones still queued for main.
  for n in 2 3 4; do
    emit_and_expect_sweeps "$home" "$n" "scheduled checks"
  done
  [ "$(max_sweep_gap "$home" 1)" -le "$SWEEP_GAP_BOUND" ] \
    || fail "scheduled checks: sweeps were $(max_sweep_gap "$home" 1)s apart, past the ${SWEEP_GAP_BOUND}s bound: $(cat "$home/sweeps" | tr '\n' ' ')"
  [ "$(home_watchers "$home")" -eq 1 ] || fail "scheduled checks: more than one watcher runs"
  left_arm=$(parent_of "$(cat "$home/state/.watch.lock/pid")")
  for n in 1 2 3 4; do
    [ "$(grep -c "fixture-event-$n\$" "$home/state/.wake-queue")" -eq 1 ] \
      || fail "scheduled checks: event $n is not queued exactly once for main:"$'\n'"$(cat "$home/state/.wake-queue")"
  done
  # The supported handoff: main's turn ends and the next park takes the cycle over.
  turn_end "$home"
  wait_until 250 hook_exited "$home" || fail "scheduled checks: the handoff never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "scheduled checks (handoff)"
  assert_re "	take-over	arm=$left_arm\$" "$home/state/.supervision-host.log" "scheduled checks: the park did not take over the continuing arm"
  main_drain "$home" > "$home/drain.out"
  drained=$(cat "$home/drain.out")
  assert_contains "$drained" 'fixture-event-4' "scheduled checks: the newest event must reach main's drain"
  assert_contains "$MAIN_ACK" '--ack-through 4' "scheduled checks: main's acknowledgement must cover all four queued events"
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "scheduled checks: main's acknowledgement failed: $MAIN_ACK"
  drained=$(main_drain "$home")
  [ "$(printf '%s\n' "$drained" | grep -c 'fixture-event-')" -eq 0 ] || fail "scheduled checks: an acknowledged event was delivered again:"$'\n'"$drained"
  [ "$(grep -c 'fixture-event-[1-4]$' "$home/state/.wake-queue" 2>/dev/null)" -eq 0 ] || fail "scheduled checks: an acknowledged event is still queued"
  ! kill -0 "$left_arm" 2>/dev/null || fail "scheduled checks: the taken-over arm still runs (pid $left_arm)"
  emit_and_expect_sweeps "$home" 5 "scheduled checks (after the handoff)"
  [ "$(home_watchers "$home")" -eq 1 ] || fail "scheduled checks: more than one watcher runs after the handoff"
  stop_home_processes "$home"
  pass "host+hook: check sweeps continue at cadence across repeated closes and a handoff while main owns the turn, and every event is delivered once"
}

test_scheduled_checks_continue_through_a_provider_wait() {
  local home n saved drained
  home=$(make_primary_home hook-sched-provider-wait)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  register_sweep_check "$home"
  saved=$FM_CHECK_INTERVAL
  export FM_CHECK_INTERVAL=1
  start_hook_session "$home"
  export FM_CHECK_INTERVAL=$saved
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "provider wait: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  wait_until 150 sweeps_reach "$home" 2 || fail "provider wait: the parked cycle never swept its check"
  append_status "$home" 'first actionable wake'
  wait_until 250 test -s "$home/stub-ready" || fail "provider wait: the engine did not reach its hold: $(cat "$home/state/.supervision-host.log")"
  # The engine is waiting on its provider: three events close the cycle in turn.
  for n in 1 2 3; do
    emit_and_expect_sweeps "$home" "$n" "provider wait"
    ! hook_exited "$home" || fail "provider wait: the host returned while the engine turn was held"
  done
  [ "$(max_sweep_gap "$home" 1)" -le "$SWEEP_GAP_BOUND" ] \
    || fail "provider wait: sweeps were $(max_sweep_gap "$home" 1)s apart, past the ${SWEEP_GAP_BOUND}s bound"
  [ "$(home_watchers "$home")" -eq 1 ] || fail "provider wait: more than one watcher runs"
  printf 'continue\n' > "$home/stub-release"
  wait_until 300 hook_exited "$home" || fail "provider wait: the held events never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "provider wait"
  for n in 1 2 3; do
    [ "$(grep -c "fixture-event-$n\$" "$home/state/.wake-queue")" -eq 1 ] \
      || fail "provider wait: event $n is not queued exactly once for main:"$'\n'"$(cat "$home/state/.wake-queue")"
  done
  drained=$(main_drain "$home")
  assert_contains "$drained" 'fixture-event-3' "provider wait: the newest event must reach main's drain"
  stop_home_processes "$home"
  pass "host+hook: check sweeps continue at cadence through a held engine turn, and the events that closed the cycle meanwhile are delivered once"
}

test_spool_waits_for_the_latest_successor() {
  local home spool arm saved
  home=$(make_primary_home spool-latest-successor)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "spool: no initial watcher"
  append_status "$home" 'first actionable wake'
  wait_until 250 test -s "$home/stub-ready" || fail "spool: engine did not hold: $(cat "$home/state/.supervision-host.log")"
  for spool in "$home"/state/.supervision-host-spool.*; do [ ! -f "$spool" ] || break; done
  append_status "$home" 'close one'
  wait_until 250 spool_ends_with "$spool" S || fail "spool: first successor never confirmed"
  append_status "$home" 'close two'
  wait_until 250 spool_ends_with "$spool" C || fail "spool: second close never published"
  arm=$(awk -F '\t' '$1 == "arm" { print $2 }' "$home/state/.supervision-host" | tail -1)
  kill -STOP "$arm"
  echo handle > "$home/stub-mode"
  printf 'continue\n' > "$home/stub-release"
  sleep 3
  saved=$(engine_calls "$home")
  kill -CONT "$arm"
  [ "$saved" -eq 1 ] || fail "spool: consumed an incomplete C1,S1,C2 handoff"
  wait_until 300 handled_at_least "$home" 2 || fail "spool: complete handoff was never handled"
  wait_until 200 watcher_live "$home" || fail "spool: scheduling stopped after handling"
  ! hook_exited "$home" || fail "spool: stale generation handed the batch to main"
  [ "$(home_watchers "$home")" -eq 1 ] || fail "fixture: expected exactly one scheduler watcher"
  stop_home_processes "$home"
  pass "host: an incomplete C1,S1,C2 batch waits for its current successor"
}

test_mixed_spool_routes_the_scheduled_close_to_main() {
  local home saved spool arm
  home=$(make_primary_home mixed-spool)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  register_sweep_check "$home"
  saved=$FM_CHECK_INTERVAL
  export FM_CHECK_INTERVAL=1
  start_hook_session "$home"
  export FM_CHECK_INTERVAL=$saved
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "mixed spool: no initial watcher"
  append_status "$home" 'first actionable wake'
  wait_until 250 test -s "$home/stub-ready" || fail "mixed spool: engine did not hold: $(cat "$home/state/.supervision-host.log")"
  for spool in "$home"/state/.supervision-host-spool.*; do [ ! -f "$spool" ] || break; done
  append_status "$home" 'branch eligible batched signal'
  wait_until 250 spool_ends_with "$spool" S || fail "mixed spool: signal successor never confirmed"
  emit_and_expect_sweeps "$home" 1 'mixed spool'
  echo handle > "$home/stub-mode"
  printf 'continue\n' > "$home/stub-release"
  wait_until 300 hook_exited "$home" || fail "mixed spool: scheduled close never reached main"
  assert_rewoke_main "$home" 'mixed spool'
  assert_contains "$(main_drain "$home")" 'fixture-event-1' "mixed spool: scheduled close was lost"
  [ ! -e "$home/engine-call.2" ] || fail "mixed spool: branch took the main-only batch"
  [ "$(home_watchers "$home")" -eq 1 ] || fail "fixture: expected exactly one scheduler watcher"
  arm=$(cut -f1 "$home/state/.supervision-host-left")
  kill -TERM "$arm"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null' _ "$arm" || fail "detached arm did not stop"
  stop_home_processes "$home"
  pass "host: a signal followed by a scheduled close hands the complete batch to main"
}

test_detached_reader_does_not_stop_scanning_during_cleanup() {
  local home saved real_rm arm
  home=$(make_primary_home detached-cleanup)
  register_sweep_check "$home"
  mkfifo "$home/cleanup-release"
  real_rm=$(command -v rm)
  cat > "$home/fakebin/rm" <<SH
#!/usr/bin/env bash
"$real_rm" "\$@"
for arg in "\$@"; do
  if [ "\$arg" = "$home/state/.supervision-host-busy" ] && [ -s "$home/state/.supervision-host-left" ]; then
    : > "$home/cleanup-ready"
    read -r _ < "$home/cleanup-release"
  fi
done
SH
  chmod +x "$home/fakebin/rm"
  saved=$FM_CHECK_INTERVAL
  export FM_CHECK_INTERVAL=1
  start_hook_session "$home"
  export FM_CHECK_INTERVAL=$saved
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "cleanup: no initial watcher"
  : > "$home/emit.1"
  wait_until 250 test -e "$home/cleanup-ready" || fail "cleanup: host never detached"
  emit_and_expect_sweeps "$home" 2 'cleanup'
  ! hook_exited "$home" || fail "cleanup: fixture did not hold the host alive"
  [ "$(home_watchers "$home")" -eq 1 ] || fail "fixture: expected exactly one scheduler watcher"
  printf 'continue\n' > "$home/cleanup-release"
  wait_until 200 hook_exited "$home" || fail "cleanup: host did not finish"
  arm=$(cut -f1 "$home/state/.supervision-host-left")
  kill -TERM "$arm"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null' _ "$arm" || fail "detached arm did not stop"
  stop_home_processes "$home"
  pass "host: a detached arm continues scanning while its relinquished reader cleans up"
}

test_spool_consumption_becomes_busy_before_the_next_close() {
  local home saved spool real_rm
  home=$(make_primary_home consume-busy)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release" "$home/consume-release"
  register_sweep_check "$home"
  real_rm=$(command -v rm)
  cat > "$home/fakebin/rm" <<SH
#!/usr/bin/env bash
"$real_rm" "\$@"
for arg in "\$@"; do
  case "\$arg" in "$home/state"/.supervision-host-spool.*.lock)
    spool=\${arg%.lock}
    host=\$(awk -F '\t' '\$1 == "host" { print \$2 }' "$home/state/.supervision-host")
    if [ "\$PPID" = "\$host" ] && [ -e "$home/pause-consume" ] && [ ! -s "\$spool" ]; then
      "$real_rm" "$home/pause-consume"
      : > "$home/consume-ready"
      printf '%s\\n' "\$$" > "$home/orphan-pid"
      read -r _ < "$home/consume-release"
      "$real_rm" "$home/orphan-pid"
    fi
    ;;
  esac
done
SH
  chmod +x "$home/fakebin/rm"
  saved=$FM_CHECK_INTERVAL
  export FM_CHECK_INTERVAL=1
  start_hook_session "$home"
  export FM_CHECK_INTERVAL=$saved
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "consume busy: no initial watcher"
  append_status "$home" 'first actionable wake'
  wait_until 250 test -s "$home/stub-ready" || fail "consume busy: first turn did not hold"
  for spool in "$home"/state/.supervision-host-spool.*; do [ ! -f "$spool" ] || break; done
  append_status "$home" 'queued branch wake'
  wait_until 250 spool_ends_with "$spool" S || fail "consume busy: no verified handoff"
  : > "$home/pause-consume"
  printf 'continue\n' > "$home/stub-release"
  wait_until 250 test -e "$home/consume-ready" || fail "consume busy: consumption was not intercepted"
  emit_and_expect_sweeps "$home" 1 'consume busy'
  printf 'continue\n' > "$home/consume-release"
  wait_until 250 test -s "$home/engine-call.2" || fail "consume busy: second turn did not begin"
  emit_and_expect_sweeps "$home" 2 'consume busy second turn'
  [ "$(home_watchers "$home")" -eq 1 ] || fail "consume busy: expected one scheduler watcher"
  stop_home_processes "$home"
  pass "host: spool consumption commits busy before a close can end its continuing arm"
}

test_batched_heartbeat_retains_fleet_scope() {
  local order home spool
  for order in heartbeat-first signal-first; do
    home=$(make_primary_home "heartbeat-batch-$order")
    ln -s "$ROOT/.agents" "$home/.agents"
    echo held > "$home/stub-mode"
    mkfifo "$home/stub-release"
    start_hook_session "$home"
    turn_end "$home"
    wait_until 150 watcher_live "$home" || fail "heartbeat batch: no initial watcher"
    append_status "$home" 'first actionable wake'
    wait_until 250 test -s "$home/stub-ready" || fail "heartbeat batch: first turn did not hold"
    for spool in "$home"/state/.supervision-host-spool.*; do [ ! -f "$spool" ] || break; done
    if [ "$order" = signal-first ]; then
      append_status "$home" 'batched signal'
      wait_until 250 spool_ends_with "$spool" S || fail "heartbeat batch: signal did not hand off"
    fi
    append_wake "$home/state" heartbeat heartbeat heartbeat || fail "heartbeat batch: heartbeat was not queued"
    FM_HOME="$home" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_lock_acquire_wait "$2.lock"
      successor=$(tail -n 1 "$2")
      printf "C\theartbeat\n" >> "$2"
      if [ "$3" = signal-first ]; then
        IFS=$(printf "\t") read -r _ watcher _ <<< "$successor"
        fm_recovery_marker_snapshot "$FM_HOME/state/.watcher-down"
        printf "S\t%s\t%s\n" "$watcher" "${FM_RECOVERY_MARKER_TOKEN##*:}" >> "$2"
      fi
      fm_lock_release "$2.lock"
    ' _ "$ROOT" "$spool" "$order"
    if [ "$order" = heartbeat-first ]; then
      append_status "$home" 'batched signal'
      wait_until 250 spool_ends_with "$spool" S || fail "heartbeat batch: signal did not hand off"
    fi
    echo fleet > "$home/stub-mode"
    printf 'continue\n' > "$home/stub-release"
    wait_until 300 handled_at_least "$home" 2 || fail "heartbeat batch $order: fleet report was refused or the heartbeat was not handled: $(cat "$home/engine-report.log"; tail -8 "$home/state/.supervision-host.log"; cat "$home/hook.err"; cat "$spool" 2>/dev/null)"
    assert_contains "$(cat "$home/engine-drain.2")" 'heartbeat' "heartbeat batch: the heartbeat row was excluded from the grant"
    assert_grep '"task":"fleet"' "$home/state/branch-outcomes.jsonl" "heartbeat batch: fleet scope was not granted"
    ! awk -F '\t' '$3 == "heartbeat" { found = 1 } END { exit !found }' "$home/state/.wake-queue" \
      || fail "heartbeat batch: the successfully handled heartbeat remains unacknowledged"
    ! hook_exited "$home" || fail "heartbeat batch: an eligible batch was handed to main"
    [ "$(home_watchers "$home")" -eq 1 ] || fail "heartbeat batch: expected one scheduler watcher"
    stop_home_processes "$home"
  done
  pass "host: every heartbeat in an accepted batch retains its row and fleet scope in either order"
}

if [ -n "${FM_TEST_CASES:-}" ]; then
  for test_case in $FM_TEST_CASES; do "$test_case"; done
  exit 0
fi

test_scheduled_checks_continue_while_main_owns_repeated_closes
test_scheduled_checks_continue_through_a_provider_wait
test_spool_waits_for_the_latest_successor
test_mixed_spool_routes_the_scheduled_close_to_main
test_detached_reader_does_not_stop_scanning_during_cleanup
test_spool_consumption_becomes_busy_before_the_next_close
test_batched_heartbeat_retains_fleet_scope
