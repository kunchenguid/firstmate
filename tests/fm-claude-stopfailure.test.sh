#!/usr/bin/env bash
# Behavior tests for the Claude StopFailure supervision recovery hook
# (bin/fm-claude-stopfailure.sh, docs/watcher-continuity.md "API-error turn
# ends").
#
# The hook fires as a Claude asyncRewake StopFailure hook. These tests run it
# hermetically as a child of a fake harness (a bash symlink named "claude") whose
# pid is written into the fixture home's state/.lock, with the reachability probe
# and the alert channels replaced by their documented seams, so no network, model,
# or desktop notification is ever touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stopfailure)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

# Alert recorder: one "<channel>\t<summary>" line per notifier invocation.
cat > "$TMP_ROOT/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "$FM_WEDGE_ALARM_LOG"
REC
chmod +x "$TMP_ROOT/rec"
export FM_WEDGE_ALARM_EXEC="$TMP_ROOT/rec"

# Fast backoff and a short grace keep every case in seconds.
export FM_STOPFAILURE_BACKOFF_BASE=1 FM_STOPFAILURE_BACKOFF_CAP=2 FM_GUARD_GRACE=300

install_scripts() {
  local dir=$1 lib
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stopfailure.sh" "$dir/bin/"
  for lib in fm-primary-scope-lib fm-supervision-lib fm-wake-lib fm-path-lib fm-session-lock-lib \
    fm-cursor-lib fm-hook-host-lib fm-wedge-alarm-lib fm-classify-lib fm-timeout-lib \
    fm-supervision-engine-lib; do
    cp "$ROOT/bin/$lib.sh" "$dir/bin/$lib.sh"
  done
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stopfailure.sh" "$dir/bin/fm-lock.sh"
}

# A primary home with in-flight work (the need) and two alert channels.
make_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  printf 'osascript\ncommand:true\n' > "$dir/config/wedge-alarm"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# Probe fixtures: down forever, up forever, or down until state/probe-up exists.
write_probe() {  # <dir> <down|up|flip>
  case "$2" in
    up) printf 'true' > "$1/probe.cmd" ;;
    down) printf 'false' > "$1/probe.cmd" ;;
    flip) printf 'test -e "%s/state/probe-up"' "$1" > "$1/probe.cmd" ;;
  esac
}

PAYLOAD_DEFAULT='{"hook_event_name":"StopFailure","error":"server_error","session_id":"sess-sf"}'

# Run the hook as a child of the fake harness holding the home's session lock.
# Output (stderr banner) and RC= go to <dir>/out.
run_sf() {  # <dir> [payload]
  local dir=$1 payload=${2:-$PAYLOAD_DEFAULT} rc=0
  printf '%s\n' "$payload" \
    | FM_HOME="$dir" FM_WEDGE_ALARM_LOG="$dir/alerts.log" \
      FM_STOPFAILURE_PROBE_CMD="$(cat "$dir/probe.cmd" 2>/dev/null || echo true)" \
      "${@:3}" "$FAKE_CLAUDE" -c '
        export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=sess-sf
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        printf "%s\n" "$CLAUDE_CODE_SESSION_ID" > "$FM_HOME/state/.lock-session"
        "$FM_HOME/bin/fm-claude-stopfailure.sh"
        result=$?
        case "${FM_TEST_CANCEL:-}" in
          stop) rm -f "$FM_HOME/state/.claude-stopfailure-episode" ;;
          need) rm -f "$FM_HOME/state/task.meta" ;;
          foreign) printf "other-session\n" > "$FM_HOME/state/.lock-session" ;;
        esac
        sleep "${FM_TEST_HOLD:-0}"
        exit "$result"
      ' > "$dir/out" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

alert_count() { [ -s "$1/alerts.log" ] && wc -l < "$1/alerts.log" | tr -d ' ' || echo 0; }

episode_get() { sed -n "s/^$2=//p" "$1/state/.claude-stopfailure-episode" 2>/dev/null | head -n 1; }

# --- gates -------------------------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir rc
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  fm_git_worktree "$base" "$dir" fm/stopfailure-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_scripts "$dir"
  write_probe "$dir" up
  rc=$(run_sf "$dir")
  expect_code 0 "$rc" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/.claude-stopfailure-episode" ] || fail "episode written in a child worktree"
  pass "stopfailure: inert in a linked child worktree even when in-flight"
}

test_inert_without_need() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/idle")
  rm -f "$dir/state/task.meta"
  write_probe "$dir" up
  rc=$(run_sf "$dir")
  expect_code 0 "$rc" "an idle home needs no recovery"
  [ ! -s "$dir/out" ] || fail "idle home printed output: $(cat "$dir/out")"
  [ ! -e "$dir/state/.claude-stopfailure-episode" ] || fail "idle home wrote an episode"
  pass "stopfailure: an idle home exits silently"
}

test_inert_under_afk_and_foreign_lock() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/afk")
  : > "$dir/state/.afk"
  write_probe "$dir" up
  rc=$(run_sf "$dir")
  expect_code 0 "$rc" "the away daemon owns supervision under AFK"
  [ ! -e "$dir/state/.claude-stopfailure-episode" ] || fail "AFK home wrote an episode"

  dir=$(make_home "$TMP_ROOT/foreign-lock")
  write_probe "$dir" up
  # A live lock owner outside this session: the hook must not act for it.
  sleep 30 &
  local holder=$!
  printf '%s\n' "$holder" > "$dir/state/.lock"
  rc=0
  printf '%s\n' "$PAYLOAD_DEFAULT" | FM_HOME="$dir" FM_WEDGE_ALARM_LOG="$dir/alerts.log" \
    FM_STOPFAILURE_PROBE_CMD=true "$dir/bin/fm-claude-stopfailure.sh" > "$dir/out" 2>&1 || rc=$?
  kill "$holder" 2>/dev/null || true
  expect_code 0 "$rc" "a session that does not own the lock must stay inert"
  [ ! -e "$dir/state/.claude-stopfailure-episode" ] || fail "non-owner wrote an episode"
  pass "stopfailure: inert under AFK and without session-lock ownership"
}

test_stands_down_on_foreign_hosts() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/foreign-host")
  write_probe "$dir" up
  rc=$(run_sf "$dir" '{"hook_event_name":"StopFailure","cursor_version":"1.0"}')
  expect_code 0 "$rc" "a Cursor-delivered payload must stand down"
  rc=$(run_sf "$dir" '{"hook_event_name":"StopFailure","transcript_path":"/home/u/.pi/agent/s.jsonl"}')
  expect_code 0 "$rc" "a pi-code-delivered payload must stand down"
  [ ! -e "$dir/state/.claude-stopfailure-episode" ] || fail "foreign host wrote an episode"
  pass "stopfailure: stands down for Cursor and pi-code payloads"
}

test_arguments_never_run() {
  local dir out rc=0
  dir=$(make_home "$TMP_ROOT/args")
  out=$("$dir/bin/fm-claude-stopfailure.sh" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must succeed"
  case "$out" in *'not for manual use'*) ;; *) fail "--help did not print usage: $out" ;; esac
  rc=0
  "$dir/bin/fm-claude-stopfailure.sh" --bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown argument must be refused"
  [ ! -e "$dir/state/.claude-stopfailure-episode" ] || fail "a manual run wrote an episode"
  pass "stopfailure: any argument is a manual run and never recovers"
}

# --- recovery -------------------------------------------------------------------------

test_reachable_api_rewakes_once_with_the_drain_instruction() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/rewake")
  write_probe "$dir" up
  rc=$(run_sf "$dir")
  expect_code 2 "$rc" "a reachable API must rewake the idle session"
  assert_grep 'bin/fm-wake-drain.sh' "$dir/out" "alert/banner text missing"
  assert_grep 'WAKE_ACK_REQUIRED' "$dir/out" "alert/banner text missing"
  assert_grep 'server_error' "$dir/out" "alert/banner text missing"
  [ "$(episode_get "$dir" attempts)" = 1 ] || fail "rewake not counted: $(cat "$dir/state/.claude-stopfailure-episode")"
  [ "$(alert_count "$dir")" = 0 ] || fail "a prompt recovery must not alert"
  [ ! -e "$dir/state/.watcher-down" ] || fail "a prompt recovery must not publish a downtime episode"
  pass "stopfailure: a reachable API rewakes once, counts it, and does not alert"
}

test_waits_for_the_api_before_rewaking() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/wait")
  write_probe "$dir" flip
  ( sleep 4; : > "$dir/state/probe-up" ) &
  local flipper=$!
  rc=$(run_sf "$dir")
  wait "$flipper" 2>/dev/null || true
  expect_code 2 "$rc" "the hook must rewake once the API returns"
  [ -e "$dir/state/probe-up" ] || fail "rewoke before the API returned"
  [ "$(alert_count "$dir")" = 0 ] || fail "recovery inside the grace window must not alert"
  pass "stopfailure: waits for the reachability probe, then rewakes without alerting"
}

# --- alert ------------------------------------------------------------------------------

test_unrecovered_episode_alerts_once_on_every_channel_then_recovers() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/alert")
  write_probe "$dir" flip
  ( sleep 7; : > "$dir/state/probe-up" ) &
  local flipper=$!
  rc=$(run_sf "$dir" "$PAYLOAD_DEFAULT" env FM_GUARD_GRACE=3)
  wait "$flipper" 2>/dev/null || true
  expect_code 2 "$rc" "the hook must still rewake when the API finally returns"
  [ "$(alert_count "$dir")" = 2 ] || fail "expected one alert on each of the two channels, got: $(cat "$dir/alerts.log" 2>/dev/null)"
  assert_grep $'osascript\t' "$dir/alerts.log" "alert/banner text missing"
  assert_grep $'command\t' "$dir/alerts.log" "alert/banner text missing"
  assert_grep 'supervision is OFF' "$dir/alerts.log" "alert/banner text missing"
  assert_grep 'server_error' "$dir/alerts.log" "alert/banner text missing"
  case "$(cat "$dir/state/.watcher-down" 2>/dev/null)" in
    pending:downtime:*) ;;
    *) fail "no typed downtime episode published: $(cat "$dir/state/.watcher-down" 2>/dev/null)" ;;
  esac
  pass "stopfailure: an unrecovered episode publishes downtime, alerts each channel once, then still rewakes"
}

test_never_recovering_api_alerts_and_stands_down_without_rewaking() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/never")
  write_probe "$dir" down
  rc=$(run_sf "$dir" "$PAYLOAD_DEFAULT" env FM_GUARD_GRACE=3 FM_STOPFAILURE_MAX_WAIT=9 FM_STOPFAILURE_REALERT_SECS=1000)
  expect_code 0 "$rc" "a hook that never saw the API return must not rewake"
  [ ! -s "$dir/out" ] || fail "stand-down printed output: $(cat "$dir/out")"
  [ "$(alert_count "$dir")" = 2 ] || fail "the rate limit must hold the alert to one per channel, got: $(cat "$dir/alerts.log" 2>/dev/null)"
  pass "stopfailure: a dead API alerts once (rate-limited) and never rewakes"
}

test_credential_failure_alerts_at_once_without_a_rewake() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/auth")
  write_probe "$dir" up
  rc=$(run_sf "$dir" '{"hook_event_name":"StopFailure","error":"authentication_failed"}')
  expect_code 0 "$rc" "waiting cannot fix a credential failure, so no rewake"
  [ "$(alert_count "$dir")" = 2 ] || fail "credential failure must alert immediately, got: $(cat "$dir/alerts.log" 2>/dev/null)"
  assert_grep 'authentication_failed' "$dir/alerts.log" "alert/banner text missing"
  pass "stopfailure: authentication failures alert immediately instead of rewaking"
}

# --- no loop ----------------------------------------------------------------------------

test_repeated_failures_keep_rewaking_with_capped_backoff() {
  local dir rc n
  dir=$(make_home "$TMP_ROOT/repeated")
  write_probe "$dir" up
  for n in 1 2 3 4 5 6; do
    rc=$(run_sf "$dir" "$PAYLOAD_DEFAULT" env FM_GUARD_GRACE=3)
    expect_code 2 "$rc" "rewake $n must remain possible"
  done
  [ "$(episode_get "$dir" attempts)" = 6 ] || fail "recovery stopped after repeated failures"
  [ "$(alert_count "$dir")" = 2 ] || fail "repeated failures must alert at the rate limit"
  rc=$(run_sf "$dir" "$PAYLOAD_DEFAULT" env FM_GUARD_GRACE=3 FM_STOPFAILURE_REALERT_SECS=1)
  expect_code 2 "$rc" "an expired alert interval must not block the rewake"
  [ "$(alert_count "$dir")" = 4 ] || fail "successful probes suppressed the expired re-alert"
  rc=$(run_sf "$dir" "$PAYLOAD_DEFAULT" env FM_GUARD_GRACE=3 FM_STOPFAILURE_REALERT_SECS=3600)
  expect_code 2 "$rc" "a rate-limited alert must not block the rewake"
  [ "$(alert_count "$dir")" = 4 ] || fail "successful probes bypassed the alert rate limit"
  [ "$(episode_get "$dir" attempts)" = 8 ] || fail "re-alerting changed the retry counter"
  pass "stopfailure: repeated failures keep recovering and alert at the rate limit"
}

test_rewake_preserves_the_original_alert_deadline() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/deadline")
  write_probe "$dir" up
  rc=$(run_sf "$dir" "$PAYLOAD_DEFAULT" env FM_GUARD_GRACE=3 FM_TEST_HOLD=5)
  expect_code 2 "$rc" "reachable API must rewake"
  [ "$(alert_count "$dir")" = 2 ] || fail "rewake without a watcher must alert at the original deadline"
  local cancel
  for cancel in stop need foreign; do
    dir=$(make_home "$TMP_ROOT/deadline-$cancel")
    write_probe "$dir" up
    rc=$(run_sf "$dir" "$PAYLOAD_DEFAULT" env FM_GUARD_GRACE=3 FM_TEST_HOLD=5 FM_TEST_CANCEL="$cancel")
    expect_code 2 "$rc" "reachable API must rewake before cancellation"
    [ "$(alert_count "$dir")" = 0 ] || fail "$cancel must make the detached deadline a no-op"
  done
  pass "stopfailure: original deadline alerts unless Stop ends the episode"
}

test_deadline_runs_during_a_slow_probe() {
  local dir outcome pid waited
  for outcome in true false; do
    dir=$(make_home "$TMP_ROOT/slow-$outcome")
    printf 'touch "%s/state/probe-start"; sleep 6; touch "%s/state/probe-end"; %s' "$dir" "$dir" "$outcome" > "$dir/probe.cmd"
    ( run_sf "$dir" "$PAYLOAD_DEFAULT" env FM_GUARD_GRACE=3 FM_STOPFAILURE_MAX_WAIT=9 > "$dir/rc" ) &
    pid=$!
    waited=0
    until [ "$(alert_count "$dir")" = 2 ] || [ "$waited" -ge 50 ]; do sleep 0.1; waited=$((waited + 1)); done
    [ "$(alert_count "$dir")" = 2 ] || fail "deadline did not alert during slow $outcome probe"
    [ -e "$dir/state/probe-start" ] || fail "probe never started"
    [ ! -e "$dir/state/probe-end" ] || fail "alert waited for slow $outcome probe to finish"
    wait "$pid" || true
    [ "$(alert_count "$dir")" = 2 ] || fail "probe completion duplicated the deadline alert"
  done
  pass "stopfailure: deadline runs independently of slow successful and failed probes"
}

test_deadline_survives_model_helper_replacement() {
  local dir
  dir=$(make_home "$TMP_ROOT/helper-replacement")
  cat > "$dir/first.sh" <<'HELPER'
export CLAUDE_PID=$$
"$FM_HOME/bin/fm-lock.sh" >/dev/null
printf '%s\n' "$$" > "$FM_HOME/first-helper"
printf '%s\n' "$TEST_PAYLOAD" | "$FM_HOME/bin/fm-claude-stopfailure.sh"
printf '%s\n' "$?" > "$FM_HOME/rc"
HELPER
  cat > "$dir/second.sh" <<'HELPER'
export CLAUDE_PID=$$
"$FM_HOME/bin/fm-lock.sh" >/dev/null
printf '%s\n' "$$" > "$FM_HOME/second-helper"
sleep 6
HELPER
  FM_HOME="$dir" FM_WEDGE_ALARM_LOG="$dir/alerts.log" \
    FM_STOPFAILURE_PROBE_CMD=true FM_GUARD_GRACE=4 TEST_PAYLOAD="$PAYLOAD_DEFAULT" \
    CLAUDE_CODE_SESSION_ID=sess-sf "$FAKE_CLAUDE" -c '
      "$FAKE_CLAUDE" "$FM_HOME/first.sh"
      "$FAKE_CLAUDE" "$FM_HOME/second.sh"
    ' > "$dir/out" 2>&1
  expect_code 2 "$(cat "$dir/rc")" "first helper must rewake"
  [ "$(cat "$dir/first-helper")" != "$(cat "$dir/second-helper")" ] || fail "helper identity did not change"
  [ "$(cat "$dir/state/.lock")" = "$(cat "$dir/second-helper")" ] || fail "replacement did not reclaim the lock"
  [ "$(alert_count "$dir")" = 2 ] || fail "helper replacement cancelled the deadline"
  pass "stopfailure: trusted session identity preserves the deadline across helper replacement"
}

test_reclaims_stale_lock_at_entry_and_during_wait() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/stale")
  write_probe "$dir" flip
  rc=0
  printf '%s\n' "$PAYLOAD_DEFAULT" | FM_HOME="$dir" FM_WEDGE_ALARM_LOG="$dir/alerts.log" \
    FM_STOPFAILURE_PROBE_CMD="$(cat "$dir/probe.cmd")" "$FAKE_CLAUDE" -c '
      sleep 0.01 &
      stale=$!
      wait "$stale"
      printf "%s\n" "$stale" > "$FM_HOME/state/.lock"
      (
        while [ ! -e "$FM_HOME/state/.claude-stopfailure-episode" ]; do sleep 0.1; done
        printf "%s\n" "$stale" > "$FM_HOME/state/.lock"
        touch "$FM_HOME/state/probe-up"
      ) &
      "$FM_HOME/bin/fm-claude-stopfailure.sh"
    ' > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" "stale ownership must be reclaimed at both checks"
  [ "$(episode_get "$dir" attempts)" = 1 ] || fail "stale owner blocked recovery"
  pass "stopfailure: stale locks at entry and during recovery are reclaimed"
}

test_clean_stop_ends_the_episode_and_a_waiting_hook_stands_down() {
  local dir pid
  dir=$(make_home "$TMP_ROOT/clean-stop")
  write_probe "$dir" down
  ( run_sf "$dir" > "$dir/rc" ) &
  pid=$!
  local waited=0
  until [ -e "$dir/state/.claude-stopfailure-episode" ] || [ "$waited" -ge 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$dir/state/.claude-stopfailure-episode" ] || fail "the waiting hook never recorded its episode"
  # A clean Stop by the owning session removes the record (the auto-arm's job).
  rm -f "$dir/state/.claude-stopfailure-episode"
  : > "$dir/state/probe-up"
  write_probe "$dir" up
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$(cat "$dir/rc")" "a hook whose episode a clean Stop ended must stand down"
  [ ! -s "$dir/out" ] || fail "stand-down printed output: $(cat "$dir/out")"
  pass "stopfailure: a clean Stop ends the episode and the waiting hook stands down"
}

test_newer_failure_supersedes_the_waiting_hook() {
  local dir pid rc
  dir=$(make_home "$TMP_ROOT/supersede")
  write_probe "$dir" down
  ( run_sf "$dir" > "$dir/rc-a" ) &
  pid=$!
  local waited=0
  until [ -e "$dir/state/.claude-stopfailure-episode" ] || [ "$waited" -ge 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ "$(episode_get "$dir" gen)" = 1 ] || fail "first firing did not take generation 1"
  # The newer firing finds the API reachable and owns the rewake.
  printf 'true' > "$dir/probe.cmd"
  rc=$(run_sf "$dir")
  expect_code 2 "$rc" "the newer firing must own the rewake"
  [ "$(episode_get "$dir" gen)" = 2 ] || fail "newer firing did not take generation 2"
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$(cat "$dir/rc-a")" "the superseded hook must stand down silently"
  [ "$(episode_get "$dir" attempts)" = 1 ] || fail "exactly one rewake must be counted across both firings"
  pass "stopfailure: a newer StopFailure supersedes a waiting hook, so only one rewake is delivered"
}

test_a_new_session_starts_a_new_episode() {
  local dir rc
  dir=$(make_home "$TMP_ROOT/new-session")
  write_probe "$dir" up
  printf 'session=other-session\nfirst=1\nattempts=9\nalerted=1\ngen=7\n' > "$dir/state/.claude-stopfailure-episode"
  rc=$(run_sf "$dir")
  expect_code 2 "$rc" "a record from another session must not affect this session"
  [ "$(episode_get "$dir" attempts)" = 1 ] || fail "stale session record leaked into the new episode"
  pass "stopfailure: an episode record from another session never affects a new one"
}

test_inert_in_child_worktree
test_inert_without_need
test_inert_under_afk_and_foreign_lock
test_stands_down_on_foreign_hosts
test_arguments_never_run
test_reachable_api_rewakes_once_with_the_drain_instruction
test_waits_for_the_api_before_rewaking
test_unrecovered_episode_alerts_once_on_every_channel_then_recovers
test_never_recovering_api_alerts_and_stands_down_without_rewaking
test_credential_failure_alerts_at_once_without_a_rewake
test_repeated_failures_keep_rewaking_with_capped_backoff
test_rewake_preserves_the_original_alert_deadline
test_deadline_runs_during_a_slow_probe
test_deadline_survives_model_helper_replacement
test_reclaims_stale_lock_at_entry_and_during_wait
test_clean_stop_ends_the_episode_and_a_waiting_hook_stands_down
test_newer_failure_supersedes_the_waiting_hook
test_a_new_session_starts_a_new_episode
