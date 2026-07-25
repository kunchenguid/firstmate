#!/usr/bin/env bash
# tests/fm-session-lock-liveness.test.sh - the holder-liveness predicate of the
# shared session-lock harness identity (bin/fm-session-lock-lib.sh), the ONE
# owner every mutual-exclusion consumer delegates to: bin/fm-lock.sh acquire and
# status, and bin/fm-claude-stop-autoarm.sh's stale-owner reclaim.
#
# The load-bearing contract, task fm-session-lock-liveness-pi-bug:
#   1. fm_harness_pid_alive tests the BASENAME of `ps -o comm=` on its own line.
#      Joining comm and `ps -o args=` into one line broke every anchored
#      alternative in FM_HARNESS_RE: a live pi harness joins to "pi pi", which
#      `^pi$` cannot match, so each live pi session read as stale and a second
#      session could take its lock - a whole-home mutual-exclusion failure.
#   2. args is consulted ONLY when comm is a bare interpreter (node/python),
#      exactly as fm_harness_ancestry_pid already does it.
#   3. The anchored `^pi$` alternative stays anchored: `pip`, `pipx`, and any
#      non-harness process whose path merely contains "pi" must read as
#      not-a-harness.
#   4. The other verified harnesses (claude, codex, opencode, grok) keep reading
#      as alive, and a dead pid still reads as not alive.
#
# Processes here are real: each case spawns a bash symlink under the case's own
# temp dir so `ps -o comm=` reports the tested command name, with no fake ps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-liveness)

SPAWNED_PIDS=()

cleanup_spawned() {
  local p
  for p in "${SPAWNED_PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup_spawned EXIT

# spawn_named <dir> <command-name> [extra-argv...]: sets SPAWNED_PID to a live
# process whose `ps -o comm=` is <command-name>.
#
# Creates <dir>/<command-name> as a bash symlink and runs it as a background
# sleeper, so ps reports that name in comm and its own path in args. Two details
# are load-bearing: the script body is two commands because bash execs a lone
# simple command in place (which would replace the tested comm with "sleep"),
# and the pid is returned through a global rather than command substitution
# because a long-lived child holding the substitution pipe open would stall the
# reader.
SPAWNED_PID=

spawn_named() {
  local dir=$1 name=$2 waited=0
  shift 2
  mkdir -p "$dir"
  [ -e "$dir/$name" ] || ln -s /bin/bash "$dir/$name"
  "$dir/$name" -c 'sleep 30; :' "$@" >/dev/null 2>&1 &
  SPAWNED_PID=$!
  SPAWNED_PIDS+=("$SPAWNED_PID")
  # Wait for the process to be observable by ps before asserting on it.
  while [ "$waited" -lt 20 ]; do
    [ -n "$(ps -o comm= -p "$SPAWNED_PID" 2>/dev/null)" ] && break
    sleep 0.05
    waited=$((waited + 1))
  done
}

# --- the fix: an anchored harness name still matches a live process ----------

test_live_pi_process_reads_alive() {
  spawn_named "$TMP_ROOT/pi-live" pi
  fm_harness_pid_alive "$SPAWNED_PID" \
    || fail "a live pi process must read as a live harness (comm=$(ps -o comm= -p "$SPAWNED_PID" 2>/dev/null), args=$(ps -o args= -p "$SPAWNED_PID" 2>/dev/null))"
  pass "fm_harness_pid_alive: a live pi process reads as alive"
}

test_other_verified_harnesses_read_alive() {
  local name
  for name in claude codex opencode grok; do
    spawn_named "$TMP_ROOT/harness-$name" "$name"
    fm_harness_pid_alive "$SPAWNED_PID" \
      || fail "a live $name process must read as a live harness"
  done
  pass "fm_harness_pid_alive: claude, codex, opencode and grok keep reading as alive"
}

test_bare_interpreter_matches_harness_in_args() {
  # comm is a bare interpreter, so the harness name is only findable in args -
  # the one case where consulting args is correct.
  spawn_named "$TMP_ROOT/interp" node claude
  fm_harness_pid_alive "$SPAWNED_PID" \
    || fail "a bare interpreter whose args name a harness must read as alive"
  pass "fm_harness_pid_alive: a bare node interpreter matches the harness named in its args"
}

# --- the anchor holds: pi-lookalikes are not harnesses ----------------------

test_pi_lookalikes_are_not_harnesses() {
  local name
  for name in pip pipx; do
    spawn_named "$TMP_ROOT/lookalike-$name" "$name"
    ! fm_harness_pid_alive "$SPAWNED_PID" \
      || fail "$name must read as not-a-harness (^pi\$ must stay anchored)"
  done
  pass "fm_harness_pid_alive: pip and pipx read as not-a-harness"
}

test_path_containing_pi_is_not_a_harness() {
  # A non-harness command living under a directory whose name contains "pi":
  # the substring must never be enough, in comm or in args.
  spawn_named "$TMP_ROOT/pipeline/bin" sleeper
  ! fm_harness_pid_alive "$SPAWNED_PID" \
    || fail "a non-harness process under a path containing 'pi' must read as not-a-harness"
  pass "fm_harness_pid_alive: a path merely containing 'pi' is not a harness"
}

test_plain_non_harness_is_not_a_harness() {
  spawn_named "$TMP_ROOT/plain" sleeper
  ! fm_harness_pid_alive "$SPAWNED_PID" \
    || fail "an unrelated live process must read as not-a-harness"
  pass "fm_harness_pid_alive: an unrelated live process reads as not-a-harness"
}

test_dead_pid_is_not_alive() {
  local pid
  spawn_named "$TMP_ROOT/dead" pi
  pid=$SPAWNED_PID
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
  ! fm_harness_pid_alive "$pid" \
    || fail "a dead pid must never read as a live harness"
  pass "fm_harness_pid_alive: a dead pid reads as not alive"
}

# --- the consumer contract: fm-lock.sh status agrees ------------------------

test_fm_lock_status_recognizes_live_pi_holder() {
  local home pid out
  home="$TMP_ROOT/lock-home"
  mkdir -p "$home/state"
  spawn_named "$TMP_ROOT/lock-harness" pi
  pid=$SPAWNED_PID
  printf '%s\n' "$pid" > "$home/state/.lock"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid $pid" \
    "fm-lock.sh status must report a live pi holder as held, not stale"
  pass "fm-lock.sh status: a live pi lock holder is reported as held"
}

test_fm_lock_status_reports_pip_holder_as_stale() {
  local home pid out
  home="$TMP_ROOT/lock-home-pip"
  mkdir -p "$home/state"
  spawn_named "$TMP_ROOT/lock-pip" pip
  pid=$SPAWNED_PID
  printf '%s\n' "$pid" > "$home/state/.lock"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: stale (pid $pid dead or not a harness)" \
    "fm-lock.sh status must not accept a live pip process as a harness holder"
  pass "fm-lock.sh status: a live pip process is not accepted as a lock holder"
}

test_live_pi_process_reads_alive
test_other_verified_harnesses_read_alive
test_bare_interpreter_matches_harness_in_args
test_pi_lookalikes_are_not_harnesses
test_path_containing_pi_is_not_a_harness
test_plain_non_harness_is_not_a_harness
test_dead_pid_is_not_alive
test_fm_lock_status_recognizes_live_pi_holder
test_fm_lock_status_reports_pip_holder_as_stale
