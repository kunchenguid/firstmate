#!/usr/bin/env bash
# Behavioral coverage for fast mode's port choice: a busy preferred port is
# skipped, and whoever holds it is left running. Preempting instead would
# silently kill the captain's own instance.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAST="$ROOT/bin/fm-fast-mode.sh"

for tool in node python3 lsof curl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "skip: $tool not found"
    exit 0
  }
done

TMP_ROOT=$(fm_test_tmproot fm-fast-mode)
HOME_DIR="$TMP_ROOT/home"
WT="$TMP_ROOT/worktree"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config/fast-mode" "$WT"

OCCUPANT=
# shellcheck disable=SC2329 # invoked by the EXIT trap below.
cleanup() {
  [ -n "$OCCUPANT" ] && kill "$OCCUPANT" 2>/dev/null
  (cd "$WT" && FM_HOME="$HOME_DIR" "$FAST" stop >/dev/null 2>&1)
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

serve() { # serve <port> - background http server, echo its pid
  python3 -m http.server "$1" --bind 127.0.0.1 >/dev/null 2>&1 &
  printf '%s\n' "$!"
}

wait_for_port() { # wait_for_port <port>
  local i
  for i in $(seq 1 50); do
    lsof -ti "tcp:$1" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  return 1
}

free_port_base() {
  local base i
  base=$((20000 + RANDOM % 20000))
  for i in $(seq 0 200); do
    if ! lsof -ti "tcp:$((base + i))" >/dev/null 2>&1 &&
      ! lsof -ti "tcp:$((base + i + 1))" >/dev/null 2>&1 &&
      ! lsof -ti "tcp:$((base + i + 2))" >/dev/null 2>&1 &&
      ! lsof -ti "tcp:$((base + i + 3))" >/dev/null 2>&1; then
      printf '%s\n' "$((base + i))"
      return 0
    fi
  done
  return 1
}

BASE=$(free_port_base) || fail "no free port block for the fixture"
PREF_API=$BASE
PREF_WEB=$((BASE + 2))
PREF_PROXY=$((BASE + 3))

cat >"$HOME_DIR/config/fast-mode/fixture.sh" <<EOF
FAST_PREF_API=$PREF_API
FAST_PREF_WEB=$PREF_WEB
FAST_PREF_PROXY=$PREF_PROXY
FAST_READY_TIMEOUT=30

fast_start_api() {
  fast_bg api python3 -m http.server "\$FAST_API_PORT" --bind 127.0.0.1
}

fast_start_web() {
  fast_bg web python3 -m http.server "\$FAST_WEB_PORT" --bind 127.0.0.1
}
EOF

# Somebody else already holds the preferred backend port.
OCCUPANT=$(serve "$PREF_API")
wait_for_port "$PREF_API" || fail "fixture occupant never bound $PREF_API"

out=$(cd "$WT" && FM_HOME="$HOME_DIR" "$FAST" up fixture-task fixture 2>&1)
code=$?
expect_code 0 "$code" "up on an occupied preferred port"$'\n'"$out"

assert_contains "$out" "port $PREF_API is busy, using $((PREF_API + 1))" "bump is reported"
assert_grep "api $((PREF_API + 1))" "$WT/.fast-mode/ports" "chosen backend port is recorded"
assert_grep "web $PREF_WEB" "$WT/.fast-mode/ports" "free preferred frontend port is kept"
assert_grep "port	$((PREF_API + 1))" "$HOME_DIR/state/fixture-task.bg" "chosen port is registered in the ledger"

kill -0 "$OCCUPANT" 2>/dev/null || fail "the occupant of $PREF_API was killed"
pass "busy preferred port is skipped, not preempted"

out=$(cd "$WT" && FM_HOME="$HOME_DIR" "$FAST" stop 2>&1)
kill -0 "$OCCUPANT" 2>/dev/null || fail "stop killed the occupant of $PREF_API"
lsof -ti "tcp:$((PREF_API + 1))" >/dev/null 2>&1 && fail "stop left the recorded backend port running"
pass "stop clears only the ports this worktree recorded"

exit 0
