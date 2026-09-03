#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source.
#
# The second half of the file covers the leaked-process sweep those helpers run
# before removing a root, including the boundary it must never cross. Nothing
# here inspects tests/lib.sh's source text; it only observes filesystem state
# and real process liveness around the real helpers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

# --- leaked-process sweep ---------------------------------------------------
#
# Removing a fixture root does not stop what is still running inside it, so
# fm_test_cleanup sweeps each registered root before removing it. These cases
# pin both halves of that contract through the real helpers: that a process
# left running inside a fixture root does not survive its owner, and - the
# property that matters most - that the sweep cannot reach anything outside
# the one root it was given.

# These cases deliberately start processes that must SURVIVE a sweep, so a case
# that fails early (fail exits immediately) would leak them - the exact class of
# leak this file is here to pin. tests/lib.sh's documented extension point is an
# own EXIT trap that still calls fm_test_cleanup, so sleeper pids are tracked and
# reaped there rather than only on each success path.
SLEEPER_PIDS=()

sweep_test_cleanup() {
  local p
  for p in "${SLEEPER_PIDS[@]:-}"; do
    [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
  done
  fm_test_cleanup
}
trap sweep_test_cleanup EXIT
trap 'sweep_test_cleanup; exit 130' INT
trap 'sweep_test_cleanup; exit 143' TERM

# Start a `sleep` whose cwd is <dir>, disowned so it is not the test shell's
# job to reap, and echo its pid once it is confirmed running. Mirrors the shape
# a leaked `treehouse get` subshell takes: reparented, cwd inside the tree.
#
# The sleeper's stdio must be detached. Callers use `$(start_cwd_sleeper ...)`,
# and a command substitution reads until the write end of its pipe is closed by
# EVERY holder - so a sleeper that inherited stdout would block the capture for
# its full duration rather than for as long as this function runs.
start_cwd_sleeper() {  # <dir>
  local dir=$1 pid tries=0
  ( cd "$dir" && exec sleep 300 ) >/dev/null 2>&1 </dev/null &
  pid=$!
  disown
  while [ "$tries" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null && break
    sleep 0.05
    tries=$((tries + 1))
  done
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

# Record a sleeper for the EXIT trap. Called in the parent shell (not inside the
# command substitution that captures the pid), so the array append survives.
track_sleeper() {  # <pid>
  [ -n "${1:-}" ] && SLEEPER_PIDS+=("$1")
}

reap_sleeper() {  # <pid>
  [ -n "${1:-}" ] || return 0
  kill -KILL "$1" 2>/dev/null || true
}

# proc_is_alive <pid>
# `kill -0` is the wrong liveness test here: these sleepers are children of the
# test shell, and a signalled child stays a ZOMBIE until the shell reaps it -
# a state `kill -0` reports as success, which would read a successfully killed
# process as a survivor. Ask for the process state instead and treat Z as dead.
proc_is_alive() {  # <pid>
  local state
  [ -n "${1:-}" ] || return 1
  state=$(ps -o state= -p "$1" 2>/dev/null | tr -d '[:space:]') || return 1
  [ -n "$state" ] || return 1
  case "$state" in Z*) return 1 ;; esac
  return 0
}

test_cleanup_sweeps_processes_leaked_in_its_own_root() {
  local child_out child_dir pid alive
  # The owning process registers the root, leaves a process running inside it,
  # publishes both, and exits - exercising the real EXIT-trap path rather than
  # calling the sweep directly.
  # The sleeper's stdio is detached so a regressed sweep fails this case
  # instead of hanging the capture for the sleeper's full duration.
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-sweep)
    ( cd "$d" && exec sleep 300 ) >/dev/null 2>&1 </dev/null &
    pid=$!
    disown
    printf "%s\n%s\n" "$d" "$pid"
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  pid=$(printf '%s\n' "$child_out" | sed -n '2p')
  [ -n "$pid" ] || fail "the child never published the pid of the process it leaked"
  assert_absent "$child_dir" "the fixture root survived its owning process's exit"

  alive=0
  if proc_is_alive "$pid"; then
    alive=1
    reap_sleeper "$pid"
  fi
  [ "$alive" -eq 0 ] \
    || fail "a process left running inside the fixture root survived fm_test_cleanup"
  pass "fm_test_cleanup reaps a process leaked inside its own fixture root"
}

test_sweep_cannot_reach_outside_its_own_root() {
  local harness swept sibling prefixed outside swept_pid sibling_pid prefixed_pid outside_pid rc=0
  harness=$(fm_test_tmproot fm-test-cleanup-sweep-boundary)
  # All four live under this suite's own registered root, so they are equally
  # eligible on the TMPDIR condition alone and only the marker and the root
  # argument may separate them - and so the suite's own cleanup reaps whatever
  # an early failure leaves behind.
  swept="$harness/swept"
  sibling="$harness/sibling"
  mkdir -p "$swept" "$sibling"
  : > "$swept/.fm-test-fixture"
  : > "$sibling/.fm-test-fixture"
  # A sibling whose path is a STRING PREFIX of the swept root: the classic way
  # a prefix comparison escapes its subtree. "$swept-prefixed" is not under
  # "$swept", so it must be untouched.
  prefixed="$swept-prefixed"
  mkdir -p "$prefixed"
  : > "$prefixed/.fm-test-fixture"
  outside="$harness/outside"
  mkdir -p "$outside"

  swept_pid=$(start_cwd_sleeper "$swept") || fail "the in-root sleeper never started"
  track_sleeper "$swept_pid"
  sibling_pid=$(start_cwd_sleeper "$sibling") || fail "the sibling-root sleeper never started"
  track_sleeper "$sibling_pid"
  prefixed_pid=$(start_cwd_sleeper "$prefixed") || fail "the prefix-sibling sleeper never started"
  track_sleeper "$prefixed_pid"
  outside_pid=$(start_cwd_sleeper "$outside") || fail "the out-of-root sleeper never started"
  track_sleeper "$outside_pid"

  fm_test_sweep_leaked_processes "$swept" || rc=$?
  expect_code 0 "$rc" "the sweep did not succeed on a well-formed fixture root"

  proc_is_alive "$swept_pid" \
    && { reap_sleeper "$swept_pid"; fail "the sweep left a process running inside the root it was given"; }
  proc_is_alive "$sibling_pid" \
    || fail "the sweep reached another fixture root's process"
  proc_is_alive "$prefixed_pid" \
    || fail "the sweep reached a sibling whose path is a string prefix of the swept root"
  proc_is_alive "$outside_pid" \
    || fail "the sweep reached a process outside the swept root entirely"

  reap_sleeper "$sibling_pid"
  reap_sleeper "$prefixed_pid"
  reap_sleeper "$outside_pid"
  pass "the leaked-process sweep reaches only processes inside the root it was given"
}

test_sweep_refuses_unmarked_and_non_tmpdir_roots() {
  local harness unmarked elsewhere outside_tmpdir unmarked_pid outside_pid rc=0
  harness=$(fm_test_tmproot fm-test-cleanup-sweep-refusals)
  # Under TMPDIR but carrying no fixture marker: a path that reached the
  # registry without fm_test_tmproot having created it must not be swept.
  unmarked="$harness/unmarked"
  # Marked but outside TMPDIR: a marker file alone must not license a sweep of
  # an arbitrary directory - a real task worktree or the primary checkout could
  # be handed a marker by anything. TMPDIR is repointed at a sibling for this
  # half, so the marked root really is outside the TMPDIR the sweep will read.
  elsewhere="$harness/effective-tmpdir"
  outside_tmpdir="$harness/marked-outside-tmpdir"
  mkdir -p "$elsewhere" "$outside_tmpdir" "$unmarked"
  : > "$outside_tmpdir/.fm-test-fixture"

  unmarked_pid=$(start_cwd_sleeper "$unmarked") || fail "the unmarked-root sleeper never started"
  track_sleeper "$unmarked_pid"
  outside_pid=$(start_cwd_sleeper "$outside_tmpdir") || fail "the non-TMPDIR sleeper never started"
  track_sleeper "$outside_pid"

  fm_test_sweep_leaked_processes "$unmarked" || rc=$?
  expect_code 0 "$rc" "the sweep failed rather than skipping an unmarked root"
  rc=0
  # A child shell, so the redirected TMPDIR cannot reach this shell at all.
  # Its own orphan scan is suppressed: it would otherwise sweep the redirected
  # TMPDIR rather than the one this case is asserting about.
  FM_TEST_SKIP_ORPHAN_REAP=1 TMPDIR="$elsewhere" bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
    fm_test_sweep_leaked_processes "$2"
  ' _ "$LIB" "$outside_tmpdir" || rc=$?
  expect_code 0 "$rc" "the sweep failed rather than skipping a non-TMPDIR root"

  proc_is_alive "$unmarked_pid" \
    || fail "the sweep signalled into a TMPDIR directory carrying no fixture marker"
  proc_is_alive "$outside_pid" \
    || fail "the sweep signalled into a marked directory outside TMPDIR"

  reap_sleeper "$unmarked_pid"
  reap_sleeper "$outside_pid"
  pass "the sweep skips roots that are unmarked or outside TMPDIR instead of signalling into them"
}

test_sweep_kills_a_process_that_ignores_term() {
  local harness root pid alive
  # The shape that actually leaked is TERM-resistant: the pane shell holding the
  # fixture tree is an interactive login shell, and every one of the 99 found on
  # this machine survived SIGTERM and needed SIGKILL. A sweep that only TERMed
  # and waited would look correct against a plain `sleep` while still leaking
  # the real thing, so pin the KILL pass against a process that ignores TERM.
  harness=$(fm_test_tmproot fm-test-cleanup-sweep-stubborn)
  root="$harness/stubborn"
  mkdir -p "$root"
  : > "$root/.fm-test-fixture"
  bash -c 'trap "" TERM; cd "$1" || exit 1; while :; do sleep 0.2; done' _ "$root" \
    >/dev/null 2>&1 </dev/null &
  pid=$!
  disown
  track_sleeper "$pid"
  while ! kill -0 "$pid" 2>/dev/null; do sleep 0.05; done
  # Confirm it really is TERM-resistant, so this case cannot pass vacuously
  # against a process that would have died to the TERM pass anyway.
  kill -TERM "$pid" 2>/dev/null
  sleep 0.5
  proc_is_alive "$pid" \
    || fail "the fixture process died to SIGTERM, so this case cannot prove the KILL pass"

  fm_test_sweep_leaked_processes "$root" \
    || fail "the sweep failed on a root holding a TERM-resistant process"

  alive=0
  if proc_is_alive "$pid"; then
    alive=1
    reap_sleeper "$pid"
  fi
  [ "$alive" -eq 0 ] \
    || fail "a TERM-resistant process inside the fixture root survived the sweep"
  pass "the sweep escalates to KILL for a process that ignores TERM"
}

test_sweep_leaves_a_pid_alone_once_its_identity_no_longer_matches() {
  local harness root pid alive
  # A cwd-only recheck closes the "left the subtree" case but not PID reuse:
  # if the pid the sweep scanned has already exited and the OS handed the
  # number to an unrelated process by the time the sweep is about to signal,
  # a cwd-only recheck cannot tell the difference. fm_test_pid_identity is
  # overridden here, in a child shell, to return a different value on every
  # call - exactly what re-deriving identity for a reused pid would look like
  # - so the pre-signal identity recheck can never match what was captured at
  # scan time. The real sleeper must therefore survive untouched.
  harness=$(fm_test_tmproot fm-test-cleanup-sweep-identity)
  root="$harness/reused"
  mkdir -p "$root"
  : > "$root/.fm-test-fixture"
  pid=$(start_cwd_sleeper "$root") || fail "the identity-check sleeper never started"
  track_sleeper "$pid"

  # A plain shell variable would not do: each call to fm_test_pid_identity runs
  # inside the command substitution that captures its output, which is a
  # subshell, so an in-memory counter would never actually advance in the
  # caller. A counter file survives across that subshell boundary instead.
  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
    counter="$2/identity-calls"
    fm_test_pid_identity() {
      local n
      n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
      printf "%s\n" "$n" > "$counter"
      printf "identity-%s\n" "$n"
    }
    fm_test_sweep_leaked_processes "$3"
  ' _ "$LIB" "$harness" "$root" \
    || fail "the sweep failed rather than no-op'ing on an identity mismatch"

  alive=0
  proc_is_alive "$pid" && alive=1
  reap_sleeper "$pid"
  [ "$alive" -eq 1 ] \
    || fail "the sweep signalled a pid whose identity no longer matched what it captured at scan time"
  pass "the sweep leaves a pid alone once its identity no longer matches what was captured at scan time"
}

test_sweep_never_reaches_a_registered_repo_checkout_dir() {
  local repo_dir pid
  # Not hypothetical: tests/fm-lint.test.sh registers a cleanup dir created by
  # `mktemp -d "$ROOT/.fm-lint-parity.XXXXXX"` - inside the repo checkout - and
  # tests/fm-arm-pretool-check.test.sh registers a bare mktemp root with no
  # fixture marker. A sweep driven off the registry alone would signal into the
  # checkout, so both conditions are checked against that real shape here, with
  # a marker planted to prove the TMPDIR condition carries it on its own.
  repo_dir=$(mktemp -d "$ROOT/.fm-test-sweep-repo-guard.XXXXXX") \
    || fail "could not create the repo-internal directory this case is about"
  pid=$(start_cwd_sleeper "$repo_dir") || {
    rm -rf "$repo_dir"
    fail "the repo-internal sleeper never started"
  }
  track_sleeper "$pid"

  fm_test_sweepable_root "$repo_dir" \
    && fail "a directory inside the repo checkout was accepted as sweepable"
  : > "$repo_dir/.fm-test-fixture"
  fm_test_sweepable_root "$repo_dir" \
    && fail "a marker file alone made a repo-checkout directory sweepable"
  fm_test_sweep_leaked_processes "$repo_dir" \
    || fail "the sweep failed rather than skipping a repo-checkout directory"

  proc_is_alive "$pid" || fail "the sweep signalled a process inside the repo checkout"
  reap_sleeper "$pid"
  rm -rf "$repo_dir"
  pass "the sweep never reaches a registered directory inside the repo checkout"
}

test_sweep_never_signals_the_sweeping_shell() {
  local harness root rc=0
  harness=$(fm_test_tmproot fm-test-cleanup-sweep-self)
  root="$harness/self"
  mkdir -p "$root"
  : > "$root/.fm-test-fixture"
  # A shell whose OWN cwd is inside the root it sweeps must survive: the child
  # cd's in, sweeps, and only then reports. TMPDIR is pointed at the harness so
  # the root qualifies while staying inside this test's own fixture tree.
  TMPDIR="$harness" bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    cd "$1" || exit 9
    fm_test_sweep_leaked_processes "$1" || exit 8
    printf "survived\n"
  ' _ "$root" > "$harness/out" 2>"$harness/err" || rc=$?

  expect_code 0 "$rc" "a shell sweeping the root it is sitting in did not survive"
  assert_grep survived "$harness/out" \
    "the sweeping shell was signalled by its own sweep"
  pass "the sweep never signals the shell performing it"
}

test_orphan_sweep_reaps_processes_left_in_a_stale_root() {
  local stale_dir pid alive
  # The accumulation path: a prior run killed hard enough to skip its traps
  # leaves both a root and processes inside it. The next source must clear both.
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale-procs.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  pid=$(start_cwd_sleeper "$stale_dir") || fail "the stale-root sleeper never started"
  track_sleeper "$pid"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" "the orphan reaper left the stale fixture root behind"
  alive=0
  if proc_is_alive "$pid"; then
    alive=1
    reap_sleeper "$pid"
  fi
  [ "$alive" -eq 0 ] \
    || fail "the orphan reaper removed a stale fixture root but left its leaked process running"
  pass "the orphan sweep reaps processes left inside a stale fixture root, not just the root"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_cleanup_sweeps_processes_leaked_in_its_own_root
test_sweep_cannot_reach_outside_its_own_root
test_sweep_refuses_unmarked_and_non_tmpdir_roots
test_sweep_kills_a_process_that_ignores_term
test_sweep_leaves_a_pid_alone_once_its_identity_no_longer_matches
test_sweep_never_reaches_a_registered_repo_checkout_dir
test_sweep_never_signals_the_sweeping_shell
test_orphan_sweep_reaps_processes_left_in_a_stale_root
