#!/usr/bin/env bash
# Behavior tests for bin/fm-kill-port.sh.
#
# The script exists because a crewmate that frees a port with a name pattern
# (`pkill -f 'wrangler dev'`) cannot tell its own server from a sibling
# worktree's or the captain's - one such call killed the captain's dev server.
# Killing by port removes the pattern, and the boundary check is what makes a
# WRONG port number a refusal instead of a second incident. These tests drive
# real listeners through the command line, never the script's source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-kill-port) || fail "could not create temp root"
INSIDE="$TMP_ROOT/inside"
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$INSIDE" "$OUTSIDE"
# The script reports symlink-resolved paths (on macOS /var is a link to /private/var),
# so compare against the same resolved form rather than the literal temp path.
OUTSIDE_REAL=$(cd "$OUTSIDE" && pwd -P)

KILL_PORT="$ROOT/bin/fm-kill-port.sh"

# Ports well above the ephemeral ranges these tests could collide with.
PORT_A=64811
PORT_B=64812

listener_pids=()

# Start a listener whose working directory is $1, on port $2. Echoes its pid.
start_listener() {
  local cwd=$1 port=$2 pid
  (cd "$cwd" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
  pid=$!
  listener_pids+=("$pid")
  local waited=0
  while [ "$waited" -lt 30 ]; do
    if lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  fail "listener on port $port never came up"
}

port_is_listening() {
  lsof -tiTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

stop_listeners() {
  local pid
  for pid in "${listener_pids[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  listener_pids=()
}

trap 'stop_listeners; fm_test_cleanup' EXIT

test_requires_at_least_one_port() {
  local out rc
  out=$("$KILL_PORT" 2>&1); rc=$?
  expect_code 2 "$rc" "no argument must be a usage error"
  assert_contains "$out" "usage:" "bare invocation must print usage"
  pass "fm-kill-port: refuses an empty argument list"
}

test_non_numeric_port_is_refused_without_acting() {
  local out rc
  out=$("$KILL_PORT" notaport 2>&1); rc=$?
  expect_code 1 "$rc" "a non-numeric port must exit non-zero"
  assert_contains "$out" "not a TCP port number" "refusal must name the reason"
  pass "fm-kill-port: refuses a non-numeric port"
}

test_absent_listener_is_reported_and_not_an_error() {
  local out rc
  out=$("$KILL_PORT" --boundary "$INSIDE" "$PORT_A" 2>&1); rc=$?
  expect_code 0 "$rc" "an unused port must not be an error, so repeat calls stay safe"
  assert_contains "$out" "no listener" "an unused port must say so"
  pass "fm-kill-port: an unused port is reported, not an error"
}

test_kills_a_listener_inside_the_boundary() {
  start_listener "$INSIDE" "$PORT_A" >/dev/null
  local out rc
  out=$("$KILL_PORT" --boundary "$INSIDE" "$PORT_A" 2>&1); rc=$?
  expect_code 0 "$rc" "a listener inside the boundary must be killed (got: $out)"
  port_is_listening "$PORT_A" && fail "port $PORT_A still has a listener after the kill"
  pass "fm-kill-port: kills a listener rooted inside the boundary"
}

# The incident guard: a correct port number for someone ELSE's process must not
# be enough. Without this the script is only a nicer spelling of the mistake.
test_refuses_a_listener_outside_the_boundary_and_leaves_it_running() {
  start_listener "$OUTSIDE" "$PORT_B" >/dev/null
  local out rc
  out=$("$KILL_PORT" --boundary "$INSIDE" "$PORT_B" 2>&1); rc=$?
  expect_code 1 "$rc" "a listener outside the boundary must be refused"
  assert_contains "$out" "not yours to kill" "refusal must say whose it is not"
  assert_contains "$out" "$OUTSIDE_REAL" "refusal must name the directory it found"
  port_is_listening "$PORT_B" || fail "refused listener on $PORT_B was killed anyway"
  pass "fm-kill-port: refuses an outside listener and leaves it running"
}

test_any_flag_overrides_the_boundary() {
  # Same outside listener as the previous test, still running because it was refused.
  port_is_listening "$PORT_B" || start_listener "$OUTSIDE" "$PORT_B" >/dev/null
  local out rc
  out=$("$KILL_PORT" --boundary "$INSIDE" --any "$PORT_B" 2>&1); rc=$?
  expect_code 0 "$rc" "--any must kill regardless of where the listener lives (got: $out)"
  port_is_listening "$PORT_B" && fail "port $PORT_B still has a listener after --any"
  pass "fm-kill-port: --any is an explicit escape hatch"
}

test_accepts_several_ports_in_one_call() {
  start_listener "$INSIDE" "$PORT_A" >/dev/null
  start_listener "$INSIDE" "$PORT_B" >/dev/null
  local out rc
  out=$("$KILL_PORT" --boundary "$INSIDE" "$PORT_A" "$PORT_B" 2>&1); rc=$?
  expect_code 0 "$rc" "several ports in one call must all be handled (got: $out)"
  port_is_listening "$PORT_A" && fail "port $PORT_A survived a multi-port call"
  port_is_listening "$PORT_B" && fail "port $PORT_B survived a multi-port call"
  pass "fm-kill-port: frees several ports in one call"
}

# One bad port must not stop the good ones, or a crewmate learns to retry the
# whole list and re-runs kills it already made.
test_one_refusal_does_not_abandon_the_other_ports() {
  start_listener "$INSIDE" "$PORT_A" >/dev/null
  local out rc
  out=$("$KILL_PORT" --boundary "$INSIDE" notaport "$PORT_A" 2>&1); rc=$?
  expect_code 1 "$rc" "a refusal anywhere in the list must surface as non-zero"
  port_is_listening "$PORT_A" && fail "port $PORT_A was skipped because an earlier argument was bad"
  pass "fm-kill-port: a refused argument does not abandon the rest"
}

test_requires_at_least_one_port
test_non_numeric_port_is_refused_without_acting
test_absent_listener_is_reported_and_not_an_error
test_kills_a_listener_inside_the_boundary
test_refuses_a_listener_outside_the_boundary_and_leaves_it_running
test_any_flag_overrides_the_boundary
test_accepts_several_ports_in_one_call
test_one_refusal_does_not_abandon_the_other_ports

echo "# all fm-kill-port tests passed"
