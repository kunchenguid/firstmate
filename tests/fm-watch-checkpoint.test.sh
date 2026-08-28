#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_quiet_checkpoint_hands_off_without_false_recovery() {
  local home first_out second_out status generation
  home=$(make_home quiet-successor)
  first_out="$home/first.out"
  second_out="$home/second.out"
  generation=handled-generation
  printf 'acked:handling:%s\n' "$generation" > "$home/state/.watcher-down"
  chmod 0600 "$home/state/.watcher-down"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$first_out" 2>"$home/first.err" || status=$?
  expect_code 124 "$status" "first quiet checkpoint exit"
  [ "$(cat "$home/state/.watcher-down")" = "acked:handling:$generation" ] \
    || fail "a planned checkpoint expiry minted a false downtime generation"

  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 1 >"$second_out" 2>"$home/second.err" || status=$?
  expect_code 124 "$status" "successor quiet checkpoint exit"
  assert_not_contains "$(cat "$second_out")" "check: rearm-resurface" \
    "a clean checkpoint handoff resurfaced false downtime"
  [ "$(cat "$home/state/.watcher-down")" = "acked:handling:$generation" ] \
    || fail "the successor checkpoint changed acknowledged recovery state"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a clean checkpoint handoff enqueued a synthetic recovery wake"
  pass "clean checkpoint expiry hands off to a successor without rearm-resurface"
}

test_crashed_checkpoint_still_resurfaces_recovery() {
  local home out child watcher_pid status i
  home=$(make_home crashed-checkpoint)
  out="$home/crashed.out"
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 20 >"$out" 2>"$home/crashed.err" &
  child=$!
  i=0
  while [ "$i" -lt 50 ]; do
    watcher_pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
    [ -n "$watcher_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "${watcher_pid:-}" ] || {
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "crash fixture checkpoint never acquired the watcher lock"
  }
  kill -KILL "$watcher_pid" 2>/dev/null || fail "could not crash the checkpoint watcher"
  wait "$child" 2>/dev/null || true

  status=0
  # Recovery is immediate once startup reaches the stale lock, but leave enough
  # outer headroom for migration/bootstrap subprocesses on a loaded CI worker.
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 10 >"$home/recovery.out" 2>"$home/recovery.err" || status=$?
  expect_code 0 "$status" "crashed checkpoint recovery exit"
  assert_contains "$(cat "$home/recovery.out")" "check: rearm-resurface" \
    "a real watcher crash did not resurface recovery"
  pass "a real checkpoint watcher crash still resurfaces recovery"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# One completed checkpoint must leave exactly ONE raw queue record per logical
# signal file. The post-grace re-scan re-observes every file that is still
# pending - the seen markers are not advanced until the block completes - so
# before the dedup collapse a single checkpoint wrote two raw records per file.
# Drain masked the noise by collapsing on the logical key, but the raw
# duplication weakens exactly-once reasoning about the queue.
#
# This used to stage an INTERRUPTED first checkpoint and measure the restart.
# That staging is no longer reachable: since upstream's re-arm resurface, the
# arm after an interrupted watcher republishes still-open durable supervision
# work as `check: rearm-resurface` and exits on it before any signal scan runs,
# and it keeps doing so while that work stays open. The collapse itself is
# unchanged and is what this case measures.
test_completed_coalescing_does_not_duplicate_raw_records() {
  local home out err status total
  home=$(make_home coalesce-dedup)
  out="$home/out.txt"
  err="$home/err.txt"
  # A crewmate's final status write and the same turn's turn-end hook: two files,
  # one logical turn.
  printf 'done: synthetic finish\n' > "$home/state/demo.status"
  : > "$home/state/demo.turn-ended"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "coalescing checkpoint exit"
  # Exactly one raw record per logical signal file, not two, and two in total.
  expect_code 1 "$(grep -c $'\tsignal\tdemo.status\t' "$home/state/.wake-queue")" \
    "demo.status did not collapse to exactly one raw queue record"
  expect_code 1 "$(grep -c $'\tsignal\tdemo.turn-ended\t' "$home/state/.wake-queue")" \
    "demo.turn-ended did not collapse to exactly one raw queue record"
  total=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  expect_code 2 "$total" "coalesced signal left more than two raw records"
  # Both files still coalesce into ONE actionable wake reason.
  assert_contains "$(cat "$out")" "demo.status" "coalesced wake dropped the status file"
  assert_contains "$(cat "$out")" "demo.turn-ended" "coalesced wake dropped the turn-end file"
  # The checkpoint recorded the current signature, so a follow-up checkpoint does
  # not re-fire the settled signals. It does still exit on the re-arm resurface
  # wake, because the two records it just queued are undrained durable work - so
  # what is pinned here is that NO new signal record appears and the raw count
  # does not grow.
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  assert_not_contains "$(cat "$out")" "signal:" "settled coalesced signal re-fired"
  total=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  expect_code 2 "$total" "settled signal appended extra raw records on re-poll"
  pass "a completed coalescing checkpoint leaves one raw record per logical signal"
}

test_quiet_checkpoint_exits_124_cleanly
test_quiet_checkpoint_hands_off_without_false_recovery
test_crashed_checkpoint_still_resurfaces_recovery
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_completed_coalescing_does_not_duplicate_raw_records
