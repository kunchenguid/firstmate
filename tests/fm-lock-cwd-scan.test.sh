#!/usr/bin/env bash
# Behavior tests for fm_lock_windows_pids_with_cwd_under (bin/fm-lock-lib.sh),
# the MSYS /proc cwd scan behind fm-teardown.sh's leaked-process reaping and
# the lock staleness proof. The scan must:
#   1. report the pid of a process rooted under the target directory;
#   2. SKIP a lingering /proc entry whose process is already dead - an MSYS
#      process that is exiting keeps its listed entry for a beat after its
#      cwd stops resolving, and treating that race as "scan incomplete" made
#      every teardown on a busy host randomly refuse with
#      "cannot determine leaked processes";
#   3. still fail closed on a LIVE process whose cwd cannot be resolved - a
#      real gap in the answer, never silently dropped;
#   4. treat only an ESRCH answer from kill -0 as proof of death - EPERM or
#      any unrecognized failure may be a live process the walker cannot
#      signal, and must stay a fail-closed gap.
# The fixtures fake /proc via FM_PROC_ROOT_OVERRIDE; the function itself is
# plain bash and testable on every platform.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORLD=$(fm_test_tmproot fm-lock-cwd-scan)

# shellcheck source=bin/fm-lock-lib.sh
. "$ROOT/bin/fm-lock-lib.sh"

TARGET="$WORLD/worktree"
mkdir -p "$TARGET/sub"

# --- 1. a process rooted under the dir is reported ---------------------------
PROC1="$WORLD/proc1"
mkdir -p "$PROC1/self" "$PROC1/4181111"
ln -s "$TARGET/sub" "$PROC1/4181111/cwd"
out=$(FM_PROC_ROOT_OVERRIDE="$PROC1" fm_lock_windows_pids_with_cwd_under "$TARGET") \
  || fail "a clean scan with one resolvable rooted entry must succeed"
[ "$out" = 4181111 ] || fail "the rooted pid was not reported, got '$out'"
pass "cwd scan reports the pid rooted under the target directory"

# --- 2. a lingering entry for a DEAD pid is not a gap ------------------------
# A real pid that is provably dead by the time the scan runs: spawn and reap.
sleep 0.01 & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
PROC2="$WORLD/proc2"
mkdir -p "$PROC2/self" "$PROC2/4181111" "$PROC2/$DEAD_PID"
ln -s "$TARGET/sub" "$PROC2/4181111/cwd"
# $DEAD_PID's entry has no resolvable cwd - the exit-race shape.
out=$(FM_PROC_ROOT_OVERRIDE="$PROC2" fm_lock_windows_pids_with_cwd_under "$TARGET") \
  || fail "a lingering /proc entry for an already-dead pid must not fail the scan"
[ "$out" = 4181111 ] || fail "the dead entry hid the rooted pid, got '$out'"
pass "cwd scan skips a lingering /proc entry whose process is already dead"

# --- 3. a LIVE process with an unresolvable cwd still fails closed ----------
sleep 300 & LIVE_PID=$!
PROC3="$WORLD/proc3"
mkdir -p "$PROC3/self" "$PROC3/$LIVE_PID"
if out=$(FM_PROC_ROOT_OVERRIDE="$PROC3" fm_lock_windows_pids_with_cwd_under "$TARGET"); then
  kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null || true
  fail "a live process with an unresolvable cwd is a real gap and must fail the scan"
fi
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null || true
pass "cwd scan fails closed on a live process whose cwd cannot be resolved"

# --- 4. a non-ESRCH kill -0 failure stays a fail-closed gap ------------------
# A real EPERM needs a process owned by another user, which this suite cannot
# create without root. Shadow the kill builtin for one fake pid to answer the
# way an unsignalable live process does; every other pid falls through to the
# real builtin. The scan runs in a command substitution subshell of this
# shell, so the shadow is visible to it.
EPERM_PID=4181113
PROC4="$WORLD/proc4"
mkdir -p "$PROC4/self" "$PROC4/4181111" "$PROC4/$EPERM_PID"
ln -s "$TARGET/sub" "$PROC4/4181111/cwd"
kill() {
  if [ "${1-}" = -0 ] && [ "${2-}" = "$EPERM_PID" ]; then
    echo "kill: ($EPERM_PID) - Operation not permitted" >&2
    return 1
  fi
  builtin kill "$@"
}
if out=$(FM_PROC_ROOT_OVERRIDE="$PROC4" fm_lock_windows_pids_with_cwd_under "$TARGET"); then
  unset -f kill
  fail "a kill -0 failure other than ESRCH must keep the scan failing closed"
fi
unset -f kill
pass "cwd scan fails closed when kill -0 fails for a reason other than ESRCH"

exit 0
