#!/usr/bin/env bash
# tests/fm-session-lock-zombie.test.sh - a zombie lock holder must be reclaimable
# (bin/fm-session-lock-lib.sh's fm_pid_is_zombie/fm_harness_pid_alive, exercised
# through the real bin/fm-lock.sh).
#
# Reproduces the incident this guards against: a harness process exits but its
# parent never reaps it, so it lingers as a zombie. `kill -0` still succeeds on a
# zombie and `ps` still reports its original comm, so before the fix
# fm_harness_pid_alive read it as a live lock holder forever, with no way to
# reclaim the home's session lock short of deleting state/.lock by hand.
#
# Every fixture here is a REAL process, not a faked ps table: a zombie is
# constructed by forking a child that execs into a binary literally named
# "claude" and exits, while its parent deliberately never calls wait() on it.
# The kernel sets a process's reported comm from the basename of the exec'd
# pathname, not argv[0], so a "claude"-named symlink stays "claude" even once
# defunct - this is why the fixture execs a symlink rather than using
# `exec -a`, which only overrides argv[0] and would not survive as the zombie's
# reported name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-zombie)
LIB="$ROOT/bin/fm-session-lock-lib.sh"

# --- fixture plumbing --------------------------------------------------------

ZOMBIE_PARENT_PIDS=()

cleanup_zombie_parents() {
  local pid
  for pid in "${ZOMBIE_PARENT_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  for pid in "${ZOMBIE_PARENT_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null
  done
}
trap 'cleanup_zombie_parents; fm_test_cleanup' EXIT

# make_zombie_pid <name>: exec a symlink named <name> pointing at /bin/true from
# a forked child, print the child's pid, and never wait() on it from the parent.
# The parent sleeps so the child stays parented (and thus unreaped) until this
# suite kills it at exit; a child reparented to init would be reaped instantly.
make_zombie_pid() {
  local name=$1 targetdir pidfile parent pid
  targetdir="$TMP_ROOT/zombie-target-$name-$$-${RANDOM:-0}"
  mkdir -p "$targetdir"
  ln -sf /bin/true "$targetdir/$name"
  pidfile="$TMP_ROOT/zombie-pidfile-$name-$$-${RANDOM:-0}"
  perl -e '
    $| = 1;
    my $pid = fork();
    if ($pid == 0) {
      exec($ARGV[0]);
      exit 1;
    }
    print "$pid\n";
    sleep 30;
  ' "$targetdir/$name" > "$pidfile" &
  parent=$!
  ZOMBIE_PARENT_PIDS+=("$parent")
  for _ in $(seq 1 50); do
    [ -s "$pidfile" ] && break
    sleep 0.1
  done
  [ -s "$pidfile" ] || fail "zombie fixture ($name) never reported its child pid"
  pid=$(tr -d '[:space:]' < "$pidfile")
  for _ in $(seq 1 50); do
    [ "$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')" = Z ] && break
    sleep 0.1
  done
  [ "$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')" = Z ] \
    || fail "zombie fixture ($name) did not produce a defunct process (pid $pid)"
  printf '%s\n' "$pid"
}

# make_live_named_pid <name> <seconds>: background a real, live process whose
# comm is literally <name> (again via a symlink, so it also matches the harness
# name regex without any faked ps), and print its pid. The backgrounded process
# must not inherit this function's own stdout: this runs inside a caller's
# command substitution, and an inherited stdout pipe stays open for as long as
# the background job runs, which would block the caller on that pipe's EOF
# instead of returning the pid immediately.
make_live_named_pid() {
  local name=$1 seconds=$2 targetdir pid
  targetdir="$TMP_ROOT/live-target-$name-$$-${RANDOM:-0}"
  mkdir -p "$targetdir"
  ln -sf /bin/sleep "$targetdir/$name"
  "$targetdir/$name" "$seconds" >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid"
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

run_lib() {  # <expression>
  bash -c ". \"\$0\"; $1" "$LIB"
}

# --- unit layer: fm_pid_is_zombie / fm_harness_pid_alive on real processes ---

test_zombie_harness_pid_is_not_alive() {
  local zpid
  zpid=$(make_zombie_pid claude)
  run_lib "fm_pid_is_zombie $zpid" \
    || fail "a real zombie process was not classified as a zombie (pid $zpid)"
  if run_lib "fm_harness_pid_alive $zpid"; then
    fail "a zombie whose comm is a verified harness name was still read as a live lock holder (pid $zpid)"
  fi
  pass "session-lock: a zombie harness process is not classified as a live lock holder"
}

test_live_harness_pid_is_still_alive() {
  local lpid
  lpid=$(make_live_named_pid claude 20)
  if run_lib "fm_pid_is_zombie $lpid"; then
    kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null
    fail "a genuinely running process was misclassified as a zombie (pid $lpid)"
  fi
  run_lib "fm_harness_pid_alive $lpid" \
    || { kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null; fail "a genuinely live harness process was not recognized as alive (pid $lpid) - the fix must not make every lock reclaimable"; }
  kill "$lpid" 2>/dev/null
  wait "$lpid" 2>/dev/null
  pass "session-lock: a genuinely live harness process is still recognized as a live lock holder (negative control)"
}

test_nonexistent_pid_is_still_not_alive() {
  local dead
  dead=$(nonexistent_pid)
  if run_lib "fm_pid_is_zombie $dead"; then
    fail "a pid that does not exist at all was classified as a zombie (pid $dead)"
  fi
  if run_lib "fm_harness_pid_alive $dead"; then
    fail "a pid that does not exist at all was classified as a live lock holder (pid $dead)"
  fi
  pass "session-lock: a nonexistent pid is unaffected by the zombie check"
}

test_live_non_harness_pid_is_still_not_a_holder() {
  local lpid
  lpid=$(make_live_named_pid sleep 20)
  if run_lib "fm_harness_pid_alive $lpid"; then
    kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null
    fail "a live process with an ordinary (non-harness) name was classified as a lock holder (pid $lpid)"
  fi
  kill "$lpid" 2>/dev/null
  wait "$lpid" 2>/dev/null
  pass "session-lock: a live non-harness pid is unaffected by the zombie check"
}

# --- end-to-end layer: the real fm-lock.sh reclaims a zombie-held lock -------

test_e2e_fm_lock_reclaims_a_zombie_held_lock() {
  local dir fakebin zpid out rc
  dir="$TMP_ROOT/e2e-zombie"
  mkdir -p "$dir/state"
  fakebin="$TMP_ROOT/e2e-zombie-caller/fakebin"
  mkdir -p "$fakebin"
  # This test process itself must resolve as a harness ancestor for fm-lock.sh
  # to identify "me", exactly like the unit fixtures above: exec a
  # "claude"-named symlink so the real ps-reported comm matches, with no faked
  # ps table anywhere in this test.
  ln -sf /bin/bash "$fakebin/claude"

  zpid=$(make_zombie_pid claude)
  printf '%s\n' "$zpid" > "$dir/state/.lock"

  out=$(FM_HOME="$dir" "$fakebin/claude" "$ROOT/bin/fm-lock.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lock.sh refused to reclaim a lock held by a dead zombie (pid $zpid): $out"
  assert_contains "$out" "lock acquired" "fm-lock.sh did not report acquiring the lock from a zombie holder: $out"
  pass "session-lock e2e: fm-lock.sh reclaims a lock held by a zombie that was never reaped"
}

test_e2e_fm_lock_still_refuses_a_live_holder() {
  local dir fakebin lpid out rc
  dir="$TMP_ROOT/e2e-live-holder"
  mkdir -p "$dir/state"
  fakebin="$TMP_ROOT/e2e-live-caller/fakebin"
  mkdir -p "$fakebin"
  ln -sf /bin/bash "$fakebin/claude"

  lpid=$(make_live_named_pid claude 20)
  printf '%s\n' "$lpid" > "$dir/state/.lock"

  out=$(FM_HOME="$dir" "$fakebin/claude" "$ROOT/bin/fm-lock.sh" 2>&1)
  rc=$?
  kill "$lpid" 2>/dev/null
  wait "$lpid" 2>/dev/null
  [ "$rc" -ne 0 ] \
    || fail "fm-lock.sh acquired a lock still held by a genuinely live harness process (pid $lpid): $out - the fix must not make every lock reclaimable"
  assert_contains "$out" "another live firstmate session holds the lock" \
    "fm-lock.sh's refusal text changed for a genuinely live holder: $out"
  pass "session-lock e2e: fm-lock.sh still refuses a lock held by a genuinely live harness process (negative control)"
}

test_zombie_harness_pid_is_not_alive
test_live_harness_pid_is_still_alive
test_nonexistent_pid_is_still_not_alive
test_live_non_harness_pid_is_still_not_a_holder
test_e2e_fm_lock_reclaims_a_zombie_held_lock
test_e2e_fm_lock_still_refuses_a_live_holder
