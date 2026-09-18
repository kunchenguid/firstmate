#!/usr/bin/env bash
# tests/fm-afk-daemon-run.test.sh - the away/quiet daemon's restart supervisor
# (bin/fm-afk-daemon-run.sh) and its shutdown handshake with
# bin/fm-afk-launch.sh stop.
#
# Two properties are safety-critical and pull in opposite directions, so both
# are pinned here with real processes rather than through a stub of the loop:
#
#   RECOVERY  a daemon that dies while the away posture still stands is
#             restarted, journalled for the return brief, and announced through
#             the configured active alert - with no model turn involved, because
#             a dead daemon produces none and a home out of quota cannot
#             complete one.
#   TEARDOWN  a deliberate shutdown always wins. The loop must never outlive
#             `stop` and must never restart the daemon `stop` just terminated,
#             through the pid-bound shutdown marker, through a direct signal, or
#             when the posture itself ends.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN="$ROOT/bin/fm-afk-daemon-run.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-daemon-run-tests)

# Every supervisor this suite starts, reaped even when an assertion aborts the
# run: the loop outlives its fixture directory by design.
TRACK_PIDS=""
SUITE_CLEANUP() {
  local p
  for p in $TRACK_PIDS; do
    kill -TERM "$p" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap SUITE_CLEANUP EXIT
trap 'SUITE_CLEANUP; exit 130' INT
trap 'SUITE_CLEANUP; exit 143' TERM

# A home in the away posture with no daemon yet. The supervisor is what starts
# the daemon, so the fixture only has to establish the posture.
make_away_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'away\n%s\n' "$(date '+%s')" > "$home/state/.afk"
  printf '%s\n' "$home"
}

# A stand-in daemon that records each generation and exits on a per-generation
# trigger, so a test decides exactly when a generation dies and can tell one
# generation from the next.
write_fake_daemon() {  # <home>
  local home=$1 entry="$1/fake-daemon.sh"
  cat > "$entry" <<'FAKE'
#!/usr/bin/env bash
set -u
state="$FM_STATE_OVERRIDE"
printf '%s\n' "$$" >> "$state/generations"
trap 'exit 143' TERM
waited=0
limit=$(( ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120} * 10 ))
while [ ! -e "$state/die" ] && [ "$waited" -lt "$limit" ]; do
  sleep 0.1
  waited=$((waited + 1))
done
rm -f "$state/die"
exit 7
FAKE
  chmod +x "$entry"
  printf '%s\n' "$entry"
}

start_supervisor() {  # <home> <entry> [extra env assignments...] -> pid
  local home=$1 entry=$2
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_AFK_DAEMON_ENTRY="$entry" FM_AFK_RESTART_DELAY_SECS=0 \
    FM_AFK_RESTART_MIN_ALIVE_SECS=0 "$@" "$RUN" >/dev/null 2>&1 &
  local pid=$!
  TRACK_PIDS="$TRACK_PIDS $pid"
  printf '%s\n' "$pid"
}

# Poll rather than sleep a fixed budget: every wait here is for a real process
# transition that normally lands in milliseconds. The budgets are generous
# because the suite also runs alongside seven others in a parallel lane, where a
# subprocess can take far longer than it does alone; a passing case returns as
# soon as the transition happens either way.
wait_for() {  # <seconds> <command...>
  local limit=$1 waited=0
  shift
  while [ "$waited" -lt $((limit * 20)) ]; do
    "$@" && return 0
    sleep 0.05
    waited=$((waited + 1))
  done
  return 1
}

generation_count() {  # <home>
  grep -c '' "$1/state/generations" 2>/dev/null || printf 0
}

# Polls the count itself: passing it through wait_for would expand it once, at
# the call, and then re-test the same stale number forever.
wait_for_generations() {  # <home> <n>
  local home=$1 want=$2 waited=0
  while [ "$waited" -lt 400 ]; do
    [ "$(generation_count "$home")" -ge "$want" ] && return 0
    sleep 0.05
    waited=$((waited + 1))
  done
  return 1
}

pid_gone() {  # <pid>
  ! kill -0 "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# RECOVERY
# ---------------------------------------------------------------------------

# The whole point of the loop: the reap that killed the daemon twice on the
# captain's fleet left state/.afk standing with nothing behind it, and no turn
# ever came to notice. Here the death is recovered with no turn at all.
test_death_is_restarted_journalled_and_alarmed() {
  local home entry pid recorder journal
  home=$(make_away_home restart-recovery)
  entry=$(write_fake_daemon "$home")
  recorder="$home/alarm.log"
  cat > "$home/notify.sh" <<NOTIFY
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$recorder"
NOTIFY
  chmod +x "$home/notify.sh"

  pid=$(start_supervisor "$home" "$entry" FM_WEDGE_ALARM_EXEC="$home/notify.sh")
  wait_for_generations "$home" 1 || fail "restart: the first daemon generation never started"

  : > "$home/state/die"
  wait_for_generations "$home" 2 || fail "restart: a death with the posture standing was not restarted"
  pass "restart: a daemon death with the away posture still standing starts the next generation"

  journal="$home/state/.afk-daemon-restarts"
  wait_for 60 test -s "$journal" || fail "restart: the death was not journalled"
  assert_grep "$(date '+%Y')" "$journal" "restart: the journal entry carries no timestamp"
  pass "restart: each recovered death is journalled for the return brief"

  wait_for 60 test -s "$recorder" || fail "restart: no active alert fired for the recovered death"
  assert_grep "away-mode supervisor daemon died" "$recorder" \
    "restart: the alert summary does not name the daemon death"
  pass "restart: a recovered death raises the configured active alert"

  kill -TERM "$pid" 2>/dev/null || true
  wait_for 60 pid_gone "$pid" || fail "restart: the supervisor did not exit on SIGTERM"
}

# The daemon log is the one chronology a return reads first, so a recovered
# outage has to appear there beside the daemon's own start and stop lines.
test_restart_is_logged_beside_the_daemon_chronology() {
  local home entry pid log
  home=$(make_away_home restart-logged)
  entry=$(write_fake_daemon "$home")
  log="$home/state/.supervise-daemon.log"
  pid=$(start_supervisor "$home" "$entry")
  wait_for_generations "$home" 1 || fail "log: the first daemon generation never started"
  : > "$home/state/die"
  wait_for_generations "$home" 2 || fail "log: the death was not restarted"
  wait_for 60 grep -q 'the away-mode daemon exited' "$log" \
    || fail "log: the recovered death is missing from the daemon log"
  pass "restart: the recovered death is recorded in the daemon log"
  kill -TERM "$pid" 2>/dev/null || true
  wait_for 60 pid_gone "$pid" || fail "log: the supervisor did not exit on SIGTERM"
}

# ---------------------------------------------------------------------------
# TEARDOWN
# ---------------------------------------------------------------------------

# The marker names the exact supervisor pid, so `stop` binds THIS loop rather
# than muting whichever loop happens to read it next.
test_shutdown_marker_naming_this_supervisor_stands_it_down() {
  local home entry pid before
  home=$(make_away_home stop-marker)
  entry=$(write_fake_daemon "$home")
  pid=$(start_supervisor "$home" "$entry")
  wait_for_generations "$home" 1 || fail "marker: the first daemon generation never started"
  before=$(generation_count "$home")

  printf '%s\n' "$pid" > "$home/state/.afk-daemon-stopping"
  : > "$home/state/die"
  wait_for 60 pid_gone "$pid" || fail "marker: the supervisor kept running through a deliberate shutdown"
  assert_equals "$before" "$(generation_count "$home")" \
    "marker: the supervisor restarted the daemon during a deliberate shutdown"
  assert_absent "$home/state/.afk-daemon-run" "marker: the supervisor left its record behind"
  pass "shutdown: a marker naming this supervisor stands it down without another restart"
}

# An interrupted stop can leave a marker behind. It must not silence the next
# supervisor, or the very outage this loop exists to prevent comes back.
test_shutdown_marker_for_another_pid_does_not_silence_this_supervisor() {
  local home entry pid
  home=$(make_away_home stop-marker-stale)
  entry=$(write_fake_daemon "$home")
  # A pid this supervisor cannot have: the marker predates it.
  printf '%s\n' 999999 > "$home/state/.afk-daemon-stopping"
  pid=$(start_supervisor "$home" "$entry")
  wait_for_generations "$home" 1 || fail "stale marker: the first daemon generation never started"
  : > "$home/state/die"
  wait_for_generations "$home" 2 \
    || fail "stale marker: a marker naming another pid silenced this supervisor"
  pass "shutdown: a marker left by an interrupted stop cannot silence a later supervisor"
  kill -TERM "$pid" 2>/dev/null || true
  wait_for 60 pid_gone "$pid" || fail "stale marker: the supervisor did not exit on SIGTERM"
}

# The posture ending is its own stand-down reason, independent of any marker.
test_posture_ending_stands_the_supervisor_down() {
  local home entry pid before
  home=$(make_away_home posture-ended)
  entry=$(write_fake_daemon "$home")
  pid=$(start_supervisor "$home" "$entry")
  wait_for_generations "$home" 1 || fail "posture: the first daemon generation never started"
  before=$(generation_count "$home")
  rm -f "$home/state/.afk"
  : > "$home/state/die"
  wait_for 60 pid_gone "$pid" || fail "posture: the supervisor outlived the away posture"
  assert_equals "$before" "$(generation_count "$home")" \
    "posture: the supervisor restarted a daemon after the posture ended"
  pass "shutdown: the away posture ending stands the supervisor down"
}

# The signal path is the guarantee that still holds when the recorded terminal
# cannot be closed by id: SIGTERM reaches the generation in flight so its own
# cleanup runs, and the loop then exits instead of restarting.
test_sigterm_forwards_to_the_generation_and_ends_the_loop() {
  local home entry pid daemon_pid before
  home=$(make_away_home signal-forward)
  entry=$(write_fake_daemon "$home")
  pid=$(start_supervisor "$home" "$entry")
  wait_for_generations "$home" 1 || fail "signal: the first daemon generation never started"
  before=$(generation_count "$home")
  daemon_pid=$(tail -1 "$home/state/generations")

  kill -TERM "$pid" 2>/dev/null || true
  wait_for 60 pid_gone "$daemon_pid" || fail "signal: the generation in flight was not signalled"
  wait_for 60 pid_gone "$pid" || fail "signal: the supervisor did not exit on SIGTERM"
  assert_equals "$before" "$(generation_count "$home")" \
    "signal: the supervisor restarted a daemon while standing down"
  pass "shutdown: SIGTERM reaches the generation in flight and ends the loop"
}

# The end-to-end teardown proof, and the way this change could plausibly have
# made things worse: a real `fm-afk-launch.sh stop` against a live supervisor.
test_launch_stop_tears_down_a_live_supervisor() {
  local home entry pid before out
  home=$(make_away_home launch-stop)
  entry=$(write_fake_daemon "$home")
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CONTRACT" propose >/dev/null 2>&1 \
    && FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CONTRACT" confirm >/dev/null 2>&1 \
    || fail "launch stop: could not confirm the fixture posture"
  pid=$(start_supervisor "$home" "$entry")
  wait_for_generations "$home" 1 || fail "launch stop: the first daemon generation never started"
  wait_for 60 test -f "$home/state/.afk-daemon-run" \
    || fail "launch stop: the supervisor never published its record"
  before=$(generation_count "$home")

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LAUNCH" stop 2>&1) \
    || fail "launch stop: stop failed against a live supervisor: $out"
  wait_for 60 pid_gone "$pid" || fail "launch stop: the supervisor outlived stop"
  assert_equals "$before" "$(generation_count "$home")" \
    "launch stop: the supervisor restarted the daemon that stop terminated"
  assert_absent "$home/state/.afk" "launch stop: the away flag was not cleared"
  assert_absent "$home/state/.afk-daemon-run" "launch stop: the supervisor record was not cleared"
  assert_absent "$home/state/.afk-daemon-stopping" \
    "launch stop: the shutdown marker was left behind, muting a later supervisor"
  pass "shutdown: fm-afk-launch.sh stop ends the supervisor and it starts no replacement daemon"
}

# A stop that refuses must not leave the marker behind either: a still-live
# supervisor would then ignore the next death it sees.
test_refused_stop_clears_the_shutdown_marker() {
  local home out
  home=$(make_away_home stop-refused)
  printf 'bogus-record\n' > "$home/state/.afk-daemon-terminal"
  printf '%s\n' "$$" > "$home/state/.afk-daemon-run"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LAUNCH" stop 2>&1) \
    && fail "refused stop: a malformed terminal record was accepted: $out"
  assert_absent "$home/state/.afk-daemon-stopping" \
    "refused stop: the shutdown marker survived a refusal"
  assert_present "$home/state/.afk" "refused stop: away state was torn down anyway"
  pass "shutdown: a refused stop clears its own marker instead of muting the supervisor"
}

test_death_is_restarted_journalled_and_alarmed
test_restart_is_logged_beside_the_daemon_chronology
test_shutdown_marker_naming_this_supervisor_stands_it_down
test_shutdown_marker_for_another_pid_does_not_silence_this_supervisor
test_posture_ending_stands_the_supervisor_down
test_sigterm_forwards_to_the_generation_and_ends_the_loop
test_launch_stop_tears_down_a_live_supervisor
test_refused_stop_clears_the_shutdown_marker
