#!/usr/bin/env bash
# Behavior tests for remote job workers abandoned by a pruned code root.
#
# The leak this pins: a worker launched from a worktree's own bin/ outlives that
# worktree. Its restart supervisor sits above the serving child, so killing the
# recorded worker pid only makes the supervisor respawn, and nothing else ever
# stops it. Observed 2026-08-07 as 29 workers at ppid 1, 1-2 days old, each
# still appending to a log in a pruned no-mistakes gate worktree.
#
# The second leak: a lane worker wedged on a job it can no longer finish keeps
# a live code root, so the pruned-root condition structurally never saw it,
# yet it holds its home's queue shut and every later caller behind it.
#
# bin/fm-remote-job-reap-orphans.sh is a machine-wide sweep by design, so these
# cases assert only about their own fixture processes. Any other worker it
# stops during the run had a pruned code root, or a lane record that could no
# longer justify it, which is exactly the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-orphan-reap)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REAPER="$ROOT/bin/fm-remote-job-reap-orphans.sh"
export FM_TEST_REAP_ROOT="$TMP_ROOT"
export FM_TEST_REAL_PS
FM_TEST_REAL_PS=$(command -v ps)
mkdir -p "$TMP_ROOT/scan-bin"
cat > "$TMP_ROOT/scan-bin/ps" <<'SH'
#!/bin/bash
if [ "${1:-}" = -u ]; then
  "$FM_TEST_REAL_PS" "$@" | awk -v root="$FM_TEST_REAP_ROOT/" 'index($0, root)'
else
  exec "$FM_TEST_REAL_PS" "$@"
fi
SH
chmod +x "$TMP_ROOT/scan-bin/ps"
export PATH="$TMP_ROOT/scan-bin:$PATH"

TRACKED_PIDS=()
orphan_cleanup() {
  local pid
  for pid in "${TRACKED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap orphan_cleanup EXIT

track() { TRACKED_PIDS+=("$1"); }

alive() { kill -0 "$1" 2>/dev/null; }

pgid_of() { ps -p "$1" -o pgid= 2>/dev/null | tr -d '[:space:]'; }

ppid_of() { ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]'; }

# Wait up to <seconds> for <pid> to exit; 0 when it did.
wait_gone() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive "$pid" || return 0
    sleep 0.1
  done
  ! alive "$pid"
}

# Wait up to <seconds> for <pid> to have a live child; 0 when it does.
wait_child() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(pgrep -P "$pid" 2>/dev/null || true)" ] && return 0
    sleep 0.1
  done
  return 1
}

# True when <pid>'s parent is a reaper for orphaned processes: init itself, or
# a subreaper systemd registers one hop below init (PR_SET_CHILD_SUBREAPER,
# e.g. `systemd --user`) - a live host's per-user manager adopts orphans there
# instead of letting them reach real init, and that is just as orphaned for
# this fixture's purpose.
is_orphaned() { # <pid>
  local parent
  parent=$(ppid_of "$1")
  case "$parent" in ''|*[!0-9]*) return 1 ;; esac
  [ "$parent" = 1 ] && return 0
  [ "$(ppid_of "$parent")" = 1 ]
}

# Wait up to <seconds> for <pid> to be reparented to an orphan reaper (see
# is_orphaned) after its launching shell exits; 0 when it does.
wait_orphaned() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    is_orphaned "$pid" && return 0
    sleep 0.1
  done
  return 1
}

# --- a real worker fixture, launched exactly the way fm-on's Linux start does -

# build_remote_root <dir>: a minimal but genuine Firstmate code root carrying
# the real worker and job library.
build_remote_root() {
  local root=$1
  mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$root/bin/"
  chmod +x "$root/bin"/*.sh
  printf 'fixture\n' > "$root/AGENTS.md"
  git -C "$root" init -q -b main
  git -C "$root" config user.email test@example.com
  git -C "$root" config user.name Test
  git -C "$root" add AGENTS.md bin
  git -C "$root" commit -qm 'remote job fixture'
}

pid_is_numeric() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

# start_worker <remote-root> <account-home> <state-root>: start the worker
# through the shared library start path and echo the supervisor pid.
start_worker() {
  local root=$1 account_home=$2 state_root=$3 pid deadline
  pid=$(
    export FM_REMOTE_JOB_STATE_ROOT="$state_root"
    export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
    export FM_REMOTE_JOB_ORPHAN_GRACE_SECONDS=1
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_start_linux_worker "$root" "$account_home" >&2 || exit 1
    deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      pid=$(pgrep -f "^/bin/bash $root/bin/fm-remote-job-worker.sh\$" | head -n 1)
      if pid_is_numeric "$pid"; then
        printf '%s\n' "$pid"
        exit 0
      fi
      sleep 0.1
    done
    exit 1
  ) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$pid"
}

CASE1="$TMP_ROOT/case1"
mkdir -p "$CASE1/account"
build_remote_root "$CASE1/remote-root"
WORKER=$(start_worker "$CASE1/remote-root" "$CASE1/account" "$CASE1/remote-jobs") ||
  fail "could not start the fixture remote job worker"
track "$WORKER"
wait_child "$WORKER" 10 || fail "the fixture worker never started its serving child"
SERVE=$(pgrep -P "$WORKER" | head -n 1)

[ "$(pgid_of "$WORKER")" = "$WORKER" ] ||
  fail "the started worker is not its own process group leader, so its tree cannot be signalled as one group"
[ "$(pgid_of "$SERVE")" = "$WORKER" ] ||
  fail "the serving child is outside the worker's process group"
pass "the Linux start path puts the whole worker tree in its own process group"

wait_orphaned "$WORKER" 5 ||
  fail "the fixture worker is not orphaned to init, so this case does not reproduce the leak"

# The exact teardown shape that leaked in production: a fixture cleanup removes
# the worker's state root and then stops only the single recorded worker pid -
# which is the serving child, not the supervisor. KILL makes that obsolete
# teardown reproduction independent of the graceful handler's missing-state
# refusal. The supervisor respawns, so the tree survives a teardown that looks
# complete.
rm -rf "$CASE1/remote-jobs"
kill -KILL "$SERVE" 2>/dev/null || true
wait_gone "$SERVE" 10 || fail "the recorded serving child did not stop"
alive "$WORKER" || fail "the fixture supervisor did not survive a lone child kill, so this case no longer covers the leak"
wait_child "$WORKER" 15 || fail "the supervisor did not respawn after its recorded child pid was killed"
pass "removing the state root and killing the recorded worker pid leaves the tree running, orphaned"

# A worker whose code root is intact is never a reap candidate, which is what
# keeps the account's healthy LaunchAgent worker out of scope.
out=$("$REAPER" 2>&1) || fail "the reaper failed against a live code root: $out"
assert_not_contains "$out" "$WORKER" "the reaper reported a worker whose code root still exists"
alive "$WORKER" || fail "the reaper stopped a worker whose code root still exists"
pass "a worker whose code root still exists is never reaped"

# Prune the code root the way a returned worktree does.
SURVIVOR=$(pgrep -P "$WORKER" | head -n 1)
rm -rf "$CASE1/remote-root"
wait_gone "$WORKER" 60 || fail "the worker survived its code root being pruned"
wait_gone "$SURVIVOR" 60 || fail "a serving child outlived the abandoned supervisor"
pass "a worker stops its whole tree once its code root is pruned"

# --- the belt-and-suspenders sweep over already-orphaned workers -------------
#
# A current worker stops itself, so the sweep is exercised against a stand-in
# that presents the same command line from a pruned root without that
# self-termination - the shape of every worker started before it shipped.

CASE2="$TMP_ROOT/case2"
mkdir -p "$CASE2/remote-root/bin"
cat > "$CASE2/remote-root/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
# Stand-in for a worker predating self-termination: a supervisor that always
# respawns its serving child and never inspects its own code root.
set -u
if [ "${1:-}" = --serve ]; then
  while :; do sleep 0.2; done
fi
while :; do
  "$0" --serve &
  wait $! 2>/dev/null
  sleep 0.2
done
SH
chmod +x "$CASE2/remote-root/bin/fm-remote-job-worker.sh"
printf 'fixture\n' > "$CASE2/remote-root/AGENTS.md"

set -m
"$CASE2/remote-root/bin/fm-remote-job-worker.sh" >/dev/null 2>&1 &
STALE=$!
set +m
track "$STALE"
wait_child "$STALE" 10 || fail "the stand-in worker never started its serving child"
STALE_SERVE=$(pgrep -P "$STALE" | head -n 1)

rm -rf "$CASE2/remote-root"

out=$("$REAPER" --dry-run 2>&1) || fail "the reaper dry run failed: $out"
assert_contains "$out" "$STALE" "the dry run did not report the abandoned worker"
assert_contains "$out" "would reap" "the dry run did not mark its report as a preview"
alive "$STALE" || fail "the dry run stopped the abandoned worker instead of only reporting it"
pass "a dry run reports the abandoned worker and signals nothing"

out=$("$REAPER" 2>&1) || fail "the reaper failed: $out"
assert_contains "$out" "$STALE" "the reaper did not report stopping the abandoned worker"
assert_contains "$out" "pruned code root" "the report did not distinguish pruned-root cleanup"
wait_gone "$STALE" 20 || fail "the abandoned worker survived the reaper"
wait_gone "$STALE_SERVE" 20 || fail "the abandoned worker's serving child survived the reaper"
pass "the reaper stops an abandoned worker's whole tree"

out=$("$REAPER" 2>&1) || fail "a repeat reaper run failed: $out"
assert_not_contains "$out" "$STALE" "the reaper reported an already-stopped worker"
pass "the reaper is idempotent"

# --- a wedged lane whose code root is perfectly healthy ---------------------

CASE3="$TMP_ROOT/case3"
CASE3_ROOT="$CASE3/remote-root"
CASE3_ACCOUNT="$CASE3/account"
CASE3_STATE="$CASE3/remote jobs"
LANE_JOB=job-wedgedlane
mkdir -p "$CASE3_ROOT/bin" "$CASE3_ACCOUNT"
# A stand-in for a lane that can no longer finish its job: it presents the lane
# command line from a live code root and never exits on its own.
export FM_TEST_CASE3_LIB="$ROOT/bin/fm-remote-job-lib.sh"
export FM_TEST_CASE3_STATE="$CASE3_STATE"
cat > "$CASE3_ROOT/bin/fm-remote-job-worker.sh" <<'SH'
#!/bin/bash
set -u
if [ "${1:-}" != --lane ]; then
  "$0" --lane job-wedgedlane "$FM_TEST_CASE3_STATE" &
  "$0" --lane job-gonerecord "$FM_TEST_CASE3_STATE" &
  sleep 300 &
  printf '%s\n' "$!" > "$FM_TEST_CASE3_STATE/sibling.pid"
  wait
  exit
fi
if [ "$2" = job-wedgedlane ]; then
  . "$FM_TEST_CASE3_LIB"
  claim="$3/jobs/$2/.claim"
  mkdir "$claim"
  printf '%s\n' "$$" > "$claim/supervisor"
  fm_remote_job_process_start "$$" > "$claim/supervisor_start"
  set -m
  sleep 300 &
  group=$!
  set +m
  printf '%s\n' "$group" > "$claim/group"
  fm_remote_job_process_start "$group" > "$claim/group_start"
  printf '%s\n' "$group" > "$3/execution.pid"
fi
printf '%s\n' "$$" > "$3/$2.pid"
while :; do sleep 0.2; done
SH
chmod +x "$CASE3_ROOT/bin/fm-remote-job-worker.sh"
printf 'fixture\n' > "$CASE3_ROOT/AGENTS.md"

case3_reaper() { # run the sweep against this fixture's own account queue
  HOME="$CASE3_ACCOUNT" FM_REMOTE_JOB_STATE_ROOT="$CASE3_STATE" "$REAPER" "$@" 2>&1
}

# Write one lane record through the library's own record API rather than by
# hand, with the deadline the caller asks for.
write_lane_record() { # <job-id> <deadline>
  (
    FM_REMOTE_JOB_STATE_ROOT="$CASE3_STATE"
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_prepare_state "$CASE3_ACCOUNT" || exit 1
    mkdir -p "$FM_REMOTE_JOB_JOBS/$1" || exit 1
    fm_remote_job_write_number "$FM_REMOTE_JOB_JOBS/$1" deadline "$2" || exit 1
    fm_remote_job_write_state "$FM_REMOTE_JOB_JOBS/$1" running || exit 1
  )
}

start_lane() {
  local attempt
  for attempt in $(seq 1 100); do
    if [ -s "$CASE3_STATE/$1.pid" ]; then
      cat "$CASE3_STATE/$1.pid"
      return 0
    fi
    sleep 0.05
  done
  return 1
}

write_lane_record "$LANE_JOB" "$(( $(date +%s) + 3600 ))" \
  || fail "could not stage the live lane record fixture"
set -m
"$CASE3_ROOT/bin/fm-remote-job-worker.sh" >/dev/null 2>&1 &
LANE_PARENT=$!
set +m
track "$LANE_PARENT"
LANE=$(start_lane "$LANE_JOB") || fail "the overdue lane fixture did not start"
track "$LANE"
alive "$LANE" || fail "the lane stand-in did not start"
SIBLING=$(cat "$CASE3_STATE/sibling.pid")
EXECUTION=$(cat "$CASE3_STATE/execution.pid")
track "$EXECUTION"
[ "$(pgid_of "$LANE")" = "$LANE_PARENT" ] || fail "the lane is outside the serving worker group"
[ "$(pgid_of "$SIBLING")" = "$LANE_PARENT" ] || fail "the sibling is outside the serving worker group"
[ "$(pgid_of "$EXECUTION")" = "$EXECUTION" ] || fail "the command execution has no isolated group"

out=$(case3_reaper --dry-run) || fail "the reaper failed against a live lane record: $out"
assert_not_contains "$out" "$LANE" "the reaper reported a lane still inside its job's deadline"
alive "$LANE" || fail "the reaper stopped a lane still inside its job's deadline"
pass "a lane executing a record inside its deadline is never reaped"

OWN_STATE=$CASE3_STATE
CASE3_STATE="$CASE3/decoy-queue"
write_lane_record "$LANE_JOB" "$(( $(date +%s) - 3600 ))" || fail "could not stage the decoy record"
out=$(case3_reaper) || fail "the cross-queue sweep failed: $out"
assert_not_contains "$out" "$LANE" "the sweep used its own expired record for another queue's lane"
alive "$LANE" || fail "the sweep killed a healthy lane in another queue"
CASE3_STATE=$OWN_STATE
pass "the sweep binds lanes to their own queue despite matching ids elsewhere"


# The wedged shape itself: the record is still there, but its deadline - and the
# lane grace after it - has passed, so the lane can no longer be executing
# anything that record justifies.
write_lane_record "$LANE_JOB" "$(( $(date +%s) - 3600 ))" \
  || fail "could not age the lane record fixture"
cp "$CASE3_STATE/jobs/$LANE_JOB/.claim/supervisor_start" "$CASE3_STATE/supervisor-start.saved"
printf 'stale identity\n' > "$CASE3_STATE/jobs/$LANE_JOB/.claim/supervisor_start"
out=$(case3_reaper) || fail "the reaper failed against a stale lane identity: $out"
assert_not_contains "$out" "$LANE" "the reaper accepted a mismatched supervisor identity"
alive "$LANE" && alive "$EXECUTION" || fail "stale claim identity authorized cleanup"
cp "$CASE3_STATE/supervisor-start.saved" "$CASE3_STATE/jobs/$LANE_JOB/.claim/supervisor_start"
out=$(case3_reaper --dry-run) || fail "the overdue lane dry run failed: $out"
assert_contains "$out" "abandoned lane for $LANE_JOB" "the dry run missed the overdue lane"
alive "$LANE" && alive "$EXECUTION" || fail "the dry run signalled the lane execution"
out=$(case3_reaper) || fail "the reaper failed against a lane past its deadline: $out"
assert_contains "$out" "$LANE" "the reaper did not report stopping the lane past its deadline"
wait_gone "$LANE" 20 || fail "the lane past its job's deadline survived the reaper"
wait_gone "$EXECUTION" 20 || fail "the overdue lane's recorded execution survived"
alive "$SIBLING" || fail "reaping an overdue lane killed its healthy sibling"
alive "$LANE_PARENT" || fail "reaping an overdue lane killed the serving worker"
assert_contains "$out" "abandoned lane for $LANE_JOB" "the report did not distinguish lane cleanup"
pass "an overdue lane and its execution stop without killing the shared group"

GONE_JOB=job-gonerecord
rm -rf "$CASE3_STATE/jobs/$LANE_JOB"
GONE_LANE=$(start_lane "$GONE_JOB")
track "$GONE_LANE"
alive "$GONE_LANE" || fail "the second lane stand-in did not start"

out=$(case3_reaper --dry-run) || fail "the reaper dry run failed: $out"
assert_not_contains "$out" "$GONE_LANE" "the dry run reported a lane after record cleanup"
out=$(case3_reaper) || fail "the reaper failed after record cleanup: $out"
assert_not_contains "$out" "$GONE_LANE" "the reaper reported a lane after record cleanup"
alive "$GONE_LANE" || fail "the reaper killed a lane during normal completion"
write_lane_record "$GONE_JOB" "$(( $(date +%s) - 3600 ))" || fail "could not stage the completed record"
printf 'done\n' > "$CASE3_STATE/jobs/$GONE_JOB/state"
out=$(case3_reaper) || fail "the reaper failed against a completed record: $out"
assert_not_contains "$out" "$GONE_LANE" "the reaper reported a lane with a published result"
alive "$GONE_LANE" || fail "the reaper killed a lane with a published result"
pass "published and reaped results leave completing lanes alone"
