#!/usr/bin/env bash
# tests/fm-telemetry.test.sh - public recorder, rotation, durability, and
# singleton behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TELEMETRY="$ROOT/bin/fm-telemetry.sh"
TMP_ROOT=$(fm_test_tmproot fm-telemetry-tests)
DAEMON_HOME=

cleanup_telemetry_test() {
  if [ -n "$DAEMON_HOME" ] && [ -x "$TELEMETRY" ]; then
    FM_HOME="$DAEMON_HOME" "$TELEMETRY" disarm >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_telemetry_test EXIT
trap 'cleanup_telemetry_test; exit 130' INT
trap 'cleanup_telemetry_test; exit 143' TERM

write_fake_samplers() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/memory_pressure" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -Q ] || {
  printf 'expected summary-only -Q mode\n' >&2
  exit 1
}
printf 'System-wide memory free percentage: 42%%\n'
SH
  cat > "$fakebin/vm_stat" <<'SH'
#!/usr/bin/env bash
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 123.\n'
SH
  cat > "$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
printf 'vm.swapusage: total = 4096.00M  used = 1024.00M  free = 3072.00M\n'
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
101 1 101 7.5 9000 01:00 alpha
102 1 102 1.5 3000 00:30 beta
103 101 101 0.5 5000 00:10 gamma
OUT
SH
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake 100000 25000 75000 25%% /\n'
SH
  cat > "$fakebin/failing-python" <<'SH'
#!/usr/bin/env bash
printf 'fake interpreter refuses to flush\n' >&2
exit 1
SH
  chmod +x "$fakebin"/*
}

record_once() {
  local home=$1 fakebin=$2
  FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 \
    PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" record
}

recorder_pids() {
  pgrep -f 'fm-telemetry.sh record' 2>/dev/null | sort || true
}

# Runs a command in the background and fails the test if it has not returned
# within <deciseconds>, so a hang is reported instead of wedging the suite.
run_bounded() {
  local label=$1 limit=$2 rc_file=$3 out_file=$4
  shift 4
  ( "$@" > "$out_file" 2>&1; printf '%s\n' "$?" > "$rc_file" ) &
  local runner=$! tries=0
  while kill -0 "$runner" 2>/dev/null && [ "$tries" -lt "$limit" ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 "$runner" 2>/dev/null; then
    kill -KILL "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    fail "$label did not return within $((limit / 10))s"
  fi
  wait "$runner" 2>/dev/null || true
}

write_guard_holder() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/fm-telemetry.sh" <<'SH'
#!/usr/bin/env bash
sleep "${1:-60}"
SH
  chmod +x "$dir/fm-telemetry.sh"
}

dead_pid() {
  local pid
  sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid"
}

test_record_writes_parseable_durable_snapshot() {
  local home fakebin log expected_day offset
  home="$TMP_ROOT/record-home"
  fakebin="$TMP_ROOT/record-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"

  expected_day=$(date -u '+%Y-%m-%d')
  offset=$(date '+%z')
  record_once "$home" "$fakebin" || fail "record mode failed"
  log="$home/state/telemetry/telemetry-$expected_day.log"
  [ -f "$log" ] || fail "record mode did not key its daily log on the UTC date"
  assert_contains "$(cat "$log")" 'SNAPSHOT_BEGIN schema=fm-telemetry-v1' "snapshot begin marker is missing"
  assert_contains "$(cat "$log")" "local_utc_offset=$offset" "snapshot did not record the local UTC offset"
  assert_contains "$(cat "$log")" 'MEMORY_PRESSURE' "memory-pressure section is missing"
  assert_contains "$(cat "$log")" 'System-wide memory free percentage: 42%' "memory-pressure summary mode was not captured"
  assert_contains "$(cat "$log")" 'vm.swapusage: total = 4096.00M' "swap sampler output is missing"
  assert_contains "$(cat "$log")" 'PROCESS_TOTAL 3' "process total was not derived from the sampled table"
  assert_contains "$(cat "$log")" 'TOP_RSS_KIB' "RSS ranking is missing"
  assert_contains "$(cat "$log")" 'TOP_CPU_PERCENT' "CPU ranking is missing"
  assert_contains "$(cat "$log")" 'PROCESS_COUNTS_BY_PARENT' "per-parent counts are missing"
  assert_contains "$(cat "$log")" 'PROCESS_COUNTS_BY_PGID_COALITION_APPROX' "coalition approximation is missing"
  assert_contains "$(cat "$log")" 'SNAPSHOT_END' "snapshot end marker is missing"
  case "$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status 2>&1)" in
    *'not running newest_snapshot_age='[0-9]*s*) ;;
    *) fail "status did not report the newest completed snapshot age" ;;
  esac
  [ ! -e "$home/state/telemetry/.record.lock" ] && [ ! -L "$home/state/telemetry/.record.lock" ] ||
    fail "one-shot record left its lock behind"
  pass "record writes one bounded, parseable snapshot dated in UTC and releases its lock"
}

test_fsync_helper_flushes_the_named_file() {
  local home out rc
  home="$TMP_ROOT/fsync-home"
  mkdir -p "$home"
  printf 'durable payload\n' > "$home/telemetry.log"

  FM_HOME="$home" "$TELEMETRY" fsync "$home/telemetry.log" ||
    fail "durable flush helper failed on a real file"
  [ "$(cat "$home/telemetry.log")" = 'durable payload' ] ||
    fail "durable flush helper altered the file it flushed"

  out=$(FM_HOME="$home" "$TELEMETRY" fsync "$home/absent.log" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "durable flush helper accepted a missing target"
  assert_contains "$out" 'is not a file' "durable flush helper did not identify the bad target"

  out=$(FM_HOME="$home" "$TELEMETRY" fsync "$home" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "durable flush helper accepted a directory target"
  pass "the durable flush helper flushes real files and rejects non-files"
}

test_record_surfaces_durability_failure() {
  local home fakebin out rc
  home="$TMP_ROOT/sync-failure-home"
  fakebin="$TMP_ROOT/sync-failure-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"

  out=$(FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 \
    FM_TELEMETRY_PYTHON="$fakebin/failing-python" \
    PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" record 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "one-shot record hid a failed durability flush"
  assert_contains "$out" 'durability flush failed' "one-shot record did not identify the durability failure"
  [ ! -e "$home/state/telemetry/.record.lock" ] && [ ! -L "$home/state/telemetry/.record.lock" ] ||
    fail "failed one-shot record left its lock behind"
  pass "one-shot record returns failure when its durability flush fails"
}

test_record_cleans_up_after_partial_temp_failure() {
  local home fakebin telemetry leftovers pid tries
  home="$TMP_ROOT/tempfail-home"
  fakebin="$TMP_ROOT/tempfail-fakebin"
  telemetry="$home/state/telemetry"
  mkdir -p "$telemetry"
  write_fake_samplers "$fakebin"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *.sample.*) exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$fakebin/mktemp"

  # The leak is only observable while the loop lives: a one-shot run's EXIT trap
  # would sweep the orphan that a long-running recorder abandons every tick.
  FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" record "fmtelemetry-tempfail-$$" >/dev/null 2>"$home/record.err" &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    grep -q 'snapshot failed' "$home/record.err" 2>/dev/null && break
    sleep 0.1
    tries=$((tries + 1))
  done
  grep -q 'snapshot failed' "$home/record.err" 2>/dev/null ||
    fail "recorder did not report the failed temp-file allocation"
  leftovers=$(find "$telemetry" \( -name '.snapshot.*' -o -name '.processes.*' -o -name '.sample.*' \) | wc -l)
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ "$leftovers" -eq 0 ] || fail "recorder leaked $leftovers temp files outside the retention cap"
  pass "the running recorder removes every temp file it created when a later allocation fails"
}

test_interval_is_restricted_to_the_supported_cadence() {
  local home fakebin out rc
  home="$TMP_ROOT/interval-home"
  fakebin="$TMP_ROOT/interval-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"

  out=$(FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 FM_TELEMETRY_INTERVAL=31 \
    PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" record 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "record accepted a 31-second cadence"
  assert_contains "$out" 'from 15 to 30' "record did not state the supported cadence range"

  FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 FM_TELEMETRY_INTERVAL=14 \
    PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" record >/dev/null 2>&1 &&
    fail "record accepted a 14-second cadence"

  FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 FM_TELEMETRY_INTERVAL=30 \
    PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" record >/dev/null 2>&1 ||
    fail "record rejected the supported 30-second cadence"
  pass "record accepts only whole cadences from 15 through 30 seconds"
}

test_rotation_prunes_oldest_daily_logs_to_cap() {
  local home fakebin telemetry total
  home="$TMP_ROOT/rotation-home"
  fakebin="$TMP_ROOT/rotation-fakebin"
  telemetry="$home/state/telemetry"
  mkdir -p "$telemetry"
  write_fake_samplers "$fakebin"
  head -c 1200 /dev/zero | tr '\0' a > "$telemetry/telemetry-2026-01-01.log"
  head -c 1200 /dev/zero | tr '\0' b > "$telemetry/telemetry-2026-01-02.log"

  FM_HOME="$home" FM_TELEMETRY_RECORD_ONCE=1 FM_TELEMETRY_MAX_BYTES=3000 \
    PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" record || fail "rotation record failed"

  assert_absent "$telemetry/telemetry-2026-01-01.log" "rotation did not prune the oldest daily log"
  total=$(find "$telemetry" -name 'telemetry-*.log' -type f -exec wc -c {} + | awk 'END { print $1 + 0 }')
  [ "$total" -le 3000 ] || fail "rotation retained $total bytes above the 3000-byte cap"
  pass "rotation prunes oldest daily logs until total bytes are within the cap"
}

test_arm_is_idempotent_and_disarm_stops_singleton() {
  local home fakebin first_pid second_pid out tries
  home="$TMP_ROOT/daemon-home"
  fakebin="$TMP_ROOT/daemon-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"
  rm -f "$fakebin/ps"
  DAEMON_HOME=$home

  FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm >/dev/null || fail "first arm failed"
  tries=0
  while [ ! -L "$home/state/telemetry/.record.lock" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -L "$home/state/telemetry/.record.lock" ] || fail "arm did not publish its singleton owner"
  first_pid=$(readlink "$home/state/telemetry/.record.lock")
  first_pid=${first_pid%%:*}

  FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm >/dev/null || fail "idempotent arm failed"
  second_pid=$(readlink "$home/state/telemetry/.record.lock")
  second_pid=${second_pid%%:*}
  [ "$first_pid" = "$second_pid" ] || fail "second arm replaced the live recorder ($first_pid -> $second_pid)"

  out=$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status) || fail "status did not report the live recorder"
  assert_contains "$out" "running pid=$first_pid" "status did not identify the singleton owner"
  assert_contains "$out" 'interval=15s' "status did not report the live recorder's configured cadence"

  FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" disarm >/dev/null || fail "disarm failed"
  kill -0 "$first_pid" 2>/dev/null && fail "disarm left recorder pid $first_pid alive"
  out=$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status 2>&1)
  assert_contains "$out" 'not running' "status did not report the stopped recorder"
  DAEMON_HOME=
  pass "arm is idempotent and disarm cleanly stops the one per-home recorder"
}

test_fsync_helper_commits_the_containing_directory() {
  local home out rc
  home="$TMP_ROOT/dirsync-home"
  mkdir -p "$home/logs"
  printf 'durable payload\n' > "$home/logs/telemetry.log"

  FM_HOME="$home" "$TELEMETRY" fsync "$home/logs/telemetry.log" ||
    fail "durable flush helper failed on a real file"

  if [ "$(id -u)" -eq 0 ]; then
    pass "the durable flush helper commits the file (directory check skipped as root)"
    return 0
  fi

  chmod 0111 "$home/logs"
  out=$(FM_HOME="$home" "$TELEMETRY" fsync "$home/logs/telemetry.log" 2>&1)
  rc=$?
  chmod 0755 "$home/logs"
  [ "$rc" -ne 0 ] ||
    fail "durable flush helper reported success without committing the containing directory"
  pass "the durable flush helper commits the log's containing directory too"
}

test_tokenless_record_is_visible_to_status_and_disarm() {
  local home fakebin pid tries out
  home="$TMP_ROOT/tokenless-home"
  fakebin="$TMP_ROOT/tokenless-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"
  rm -f "$fakebin/ps"
  DAEMON_HOME=$home

  FM_HOME="$home" FM_TELEMETRY_INTERVAL=30 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" record >/dev/null 2>&1 &
  pid=$!
  tries=0
  while [ ! -L "$home/state/telemetry/.record.lock" ] && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -L "$home/state/telemetry/.record.lock" ] || fail "token-less record did not publish a lock"

  out=$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status) ||
    fail "status reported a token-less recorder as not running"
  assert_contains "$out" "running pid=$pid" "status did not identify the token-less recorder"

  out=$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" disarm) ||
    fail "disarm failed against a token-less recorder"
  assert_contains "$out" "stopped pid=$pid" "disarm did not stop the token-less recorder"
  kill -0 "$pid" 2>/dev/null && fail "disarm left token-less recorder pid $pid alive"
  wait "$pid" 2>/dev/null || true
  DAEMON_HOME=
  pass "a token-less recorder is reported by status and stopped by disarm"
}

test_arm_refuses_to_detach_without_a_working_durability_helper() {
  local home fakebin out rc
  home="$TMP_ROOT/probe-home"
  fakebin="$TMP_ROOT/probe-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"
  rm -f "$fakebin/ps"

  out=$(FM_HOME="$home" FM_TELEMETRY_PYTHON="$fakebin/failing-python" \
    PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" arm 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "arm detached a recorder without a working durability helper"
  assert_contains "$out" 'durable-flush helper' "arm did not name the broken durability helper"
  [ ! -L "$home/state/telemetry/.record.lock" ] || fail "failed arm published a lock"
  FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status >/dev/null 2>&1 &&
    fail "status reported a recorder after arm refused to detach"
  pass "arm refuses to detach when the durable-flush helper does not work"
}

test_detached_recorder_diagnostics_are_persisted_and_bounded() {
  local home fakebin diagnostics tries out bytes
  home="$TMP_ROOT/diagnostics-home"
  fakebin="$TMP_ROOT/diagnostics-fakebin"
  diagnostics="$home/state/telemetry/recorder.err"
  mkdir -p "$home/state/telemetry"
  write_fake_samplers "$fakebin"
  rm -f "$fakebin/ps"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *.sample.*) exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$fakebin/mktemp"
  head -c 200000 /dev/zero | tr '\0' 'x' > "$diagnostics"
  printf '\n' >> "$diagnostics"
  DAEMON_HOME=$home

  FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm >/dev/null || fail "arm failed"
  tries=0
  while [ "$tries" -lt 100 ]; do
    grep -q 'snapshot failed' "$diagnostics" 2>/dev/null && break
    sleep 0.1
    tries=$((tries + 1))
  done
  grep -q 'snapshot failed' "$diagnostics" 2>/dev/null ||
    fail "the detached recorder's diagnostics were discarded instead of persisted"

  bytes=$(wc -c < "$diagnostics")
  [ "$bytes" -le 65536 ] || fail "recorder diagnostics grew to $bytes bytes without being trimmed"

  case "$(grep 'snapshot failed' "$diagnostics" | tail -n 1)" in
    'fm-telemetry: '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z' snapshot failed') ;;
    *) fail "persisted diagnostics are not UTC timestamped: $(grep 'snapshot failed' "$diagnostics" | tail -n 1)" ;;
  esac

  out=$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status)
  assert_contains "$out" 'newest diagnostic' "status did not surface the recorder's diagnostics"
  case "$out" in
    *'newest diagnostic (age '[0-9]*'s)'*) ;;
    *) fail "status did not report how old the newest diagnostic is: $out" ;;
  esac

  FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" disarm >/dev/null ||
    fail "disarm failed"
  DAEMON_HOME=
  pass "a detached recorder persists bounded diagnostics that status surfaces"
}

test_arm_returns_even_when_liveness_cannot_be_confirmed() {
  local home fakebin rc out pid
  home="$TMP_ROOT/blindps-home"
  fakebin="$TMP_ROOT/blindps-fakebin"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/ps"
  DAEMON_HOME=$home

  run_bounded 'arm with unusable ps' 150 "$home/arm.rc" "$home/arm.out" \
    env FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm
  rc=$(cat "$home/arm.rc")
  out=$(cat "$home/arm.out")
  [ "$rc" -eq 0 ] || fail "arm failed against an unusable ps: $out"
  assert_contains "$out" 'running pid=' "arm did not converge on the observed lock owner"

  pid=$(readlink "$home/state/telemetry/.record.lock")
  pid=${pid%%:*}
  FM_HOME="$home" PATH="/usr/bin:/bin" "$TELEMETRY" disarm >/dev/null ||
    fail "disarm could not stop the recorder arm reported"
  kill -0 "$pid" 2>/dev/null && fail "disarm left recorder pid $pid alive"
  DAEMON_HOME=
  pass "arm returns bounded and reports the owner when liveness cannot be confirmed"
}

test_guard_is_reclaimed_only_after_its_holder_is_gone() {
  local home fakebin holderbin holder_pid stale rc out
  home="$TMP_ROOT/guard-home"
  fakebin="$TMP_ROOT/guard-fakebin"
  holderbin="$TMP_ROOT/guard-holderbin"
  mkdir -p "$home/state/telemetry"
  write_fake_samplers "$fakebin"
  rm -f "$fakebin/ps"
  write_guard_holder "$holderbin"

  stale=$(dead_pid)
  ln -s "$stale:20:fmtelemetry-stale" "$home/state/telemetry/.record.lock" ||
    fail "could not stage a stale lock"

  "$holderbin/fm-telemetry.sh" 60 &
  holder_pid=$!
  ln -s "$holder_pid:guard-live" "$home/state/telemetry/.record.guard" ||
    fail "could not stage a live guard"

  run_bounded 'arm against a live guard holder' 250 "$home/arm.rc" "$home/arm.out" \
    env FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm
  rc=$(cat "$home/arm.rc")
  out=$(cat "$home/arm.out")
  [ "$rc" -ne 0 ] || fail "arm stole the guard from a live holder: $out"
  [ "$(readlink "$home/state/telemetry/.record.guard")" = "$holder_pid:guard-live" ] ||
    fail "a live holder's guard was replaced"
  [ -L "$home/state/telemetry/.record.lock" ] ||
    fail "arm retired the stale lock while another process held the guard"

  kill -TERM "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  DAEMON_HOME=$home
  run_bounded 'arm against a dead guard holder' 250 "$home/arm2.rc" "$home/arm2.out" \
    env FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm
  rc=$(cat "$home/arm2.rc")
  out=$(cat "$home/arm2.out")
  [ "$rc" -eq 0 ] || fail "arm did not reclaim a guard whose holder is gone: $out"
  assert_contains "$out" 'running pid=' "arm did not start a recorder after reclaiming the guard"

  FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" disarm >/dev/null ||
    fail "disarm failed"
  DAEMON_HOME=
  pass "the guard is held against live holders and reclaimed once its holder is gone"
}

test_losing_the_start_up_race_stays_out_of_diagnostics() {
  local home fakebin diagnostics rc out
  home="$TMP_ROOT/loser-home"
  fakebin="$TMP_ROOT/loser-fakebin"
  diagnostics="$home/state/telemetry/recorder.err"
  mkdir -p "$home/state"
  write_fake_samplers "$fakebin"
  rm -f "$fakebin/ps"
  DAEMON_HOME=$home

  FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" arm >/dev/null || fail "arm failed"

  out=$(FM_HOME="$home" FM_TELEMETRY_INTERVAL=15 PATH="$fakebin:/usr/bin:/bin" \
    "$TELEMETRY" record "fmtelemetry-loser-$$" 2>>"$diagnostics")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a second recorder started against the same FM_HOME"
  assert_contains "$out" 'recorder already running' "the losing recorder did not report the live owner"
  [ ! -s "$diagnostics" ] ||
    fail "losing the start-up race polluted the diagnostics stream: $(cat "$diagnostics")"

  out=$(FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" status) ||
    fail "status did not report the live recorder"
  assert_not_contains "$out" 'newest diagnostic' "status reported a benign lost race as a diagnostic"

  FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" disarm >/dev/null ||
    fail "disarm failed"
  DAEMON_HOME=
  pass "losing the start-up race is reported without polluting persisted diagnostics"
}

test_concurrent_arms_over_a_stale_lock_keep_one_recorder() {
  local home fakebin before after fresh count stale_pid tries i survivor rc_file
  home="$TMP_ROOT/race-home"
  fakebin="$TMP_ROOT/race-fakebin"
  mkdir -p "$home/state/telemetry"
  write_fake_samplers "$fakebin"
  rm -f "$fakebin/ps"
  DAEMON_HOME=$home

  sleep 0 &
  stale_pid=$!
  wait "$stale_pid" 2>/dev/null || true
  ln -s "$stale_pid:20:fmtelemetry-stale-token" "$home/state/telemetry/.record.lock" ||
    fail "could not stage a stale lock"

  before="$home/recorders.before"
  after="$home/recorders.after"
  recorder_pids > "$before"
  i=0
  while [ "$i" -lt 4 ]; do
    (
      out=$(FM_HOME="$home" FM_TELEMETRY_INTERVAL=30 PATH="$fakebin:/usr/bin:/bin" \
        "$TELEMETRY" arm 2>&1)
      printf '%s\n' "$?" > "$home/arm.$i.rc"
      printf '%s\n' "$out" > "$home/arm.$i.out"
    ) &
    i=$((i + 1))
  done
  wait

  for rc_file in "$home"/arm.*.rc; do
    [ "$(cat "$rc_file")" = 0 ] ||
      fail "a concurrent cold arm failed with rc $(cat "$rc_file"): $(cat "${rc_file%.rc}.out")"
    case "$(cat "${rc_file%.rc}.out")" in
      *'fm-telemetry: running pid='*|*'fm-telemetry: already running pid='*) ;;
      *) fail "a concurrent cold arm did not report the live recorder: $(cat "${rc_file%.rc}.out")" ;;
    esac
  done

  count=0
  fresh=
  tries=0
  while [ "$tries" -lt 50 ]; do
    recorder_pids > "$after"
    fresh=$(comm -13 "$before" "$after")
    count=$(printf '%s' "$fresh" | grep -c . || true)
    [ "$count" -le 1 ] && break
    sleep 0.1
    tries=$((tries + 1))
  done
  [ "$count" -eq 1 ] || fail "concurrent arms left $count recorders running for one FM_HOME"

  survivor=$(readlink "$home/state/telemetry/.record.lock")
  survivor=${survivor%%:*}
  [ "$survivor" = "$fresh" ] ||
    fail "the published lock ($survivor) does not name the surviving recorder ($fresh)"

  FM_HOME="$home" PATH="$fakebin:/usr/bin:/bin" "$TELEMETRY" disarm >/dev/null ||
    fail "disarm could not stop the surviving recorder"
  kill -0 "$survivor" 2>/dev/null && fail "disarm left recorder pid $survivor alive"
  DAEMON_HOME=
  pass "concurrent arms over a stale lock converge on exactly one live recorder"
}

test_record_writes_parseable_durable_snapshot
test_fsync_helper_flushes_the_named_file
test_fsync_helper_commits_the_containing_directory
test_record_surfaces_durability_failure
test_record_cleans_up_after_partial_temp_failure
test_interval_is_restricted_to_the_supported_cadence
test_rotation_prunes_oldest_daily_logs_to_cap
test_arm_is_idempotent_and_disarm_stops_singleton
test_tokenless_record_is_visible_to_status_and_disarm
test_arm_refuses_to_detach_without_a_working_durability_helper
test_detached_recorder_diagnostics_are_persisted_and_bounded
test_arm_returns_even_when_liveness_cannot_be_confirmed
test_guard_is_reclaimed_only_after_its_holder_is_gone
test_losing_the_start_up_race_stays_out_of_diagnostics
test_concurrent_arms_over_a_stale_lock_keep_one_recorder
