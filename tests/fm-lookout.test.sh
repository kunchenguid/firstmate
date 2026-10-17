#!/usr/bin/env bash
# tests/fm-lookout.test.sh - a second mate's lookout on the flagship
# (bin/fm-lookout.sh). A mate home keeps a lookout on a flagship home through a
# fake ssh that runs the remote command locally, or fails like a host that does
# not answer. A fake watcher arm stands in for bin/fm-watch-arm.sh, and a fake
# fm-supervise-daemon.sh holding the daemon lock stands in for the away daemon.
# Covers a fresh beacon, a stale beacon that recovers, a failed recovery with
# backoff that takes the con, a silent flagship whose con is taken and handed
# back, a daemon home whose away daemon is alive or dead, the parent-channel
# facts and their matching con keys, the claim the flagship honours, the
# return-brief lines, and standing the lookout as a watcher check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOOKOUT="$ROOT/bin/fm-lookout.sh"
TMP_ROOT=$(fm_test_tmproot lookout)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# ssh [options] -- <host> <command>: run <command> locally, or exit 255 like a
# host that does not answer while $FAKE_SSH_DOWN exists.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
host=$1
shift
[ ! -e "${FAKE_SSH_DOWN:-/nonexistent}" ] || { echo "ssh: connect to host $host port 22: Operation timed out" >&2; exit 255; }
[ ! -e "${FAKE_SSH_SLOW:-/nonexistent}" ] || sleep "$(cat "$FAKE_SSH_SLOW")"
exec /bin/sh -c "$1"
SH
# The watcher arm stand-in: counts its runs and reports the status line its
# mode file asks for.
cat > "$FAKEBIN/fake-arm" <<'SH'
#!/usr/bin/env bash
printf 'run\n' >> "$FAKE_ARM_RUNS"
if [ "$(cat "$FAKE_ARM_MODE" 2>/dev/null)" = fail ]; then
  echo 'watcher: FAILED - no live watcher with a fresh beacon'
  exit 1
fi
touch "$FM_HOME/state/.last-watcher-beat"
echo 'watcher: started pid=4242 (beacon fresh)'
SH
cat > "$FAKEBIN/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
chmod +x "$FAKEBIN/fake-ssh" "$FAKEBIN/fake-arm" "$FAKEBIN/fm-supervise-daemon.sh"

export FM_TEST_SEAM=1 FM_LOOKOUT_SSH="$FAKEBIN/fake-ssh" FM_LOOKOUT_ARM="$FAKEBIN/fake-arm"

LEDGER_ROWS='| Review | Title | Package(s) | Published | Needs | Last activity | Host hint |
|---|---|---|---|---|---|---|
| https://code.amazon.com/reviews/CR-100 | iOS fix | RewindApp | draft | conflict: needs rebase | 10-05 22:54Z | mini |
| https://code.amazon.com/reviews/CR-101 | Android fix | RewindApp | draft | dry run red: https://build.example/1 | 10-05 22:54Z | brownfield-desk |
| https://code.amazon.com/reviews/CR-102 | Both halves | RewindApp | draft | AutoSDE open (1 comments) | 10-05 22:54Z | mini (iOS half), brownfield-desk (Android half) |
| https://code.amazon.com/reviews/CR-103 | Done | RewindApp | draft | green, ready to publish (no redrive needed) | 10-05 22:54Z | mini |
| https://code.amazon.com/reviews/CR-104 | Held | RewindApp | draft | dry run red: https://build.example/4 | 10-05 22:54Z | mini |'

# A flagship home with an away record and a fresh beacon, its review ledger
# and ROUTE lines, and a remote second-mate home keeping a lookout on it.
make_pair() {  # <name> [stale-secs] -> sets FLAG and MATE
  local name=$1 stale=${2:-900} now
  FLAG="$TMP_ROOT/$name/flagship"
  MATE="$TMP_ROOT/$name/mate"
  mkdir -p "$FLAG/state" "$FLAG/data/cr-dm-watch" "$MATE/state" "$MATE/config"
  FM_HOME="$FLAG" FM_STATE_OVERRIDE="$FLAG/state" "$ROOT/bin/fm-afk-contract.sh" enter --words 'redrive the reviews' >/dev/null 2>&1 \
    || fail "could not write the flagship's away record"
  : > "$FLAG/state/.last-watcher-beat"
  printf '%s\n' "$LEDGER_ROWS" > "$FLAG/data/cr-dm-watch/overnight-ledger.md"
  now=$(date +%s)
  {
    printf 'progress [at=%s]: ROUTE https://code.amazon.com/reviews/CR-105 to mini-capacity: dry run red (iOS).\n' "$now"
    printf 'progress [at=%s]: ROUTE https://code.amazon.com/reviews/CR-106 to devdesk-linux: 1 AutoSDE comment open, fix in code.\n' "$now"
    printf 'progress [at=%s]: ROUTE https://code.amazon.com/reviews/CR-107 to beefy: conflict, needs rebase.\n' "$now"
    printf 'progress [at=%s]: ROUTE https://code.amazon.com/reviews/CR-108 to beefy: from last week.\n' $((now - 200000))
    printf 'working [key=cr-109] [at=%s]: ROUTE https://code.amazon.com/reviews/CR-109 to mini-capacity: keyed route line.\n' "$now"
  } > "$FLAG/state/cr-driver.status"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=laptop\n' > "$MATE/.fm-secondmate-parent"
  printf 'mini-capacity\n' > "$MATE/.fm-secondmate-home"
  cat > "$MATE/config/lookout" <<EOF
flagship_host=laptop
flagship_home=$FLAG
flagship_root=$ROOT
stale_secs=$stale
backoff_base_secs=300
login_shell=no
routes=state/cr-driver.status
ledger=data/cr-dm-watch/overnight-ledger.md
ledger_columns=1,5,7
ledger_skip=^(green|unreadable)
self_hint=mini
EOF
  export FAKE_ARM_RUNS="$TMP_ROOT/$name/arm-runs" FAKE_ARM_MODE="$TMP_ROOT/$name/arm-mode" FAKE_SSH_DOWN="$TMP_ROOT/$name/down" FAKE_SSH_SLOW="$TMP_ROOT/$name/slow"
}

watch() { OUT=$(FM_HOME="$MATE" "$LOOKOUT" watch 2>&1); RC=$?; }
on_flagship() { FM_HOME="$FLAG" "$LOOKOUT" "$@"; }
on_mate() { FM_HOME="$MATE" "$LOOKOUT" "$@"; }
arm_runs() { [ -f "$FAKE_ARM_RUNS" ] && wc -l < "$FAKE_ARM_RUNS" | tr -d ' ' || echo 0; }
age_beacon() { fm_touch_epoch $(( $(date +%s) - $1 )) "$FLAG/state/.last-watcher-beat"; }
MATE_LOG() { cat "$MATE/state/lookout/flagship/events.log" 2>/dev/null; }
FLAG_LOG() { cat "$FLAG/state/.lookout.log" 2>/dev/null; }
PARENT() { cat "$MATE/state/parent-replies.status" 2>/dev/null; }

case_fresh_beacon_does_nothing() {
  make_pair fresh
  watch
  expect_code 0 "$RC" "fresh watch"
  assert_equals '' "$OUT" "a fresh watch woke the mate"
  assert_equals '' "$(MATE_LOG)" "a fresh beacon recorded an event"
  assert_absent "$FLAG/state/.lookout.log" "a fresh beacon wrote to the flagship"
  assert_equals 0 "$(arm_runs)" "a fresh beacon started a recovery"
  age_beacon 5000
  rm -f "$FLAG/state/.afk-contract"
  watch
  assert_equals 0 "$(arm_runs)" "a stale beacon outside away mode started a recovery"
  pass "a fresh beacon, or a stale one outside away mode, records nothing, recovers nothing, and wakes no one"
}

case_stale_beacon_recovers() {
  make_pair stale
  age_beacon 4000
  watch
  expect_code 0 "$RC" "stale watch"
  assert_equals '' "$OUT" "a recovered watch woke the mate"
  assert_equals 1 "$(arm_runs)" "a stale beacon did not run the watcher arm once"
  assert_contains "$(MATE_LOG)" 's old during away mode (threshold 900s)' "the stale event was not recorded on the mate"
  assert_contains "$(FLAG_LOG)" "$(printf '\tmini-capacity\tstale\t')" "the stale event did not reach the flagship before the restart"
  assert_contains "$(PARENT)" 'lookout: the flagship'"'"'s watcher beacon is' "the stale fact was not published on the parent channel"
  assert_contains "$(PARENT)" 'lookout: restarted the flagship'"'"'s watcher' "the restart was not published on the parent channel"
  watch
  assert_contains "$(FLAG_LOG)" 'restarted the flagship'"'"'s watcher: watcher: started pid=4242' "the restart was not recorded on the flagship"
  assert_contains "$(FLAG_LOG)" 'watcher beacon is fresh again' "the end of the episode was not recorded"
  pass "a stale beacon is recorded on both vessels and the parent channel, then the watcher arm restarts it"
}

case_failed_recovery_takes_the_con() {
  local before brief
  make_pair failed
  printf 'fail\n' > "$FAKE_ARM_MODE"
  on_flagship claim CR-104 --holder flagship-driver >/dev/null || fail "the flagship driver could not claim CR-104"
  age_beacon 4000
  watch
  expect_code 0 "$RC" "failed watch"
  assert_contains "$OUT" 'lookout: took the con from flagship' "taking the con did not wake the mate"
  assert_contains "$OUT" 'CR-105 CR-109 CR-100 CR-102' "the mate was not told which reviews to drive"
  assert_contains "$(MATE_LOG)" 'could not restart the flagship'"'"'s watcher (attempt 1' "the failed restart was not recorded"
  assert_contains "$(MATE_LOG)" 'watcher: FAILED - no live watcher' "the arm's failure line was not kept"
  assert_contains "$(MATE_LOG)" 'took the con of 4 review(s) this mate builds: CR-105 CR-109 CR-100 CR-102; 1 already held elsewhere; 2 ROUTE line(s) to other desks not delivered' "the con summary is wrong"
  assert_contains "$(MATE_LOG)" 'ROUTE https://code.amazon.com/reviews/CR-106 to devdesk-linux was not delivered' "an undelivered route was not recorded"
  assert_not_contains "$(MATE_LOG)" 'CR-108' "a route outside the window was recorded"
  assert_contains "$(PARENT)" 'working [key=lookout-con-flagship-' "taking the con was not published as a working phase"
  assert_contains "$(PARENT)" 'could not restart the flagship' "the failed restart was not published"
  on_mate claimed CR-100 | grep -F 'held by mini-capacity' >/dev/null || fail "the mate does not hold CR-100"
  on_mate claimed CR-104 | grep -F 'held by flagship-driver' >/dev/null || fail "the mate took a review the flagship driver held"
  on_mate claimed CR-101 >/dev/null && fail "an Android-only review was claimed by the mate"
  on_mate claimed CR-103 >/dev/null && fail "a green review was claimed"
  on_mate claimed CR-109 >/dev/null || fail "a keyed ROUTE line to the mate was not claimed"
  before=$(arm_runs)
  watch
  assert_equals "$before" "$(arm_runs)" "a retry ran before its backoff elapsed"
  assert_equals '' "$OUT" "a second pass in the same episode woke the mate again"
  printf 'ok\n' > "$FAKE_ARM_MODE"
  : > "$FLAG/state/.last-watcher-beat"
  watch
  assert_contains "$OUT" 'lookout: handed the con back to flagship' "handing the con back did not wake the mate"
  on_flagship claimed CR-100 | grep -F 'held by mini-capacity' >/dev/null || fail "the flagship does not see the mate's claim on CR-100"
  on_flagship claim CR-100 --holder flagship-driver >/dev/null && fail "the flagship driver could double-drive a review the mate holds"
  [ "$(grep -c "$(printf '\ttook-the-con\t')" "$FLAG/state/.lookout.log")" -eq 1 ] || fail "the con was taken twice in one episode"
  brief=$(on_flagship brief --since 0)
  assert_contains "$brief" 'lookout mini-capacity at ' "the return brief has no lookout lines"
  assert_contains "$brief" 'lookout: CR-100 is still claimed by mini-capacity' "the return brief does not list the held claim"
  pass "a failed restart backs off and takes the con of the mate's own reviews without taking a held one, and the flagship honours the claims"
}

case_silent_flagship_hands_back_the_con() {
  local brief
  make_pair silent 5
  : > "$FLAG/state/.last-watcher-beat"
  watch
  assert_equals '' "$OUT" "the first pass woke the mate"
  : > "$FAKE_SSH_DOWN"
  watch
  expect_code 0 "$RC" "silent watch"
  assert_contains "$(MATE_LOG)" 'the flagship did not answer over SSH (exit 255' "the silence was not recorded on the mate"
  assert_contains "$(PARENT)" 'lookout: the flagship laptop did not answer over SSH' "the silence was not published on the parent channel"
  assert_absent "$FLAG/state/.lookout.log" "a silent flagship was written to"
  assert_present "$MATE/state/lookout/flagship/pending" "the silence was not queued for the return brief"
  sleep 6
  watch
  assert_contains "$OUT" 'lookout: took the con from flagship (the flagship has been silent for' "a silent away flagship's con was not taken"
  on_mate claimed CR-100 >/dev/null || fail "the mate did not claim CR-100 while the flagship was silent"
  rm -f "$FAKE_SSH_DOWN"
  : > "$FLAG/state/.last-watcher-beat"
  watch
  assert_contains "$OUT" 'lookout: handed the con back to flagship' "the con was not handed back"
  assert_contains "$(FLAG_LOG)" 'did not answer over SSH' "the queued silence did not reach the flagship"
  assert_contains "$(FLAG_LOG)" "$(printf '\thanded-back-the-con\t')" "the handback was not recorded on the flagship"
  assert_contains "$(PARENT)" 'resolved [key=lookout-con-flagship-' "the handback did not resolve the con phase on the parent channel"
  on_flagship claimed CR-100 | grep -F 'held by mini-capacity' >/dev/null || fail "the flagship lost the mate's claim at handback"
  on_mate release CR-100 >/dev/null || fail "the mate could not release CR-100"
  watch
  on_flagship claimed CR-100 >/dev/null && fail "the release did not reach the flagship"
  brief=$(on_flagship brief --since 0)
  assert_not_contains "$brief" 'CR-100 is still claimed' "the return brief lists a released claim"
  assert_contains "$brief" 'CR-102 is still claimed by mini-capacity' "the return brief lost a held claim"
  pass "a silent away flagship's con is taken after the threshold and handed back, with claims kept until released"
}

case_claim_rules() {
  make_pair claims
  on_flagship claim https://code.amazon.com/reviews/CR-200 --holder alpha >/dev/null || fail "a free review could not be claimed"
  on_flagship claim CR-200 --holder beta >/dev/null && fail "a held review was claimed by another holder"
  on_flagship release CR-200 --holder beta >/dev/null && fail "a non-holder released a claim"
  on_flagship release CR-200 --holder alpha >/dev/null || fail "the holder could not release"
  on_flagship claimed CR-200 >/dev/null && fail "a released review still reads held"
  pass "a review has one holder, and only that holder releases it"
}

case_idle_primary_takes_the_con() {
  local now
  make_pair idle
  now=$(date +%s)
  printf '%s\t7\tsignal\treview.status\tsignal: review.status\n' $((now - 4000)) > "$FLAG/state/.wake-queue"
  watch
  assert_contains "$OUT" 'lookout: took the con from flagship (the flagship'"'"'s primary session has made no progress' "an idle primary did not hand the mate the con"
  assert_equals 0 "$(arm_runs)" "a beating watcher was restarted"
  assert_contains "$(PARENT)" 'left queued wakes unacknowledged' "the idle primary was not published on the parent channel"
  on_mate claimed CR-100 >/dev/null || fail "the mate did not claim CR-100 from an idle primary"
  : > "$FLAG/state/.wake-queue"
  watch
  assert_contains "$OUT" 'lookout: handed the con back to flagship (the flagship'"'"'s watcher is beating and its queue is moving)' "the con was not handed back once the queue moved"
  assert_contains "$(MATE_LOG)" 'the flagship'"'"'s queue is moving again' "the end of the idle episode was not recorded"
  pass "a beating watcher over a primary that leaves wakes unacknowledged hands the mate the con, and progress hands it back"
}

case_unconfigured_queue_takes_nothing() {
  make_pair unconfigured
  sed -i.bak -e '/^routes=/d' -e '/^ledger/d' -e '/^self_hint=/d' "$MATE/config/lookout"
  printf 'fail\n' > "$FAKE_ARM_MODE"
  age_beacon 4000
  watch
  assert_equals '' "$OUT" "a con with no configured queue woke the mate"
  assert_contains "$(MATE_LOG)" 'no review queue is configured or synced' "the empty con was not recorded"
  assert_contains "$(PARENT)" 'no review queue is configured for this mate' "the empty con was not published"
  on_mate claimed CR-100 >/dev/null && fail "an unconfigured queue still claimed a review"
  printf 'ok\n' > "$FAKE_ARM_MODE"
  : > "$FLAG/state/.last-watcher-beat"
  watch
  assert_equals '' "$OUT" "handing back an empty con woke the mate"
  pass "with no review queue configured the lookout records the failure and claims nothing"
}

case_slow_flagship_and_reused_lock() {
  local started elapsed
  make_pair slow
  printf 'ssh_timeout_secs=8\npass_budget_secs=12\n' >> "$MATE/config/lookout"
  mkdir -p "$MATE/state/lookout/flagship"
  sleep 60 &
  printf '%s\n' "$!" > "$MATE/state/lookout/flagship/lock"
  age_beacon 4000
  printf '5\n' > "$FAKE_SSH_SLOW"
  started=$(date +%s)
  watch
  elapsed=$(( $(date +%s) - started ))
  kill %1 2>/dev/null || true
  [ "$elapsed" -lt 20 ] || fail "a slow flagship pass ran ${elapsed}s, past its budget"
  assert_contains "$(MATE_LOG)" 's old during away mode' "a lock held by a reused pid stopped the lookout"
  assert_equals 0 "$(arm_runs)" "a restart was tried without time left in the pass"
  rm -f "$FAKE_SSH_SLOW"
  watch
  assert_equals 1 "$(arm_runs)" "the deferred restart did not run on the next pass"
  assert_equals '' "$(cat "$MATE/state/lookout/flagship/lock")" "the pass lock was not emptied on exit"
  pass "a reused pid in the lock does not stop the lookout, and a slow flagship defers the restart instead of overrunning the pass"
}

case_stand_registers_a_watcher_check() {
  local out
  make_pair stand
  out=$(on_mate stand) || fail "stand failed: $out"
  assert_contains "$out" 'lookout stood on the flagship laptop' "stand did not say what it stood"
  assert_present "$MATE/state/lookout.check-trust" "stand did not register the watcher check"
  age_beacon 4000
  out=$(FM_HOME="$MATE" "$MATE/state/lookout.check.sh") || fail "the registered check did not run"
  assert_equals 1 "$(arm_runs)" "the registered check did not keep the lookout"
  out=$(on_mate stand-down) || fail "stand-down failed: $out"
  assert_absent "$MATE/state/lookout.check.sh" "stand-down left the check"
  rm -f "$MATE/config/lookout"
  on_mate stand >/dev/null 2>&1 && fail "stand ran without a flagship configured"
  pass "stand registers the lookout as this home's watcher check, stand-down retires it, and stand refuses without a flagship"
}

# Make the flagship a daemon home: state/.afk, and with "alive" a running
# fm-supervise-daemon.sh holding state/.supervise-daemon.lock.
make_daemon_home() {  # alive|dead
  : > "$FLAG/state/.afk"
  mkdir -p "$FLAG/state/.supervise-daemon.lock"
  if [ "$1" = alive ]; then
    "$FAKEBIN/fm-supervise-daemon.sh" >/dev/null 2>&1 &
    DAEMON_PID=$!
  else
    DAEMON_PID=999999
  fi
  printf '%s\n' "$DAEMON_PID" > "$FLAG/state/.supervise-daemon.lock/pid"
}

case_daemon_home_alive_is_left_alone() {
  local before
  make_pair daemon-alive
  make_daemon_home alive
  age_beacon 4000
  watch
  expect_code 0 "$RC" "daemon-alive watch"
  assert_equals '' "$OUT" "a live away daemon woke the mate"
  assert_equals 0 "$(arm_runs)" "a watcher was armed on a daemon home"
  assert_contains "$(MATE_LOG)" "left the flagship's supervision to its live away daemon: watcher: away daemon pid=$DAEMON_PID is alive" "the live daemon was not recorded"
  assert_not_contains "$(MATE_LOG)" 'took-the-con' "the con was taken while the away daemon lives"
  assert_not_contains "$(MATE_LOG)" 'restarted the flagship' "leaving a live daemon alone was recorded as a restart"
  on_mate claimed CR-100 >/dev/null && fail "the mate claimed a review while the away daemon lives"
  before=$(grep -c 'daemon-alive' "$MATE/state/lookout/flagship/events.log")
  watch
  assert_equals "$before" "$(grep -c 'daemon-alive' "$MATE/state/lookout/flagship/events.log")" "the daemon was rechecked before the backoff elapsed"
  kill "$DAEMON_PID" 2>/dev/null || true
  pass "on a daemon home with a live away daemon below the stall threshold the lookout arms no watcher, takes no con, and leaves the daemon alone"
}

case_daemon_home_stalled_takes_the_con() {
  make_pair daemon-stalled
  printf 'backoff_base_secs=1\ndaemon_stall_secs=2\n' >> "$MATE/config/lookout"
  make_daemon_home alive
  age_beacon 4000
  watch
  assert_equals '' "$OUT" "a live daemon below the stall threshold woke the mate"
  on_mate claimed CR-100 >/dev/null && fail "the mate claimed a review before the stall threshold"
  sleep 3
  age_beacon 4000
  watch
  expect_code 0 "$RC" "stalled daemon watch"
  assert_equals 0 "$(arm_runs)" "a watcher was armed beside a live away daemon"
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "the live away daemon was touched"
  assert_contains "$(MATE_LOG)" 'daemon alive but supervision stalled' "the stall was not recorded"
  assert_equals 1 "$(grep -c 'daemon-alive' "$MATE/state/lookout/flagship/events.log")" "the live daemon was recorded more than once in one episode"
  assert_contains "$OUT" 'lookout: took the con from flagship (the flagship'"'"'s away daemon is alive but supervision has stalled' "a stalled daemon home did not hand the mate the con"
  on_mate claimed CR-100 >/dev/null || fail "the mate did not claim CR-100 from a stalled daemon home"
  : > "$FLAG/state/.last-watcher-beat"
  watch
  assert_contains "$OUT" 'lookout: handed the con back to flagship' "the con was not handed back once the beacon was fresh"
  kill "$DAEMON_PID" 2>/dev/null || true
  pass "a live away daemon whose beacon stays stale past daemon_stall_secs is left alone while the mate takes the con, and a fresh beacon hands it back"
}

case_daemon_home_dead_takes_the_con() {
  make_pair daemon-dead
  make_daemon_home dead
  age_beacon 4000
  watch
  expect_code 0 "$RC" "daemon-dead watch"
  assert_equals 0 "$(arm_runs)" "a watcher was armed on a daemon home"
  assert_contains "$(MATE_LOG)" 'the away daemon owns supervision here and is not running; a lookout cannot revive it from outside' "the dead daemon was not reported"
  assert_contains "$OUT" 'lookout: took the con from flagship (the flagship'"'"'s watcher could not be restarted)' "a dead away daemon did not hand the mate the con"
  on_mate claimed CR-100 >/dev/null || fail "the mate did not claim CR-100 from a dead daemon home"
  pass "on a daemon home with a dead away daemon the lookout arms no watcher, reports it cannot revive it, and takes the con"
}

case_con_keys_match_on_an_idle_flagship() {
  local now working resolved
  make_pair con-keys
  now=$(date +%s)
  printf '%s\t7\tsignal\treview.status\tsignal: review.status\n' $((now - 4000)) > "$FLAG/state/.wake-queue"
  watch
  : > "$FLAG/state/.wake-queue"
  watch
  working=$(PARENT | sed -n 's/.*working \[key=\(lookout-con-[^]]*\)\].*/\1/p' | tail -n 1)
  resolved=$(PARENT | sed -n 's/.*resolved \[key=\(lookout-con-[^]]*\)\].*/\1/p' | tail -n 1)
  [ -n "$working" ] || fail "taking the con published no keyed working phase"
  assert_equals "$working" "$resolved" "the handback did not resolve the con phase it opened"
  [ "$working" != lookout-con-flagship-0 ] || fail "the con phase was keyed by a stale episode start"
  pass "an idle flagship's con opens and resolves one parent-channel phase under the same key"
}

case_fresh_beacon_does_nothing
case_stale_beacon_recovers
case_failed_recovery_takes_the_con
case_silent_flagship_hands_back_the_con
case_idle_primary_takes_the_con
case_unconfigured_queue_takes_nothing
case_slow_flagship_and_reused_lock
case_claim_rules
case_stand_registers_a_watcher_check
case_daemon_home_alive_is_left_alone
case_daemon_home_stalled_takes_the_con
case_daemon_home_dead_takes_the_con
case_con_keys_match_on_an_idle_flagship
