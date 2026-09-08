#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-failure-tests)
REAL_MKTEMP=$(command -v mktemp)
BIN="$ROOT/bin"
LIB="$BIN/fm-wake-lib.sh"
DRAIN="$BIN/fm-wake-drain.sh"
GRANT="$BIN/fm-wake-grant.sh"

failure_case() {
  local dir
  dir=$(make_case "$1")
  cat > "$dir/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"$FM_TEST_FAILED_LOCK.owner."*)
    attempts=$(cat "$FM_TEST_FAILURE_ATTEMPTS" 2>/dev/null || printf '0')
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" > "$FM_TEST_FAILURE_ATTEMPTS"
    [ "$attempts" -le "${FM_TEST_ALLOW_CREATIONS:-0}" ] || exit 1
    ;;
esac
exec "$FM_TEST_REAL_MKTEMP" "$@"
SH
  chmod +x "$dir/fakebin/mktemp"
  printf '%s\n' "$dir"
}

with_creation_failure() {
  local dir=$1 lock=$2
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_TEST_FAILED_LOCK="$lock" FM_TEST_FAILURE_ATTEMPTS="$dir/attempts" \
    FM_TEST_REAL_MKTEMP="$REAL_MKTEMP" "$@"
}

expect_creation_refusal() {
  local dir=$1 lock=$2 rc
  shift 2
  if with_creation_failure "$dir" "$lock" "$@" > "$dir/out" 2> "$dir/err"; then
    fail "acquisition failure was reported as success: $*"
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] || fail "creation failure did not propagate status 2 (got $rc): $(cat "$dir/err")"
  grep -F 'lock: cannot establish owner record for ' "$dir/err" >/dev/null \
    || fail "creation failure omitted its diagnostic: $*"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "failed acquisition published a lock"
}

test_reclaim_gap_is_retryable() {
  local dir gap
  . "$BIN/fm-timeout-lib.sh"
  for gap in primary steal; do
    dir=$(make_case "reclaim-gap-$gap")
    # shellcheck disable=SC2016 # Variables expand in the child shell, not this test shell.
    if ! fm_run_timed 10 env FM_STATE_OVERRIDE="$dir/state" bash -c '
      set -eu
      . "$1"
      dir=$2
      lock=$FM_WAKE_QUEUE_LOCK
      gap_lock=$lock
      held=
      waiter=
      cleanup() {
        if [ -n "$waiter" ]; then
          kill "$waiter" 2>/dev/null || true
          wait "$waiter" 2>/dev/null || true
        fi
        fm_lock_release "$gap_lock.steal"
      }
      trap cleanup EXIT
      if [ "$3" = steal ]; then
        bash -c : &
        held=$!
        wait "$held"
        mkdir "$lock"
        printf "%s\n" "$held" > "$lock/pid"
        gap_lock="$lock.steal"
      fi
      fm_lock_try_acquire "$gap_lock.steal"
      result=$(bash -c '\''
        . "$1"
        if fm_lock_try_acquire "$2"; then rc=0; else rc=$?; fi
        printf "rc=%s held=%s\n" "$rc" "$FM_LOCK_HELD_PID"
      '\'' _ "$1" "$lock")
      [ "$result" = "rc=1 held=$held" ]
      [ ! -e "$gap_lock" ] && [ ! -L "$gap_lock" ]
      bash -c '\''
        . "$1"
        blocked=$2
        sleep() { : > "$blocked"; command sleep "$@"; }
        fm_wake_append signal task "signal: task"
      '\'' _ "$1" "$dir/blocked" &
      waiter=$!
      polls=0
      while [ ! -e "$dir/blocked" ] && [ "$polls" -lt 100 ]; do
        sleep 0.02
        polls=$((polls + 1))
      done
      [ -e "$dir/blocked" ]
      kill -0 "$waiter"
      [ ! -e "$FM_WAKE_QUEUE" ]
      fm_lock_release "$gap_lock.steal"
      wait "$waiter"
      waiter=
      [ "$(cat "$STATE/.wake-queue.seq")" = 1 ]
      awk -F "\t" '\''NF == 5 && $2 == 1 && $3 == "signal" && $4 == "task" { found++ } END { exit (NR != 1 || found != 1) }'\'' "$FM_WAKE_QUEUE"
      [ ! -e "$lock" ] && [ ! -L "$lock" ]
    ' _ "$LIB" "$dir" "$gap" > "$dir/out" 2> "$dir/err"; then
      fail "$gap reclaim gap did not retain contention and retry: $(cat "$dir/err")"
    fi
    [ ! -s "$dir/err" ] || fail "$gap reclaim gap emitted a creation-failure diagnostic: $(cat "$dir/err")"
    pass "$gap reclaim gap remains retryable and wake append waits for the stealer"
  done
}

test_reclaim_publication_race_is_contention() {
  local dir owner
  for owner in self dead; do
    dir=$(make_case "reclaim-publication-$owner")
    if ! FM_STATE_OVERRIDE="$dir/state" bash -c '
      set -eu
      . "$1"
      lock="$STATE/.publication.lock"
      if [ "$2" = self ]; then
        fm_lock_try_acquire "$lock"
      else
        bash -c : &
        dead=$!
        wait "$dead"
        mkdir "$lock"
        printf "%s\n" "$dead" > "$lock/pid"
      fi
      ln() {
        [ "${3:-}" != "$lock" ] || return 1
        command ln "$@"
      }
      if fm_lock_try_acquire "$lock"; then rc=0; else rc=$?; fi
      [ "$rc" -eq 1 ] && [ -z "$FM_LOCK_HELD_PID" ]
      [ ! -e "$lock" ] && [ ! -L "$lock" ]
      unset -f ln
      fm_lock_acquire_wait "$lock"
      fm_current_pid current
      [ "$(cat "$lock/pid")" = "$current" ]
      fm_lock_release "$lock"
    ' _ "$LIB" "$owner" > "$dir/out" 2> "$dir/err"; then
      fail "$owner-owner reclaim publication race was not retryable: $(cat "$dir/err")"
    fi
    [ ! -s "$dir/err" ] || fail "$owner-owner publication race emitted a creation-failure diagnostic"
    pass "$owner-owner reclaim publication race retains contention and later acquires"
  done
}

test_abandoned_reclaim_gap_recovers() {
  local dir holder
  dir=$(make_case abandoned-reclaim-gap)
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1"
    fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK.steal"
  ' _ "$LIB" &
  holder=$!
  wait "$holder" || fail "could not plant an exited steal owner"
  [ "$(cat "$dir/state/.wake-queue.lock.steal/pid")" = "$holder" ] \
    || fail "exited stealer did not leave its ownership record"
  # shellcheck disable=SC2016 # Variables expand in the child shell, not this test shell.
  if ! fm_run_timed 5 env FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1"
    fm_wake_append signal task "signal: task"
  ' _ "$LIB" > "$dir/out" 2> "$dir/err"; then
    fail "wake append failed to reclaim an abandoned transition: $(cat "$dir/err")"
  fi
  [ "$(cat "$dir/state/.wake-queue.seq")" = 1 ] || fail "abandoned transition did not admit the queued wake"
  [ ! -s "$dir/err" ] || fail "abandoned reclaim gap emitted a creation-failure diagnostic"
  pass "a stealer that exits in the publication gap is reclaimed"
}

test_queue_declines_unlocked_append_and_ack() {
  local dir state token allowed
  dir=$(failure_case append)
  state="$dir/state"
  # shellcheck disable=SC2016 # Variables expand in the child shell, not this test shell.
  expect_creation_refusal "$dir" "$state/.wake-queue.lock" bash -c '
    . "$1"
    fm_wake_append signal task "signal: task"
  ' _ "$LIB"
  [ ! -e "$state/.wake-queue" ] && [ ! -e "$state/.wake-queue.seq" ] \
    && [ ! -e "$state/.watcher-down" ] || fail "failed append mutated the queue or recovery state"
  pass "wake append refuses protected writes when its queue lock cannot be created"

  for allowed in 0 1; do
    dir=$(failure_case "ack-$allowed")
    state="$dir/state"
    append_wake "$state" signal task "signal: task" || fail "could not seed queue"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/presentation" 2> "$dir/presentation.err" \
      || fail "could not present queue before acknowledgement"
    token=$(FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      fm_recovery_marker_read "$STATE/.watcher-down" || exit 1
      printf "%s\n" "$FM_RECOVERY_MARKER_TOKEN"
    ' _ "$LIB") || fail "could not read recovery generation"
    cp "$state/.wake-queue" "$dir/queue-before"
    cp "$state/.main-eligible-rows" "$dir/rows-before"
    cp "$state/.watcher-down" "$dir/recovery-before"
    FM_TEST_ALLOW_CREATIONS="$allowed" expect_creation_refusal "$dir" "$state/.wake-queue.lock" \
      "$DRAIN" --ack-through 1 --recovery-generation "${token##*:}"
    cmp -s "$dir/queue-before" "$state/.wake-queue" || fail "failed ack removed queue rows"
    cmp -s "$dir/rows-before" "$state/.main-eligible-rows" || fail "failed ack changed presented rows"
    cmp -s "$dir/recovery-before" "$state/.watcher-down" || fail "failed ack changed recovery state"
    pass "wake drain preserves queue rows when acquisition fails after $allowed successful holds"
  done
}

test_grant_declines_unlocked_release() {
  local dir state
  dir=$(failure_case grant)
  state="$dir/state"
  append_wake "$state" signal task "signal: task" || fail "could not seed granted row"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" generation || fail "could not activate grant owner"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish generation 1 || fail "could not publish grant"
  cp "$state/.branch-eligible-rows" "$dir/rows-before"
  cp "$state/.branch-eligible-owner" "$dir/owner-before"
  expect_creation_refusal "$dir" "$state/.wake-queue.lock" "$GRANT" release generation
  cmp -s "$dir/rows-before" "$state/.branch-eligible-rows" || fail "failed grant release removed rows"
  cmp -s "$dir/owner-before" "$state/.branch-eligible-owner" || fail "failed grant release changed its owner"
  pass "wake grant release preserves ownership and rows after acquisition failure"
}

test_metadata_and_lease_guards_refuse_mutation() {
  local dir state
  dir=$(failure_case metadata)
  state="$dir/state"
  printf 'kind=ship\nx_request=request\nx_followups=0\n' > "$state/task.meta"
  cp "$state/task.meta" "$dir/meta-before"
  # shellcheck disable=SC2016 # Variables expand in the child shell, not this test shell.
  expect_creation_refusal "$dir" "$state/.meta-task.lock" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-x-lib.sh"
    fmx_meta_followups_set "$2/task.meta" 5
  ' _ "$BIN" "$state"
  cmp -s "$dir/meta-before" "$state/task.meta" || fail "failed metadata lock allowed a rewrite"
  pass "Relay metadata remains unchanged after acquisition failure"

  dir=$(failure_case lease)
  state="$dir/state"
  printf 'actor=branch\nexpires=1\n' > "$state/.lease-task"
  cp "$state/.lease-task" "$dir/lease-before"
  # shellcheck disable=SC2016 # Variables expand in the child shell, not this test shell.
  expect_creation_refusal "$dir" "$state/.fm-lease-command.lock" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-lease-lib.sh"
    if fm_lease_guard task test; then rc=0; else rc=$?; fi
    printf "held=%s\n" "$FM_LEASE_GUARD_LOCK"
    exit "$rc"
  ' _ "$BIN"
  [ "$(cat "$dir/out")" = 'held=' ] || fail "failed lease guard marked itself locked"
  cmp -s "$dir/lease-before" "$state/.lease-task" || fail "failed lease guard removed stale state"
  pass "lease guard declines mutation and leaves its held flag clear"
}

test_startup_harvest_refuses_unlocked_receipt() {
  local dir state
  dir=$(failure_case startup)
  state="$dir/state"
  printf 'generation=test\nstate=done\nreport_published=1\n' > "$state/.startup-network.status"
  printf 'test\t%s\n' "$$" > "$state/.startup-network.claim"
  cp "$state/.startup-network.claim" "$dir/claim-before"
  expect_creation_refusal "$dir" "$state/.startup-network.lock" \
    "$BIN/fm-startup-network.sh" harvest --pid "$$"
  cmp -s "$dir/claim-before" "$state/.startup-network.claim" || fail "failed harvest retired its claim"
  [ ! -e "$state/.startup-network.delivered" ] || fail "failed harvest published a delivery receipt"
  pass "startup harvest refuses claim and receipt mutation without its publication lock"
}

test_supervision_startup_reports_creation_failure() {
  local dir script lockname
  for script in fm-watch.sh fm-supervise-daemon.sh; do
    dir=$(failure_case "$script")
    case "$script" in
      fm-watch.sh) lockname=.watch.lock ;;
      *) lockname=.supervise-daemon.lock ;;
    esac
    expect_creation_refusal "$dir" "$dir/state/$lockname" "$BIN/$script"
    ! grep -F 'already running' "$dir/out" "$dir/err" >/dev/null \
      || fail "$script labelled creation failure as an existing supervisor"
    [ ! -e "$dir/state/.last-watcher-beat" ] || fail "failed watcher published a heartbeat"
    pass "$script reports creation failure instead of claiming a supervisor exists"
  done
}

test_interrupted_handoff_keeps_live_caller_held() {
  local dir state lockdir holder helper rc out fault
  for fault in kill write-failure; do
    dir=$(failure_case "handoff-$fault")
    state="$dir/state"
    lockdir="$state/.handoff.lock"
    holder=$$
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      caller=$3
      fault=$4
      caller_identity=$(fm_pid_identity "$caller") || exit 7
      printf() {
        if [ "$fault" = write-failure ] && [ "${2:-}" = "$caller_identity" ]; then
          return 1
        fi
        command printf "$@"
        if [ "$fault" = kill ] && [ "${2:-}" = "$caller" ]; then
          kill -KILL "${BASHPID:-$$}"
        fi
      }
      _fm_lock_acquire_wait_handoff "$2" "$caller"
    ' _ "$LIB" "$lockdir" "$holder" "$fault" > "$dir/helper.out" 2> "$dir/helper.err" &
    helper=$!
    rc=0
    wait "$helper" 2>/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "handoff fault did not interrupt the helper"
    [ "$(cat "$lockdir/pid")" = "$holder" ] || fail "handoff did not reach caller pid publication"
    [ ! -s "$lockdir/pid-identity" ] || [ -z "$(cat "$lockdir/pid-identity")" ] \
      || fail "handoff paired its new pid with an earlier identity"
    out=$(FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then rc=0; else rc=$?; fi
      printf "rc=%s held=%s pid=%s\n" "$rc" "$FM_LOCK_HELD_PID" "$(cat "$2/pid")"
    ' _ "$LIB" "$lockdir")
    [ "$out" = "rc=1 held=$holder pid=$holder" ] || fail "interrupted handoff allowed a live caller to lose its lock: $out"
    pass "$fault during handoff preserves the live caller with a conservative empty identity"
  done
}

test_reclaim_gap_is_retryable
test_reclaim_publication_race_is_contention
test_abandoned_reclaim_gap_recovers
test_queue_declines_unlocked_append_and_ack
test_grant_declines_unlocked_release
test_metadata_and_lease_guards_refuse_mutation
test_startup_harvest_refuses_unlocked_receipt
test_supervision_startup_reports_creation_failure
test_interrupted_handoff_keeps_live_caller_held
