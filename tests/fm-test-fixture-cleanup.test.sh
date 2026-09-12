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
# Three more cases cover the other half of that teardown: a fixture home that
# armed a real process-event listener. A runner is detached and reparents, so
# removing the fixture root does not stop it, and a run that ends by failing or
# by being signalled is exactly the one that used to leave a listener polling a
# target that no longer existed. Those two arm a real runner in a declared home
# and assert the process is gone, identified by the unique blocker path the case
# registered. The third exercises tests/lib.sh's containment default without a
# per-home claim-root override; its home is declared for teardown.
#
# Nothing here inspects tests/lib.sh's source text; it only observes filesystem
# and process state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

# The interrupted-run case below holds a live child test process while it waits.
# That child owns an armed listener, so teardown has to stop it BEFORE the
# fixture roots go: signalled while its own home still exists, it retires the
# listener through its own traps.
#
# The recorded pid alone does not authorize a signal. A child that dies during
# its own startup can be reaped before this suite ever waits for it, which frees
# its pid for the operating system to hand to an unrelated process, and killing
# a stranger from teardown would be a worse defect than the leak. So the pid is
# signalled only while the kernel still reports it as a child of THIS shell -
# ownership of that exact recorded identifier, never a process or script name -
# and it is dropped as soon as the case has waited for it.
HELD_LISTENER_CHILD=

held_listener_child_is_ours() {
  local parent
  [ -n "$HELD_LISTENER_CHILD" ] || return 1
  parent=$(ps -o ppid= -p "$HELD_LISTENER_CHILD" 2>/dev/null | tr -d '[:space:]')
  [ -n "$parent" ] && [ "$parent" = "$$" ]
}

cleanup() {
  if [ -n "$HELD_LISTENER_CHILD" ]; then
    if held_listener_child_is_ours; then
      kill -TERM "$HELD_LISTENER_CHILD" 2>/dev/null || true
      wait "$HELD_LISTENER_CHILD" 2>/dev/null || true
    fi
    HELD_LISTENER_CHILD=
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 131' QUIT

wait_for_file() {  # <path> [tries]
  local tries=${2:-200}
  while [ "$tries" -gt 0 ]; do
    [ -s "$1" ] && return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

# Is the armed listener still running? Identified by the unique blocker path
# THIS case registered, never by a script or process name: an orphan left by
# this test has to be distinguishable from any other listener on the machine,
# including a live one that has nothing to do with the suite.
listener_alive() {  # <pid> <blocker-path>
  local args
  args=$(ps -o args= -p "$1" 2>/dev/null) || return 1
  case "$args" in *"$2"*) return 0 ;; esac
  return 1
}

wait_for_listener_exit() {  # <pid> <blocker-path> [tries]
  local tries=${3:-200}
  while [ "$tries" -gt 0 ]; do
    listener_alive "$1" "$2" || return 0
    sleep 0.05
    tries=$((tries - 1))
  done
  return 1
}

# Build a child test process that arms a real detached process-event runner in
# its own fixture root, declared for reaping the way every suite that opens a
# listener declares one, and then ends the way its argument names. The blocker
# records its pid OUTSIDE the fixture root, so the check survives the root's
# removal and can still name the process after its target is gone.
write_listener_child() {  # <harness>
  local harness=$1
  cat > "$harness/blocker.sh" <<'SH'
#!/usr/bin/env bash
# Records its own pid, then blocks the way a real poll does. The wait is bounded
# so a stub that escapes its test stops on its own instead of polling forever.
printf '%s\n' "$$" > "$1"
while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.2; done
exit 75
SH
  chmod +x "$harness/blocker.sh"
  cat > "$harness/child.sh" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1090
. "$FM_TEST_CHILD_LIB"
root=$(fm_test_tmproot fm-test-cleanup-listener)
home="$root/home"
fm_test_track_procevent_home "$home" "$home/procevent-claims"
mkdir -p "$home/state"
FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
  "$ROOT/bin/fm-procevent.sh" register lavish leaked-src \
  -- "$FM_TEST_CHILD_BLOCKER" "$FM_TEST_CHILD_PIDFILE" >/dev/null
FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
  "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
tries=200
while [ ! -s "$FM_TEST_CHILD_PIDFILE" ]; do
  [ "$tries" -gt 0 ] || { printf 'the listener never started\n' >&2; exit 3; }
  sleep 0.05
  tries=$((tries - 1))
done
printf '%s\n' "$root" > "$FM_TEST_CHILD_ROOTFILE"
case "${1-}" in
  fail) fail "deliberate failure while a listener is armed" ;;
  hold) while :; do sleep 0.1; done ;;
esac
SH
  chmod +x "$harness/child.sh"
}

# Replaces the calling shell, so backgrounding this function makes $! the child
# test process itself. Signalling a wrapper subshell instead would leave the
# child running and prove nothing about its teardown.
run_listener_child() {  # <harness> <mode>
  exec env FM_TEST_CHILD_LIB="$LIB" \
    FM_TEST_CHILD_BLOCKER="$1/blocker.sh" \
    FM_TEST_CHILD_PIDFILE="$1/listener.pid" \
    FM_TEST_CHILD_ROOTFILE="$1/child-root" \
    bash "$1/child.sh" "$2"
}

test_armed_listener_retired_after_failing_exit() {
  local harness rc=0 pid child_root
  harness=$(fm_test_tmproot fm-test-cleanup-listener-fail-harness)
  write_listener_child "$harness"
  ( run_listener_child "$harness" fail ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] \
    || fail "the child never reached its deliberate failure with a listener armed (exit $rc)"
  wait_for_file "$harness/listener.pid" || fail "the child never recorded its listener"
  pid=$(cat "$harness/listener.pid")
  child_root=$(cat "$harness/child-root")
  assert_absent "$child_root" "a failed test left its fixture root behind"
  wait_for_listener_exit "$pid" "$harness/blocker.sh" \
    || fail "a failed test left its listener polling a target it had already removed"
  pass "a failed test retires the listener it armed"
}

test_armed_listener_retired_after_sigterm() {
  local harness pid child_root
  harness=$(fm_test_tmproot fm-test-cleanup-listener-term-harness)
  write_listener_child "$harness"
  run_listener_child "$harness" hold >/dev/null 2>&1 &
  HELD_LISTENER_CHILD=$!
  wait_for_file "$harness/child-root" \
    || fail "the child never armed its listener before the wait timed out"
  pid=$(cat "$harness/listener.pid")
  child_root=$(cat "$harness/child-root")
  listener_alive "$pid" "$harness/blocker.sh" \
    || fail "the child's listener was not running before it was interrupted"
  kill -TERM "$HELD_LISTENER_CHILD"
  wait "$HELD_LISTENER_CHILD" 2>/dev/null
  HELD_LISTENER_CHILD=
  assert_absent "$child_root" "an interrupted run left its fixture root behind"
  wait_for_listener_exit "$pid" "$harness/blocker.sh" \
    || fail "an interrupted run left its listener polling a target it had already removed"
  pass "an interrupted run retires the listener it armed"
}

# A home that names no claim root of its own must still not reach the running
# user's real claim store. HOME and XDG_STATE_HOME are pointed at a scratch
# directory, so the pre-fix fallback would resolve there and is observable:
# either the claim lands under the suite-owned root, or it lands under the
# scratch state directory this case owns.
test_undeclared_home_claims_stay_in_the_suite_owned_root() {
  local root home scratch tries=200
  root=$(fm_test_tmproot fm-test-cleanup-claim-root)
  home="$root/home"
  scratch="$root/scratch"
  fm_test_track_procevent_home "$home"
  mkdir -p "$home/state" "$scratch"
  cat > "$root/blocker.sh" <<'SH'
#!/usr/bin/env bash
while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.2; done
exit 75
SH
  chmod +x "$root/blocker.sh"
  HOME="$scratch" XDG_STATE_HOME="$scratch/state" FM_HOME="$home" \
    "$ROOT/bin/fm-procevent.sh" register lavish contained-src -- "$root/blocker.sh" >/dev/null \
    || fail "the undeclared home could not register its source"
  HOME="$scratch" XDG_STATE_HOME="$scratch/state" FM_HOME="$home" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
    || fail "the undeclared home could not start its source"
  while [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/contained-src.claim" ] && [ "$tries" -gt 0 ]; do
    sleep 0.05
    tries=$((tries - 1))
  done
  assert_present "$FM_PROCEVENT_CLAIM_ROOT/contained-src.claim" \
    "an undeclared home's claim did not land in the suite-owned claim root"
  assert_absent "$scratch/state/firstmate/procevent-claims" \
    "an undeclared home reached the running user's own procevent claim store"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  pass "an undeclared home's claims stay inside the suite-owned claim root"
}

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

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_armed_listener_retired_after_failing_exit
test_armed_listener_retired_after_sigterm
test_undeclared_home_claims_stay_in_the_suite_owned_root
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
