#!/usr/bin/env bash
# tests/fm-sprint-poll.test.sh - behavior tests for bin/fm-sprint-poll.sh.
#
# The script is offline by construction: it cannot read the board and never
# tries, so nothing here touches the network. Every case is a pure function of
# config, clock and stamp file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-sprint-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-sprint-poll)

run() {  # <dir> [extra-env...]
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
      FM_CONFIG_OVERRIDE="$1/config" FM_STATE_OVERRIDE="$1/state" "$POLL"
}

setup() {  # <dir> <config-body>
  local d=$1
  mkdir -p "$d/config" "$d/state"
  [ -z "$2" ] || printf '%s\n' "$2" > "$d/config/sprint-poll.env"
}

# The load-bearing guarantee: until the captain opts in, the watcher's behaviour
# must be unchanged byte for byte. A stray character here would wake the fleet.
test_inert_without_config() {
  local d out
  d="$TMP_ROOT/inert"; setup "$d" ""
  out=$(run "$d"); expect_code 0 $? "an unconfigured poll must exit 0"
  [ -z "$out" ] || fail "an unconfigured poll must print NOTHING, got: '$out'"
  [ ! -f "$d/state/sprint-poll.last" ] || fail "an unconfigured poll must not write state"
  pass "fm-sprint-poll.sh: inert without config - no output, no state, exit 0"
}

# Outside the working window every wake is spend against an empty board.
test_outside_window_is_silent() {
  local d out h
  d="$TMP_ROOT/window"
  # A window that cannot contain the current hour, whatever it is.
  h=$(date +%-H)
  if [ "$h" -lt 12 ]; then setup "$d" 'FM_SPRINT_HOURS=20-23'; else setup "$d" 'FM_SPRINT_HOURS=0-1'; fi
  out=$(run "$d"); expect_code 0 $? "an out-of-window poll must exit 0"
  [ -z "$out" ] || fail "an out-of-window poll must stay silent, got: '$out'"
  pass "fm-sprint-poll.sh: silent outside the working window"
}

test_emits_once_then_holds_for_the_interval() {
  local d first second
  d="$TMP_ROOT/interval"
  setup "$d" 'FM_SPRINT_HOURS=0-23
FM_SPRINT_DAYS=1-7
FM_SPRINT_INTERVAL=3600'

  first=$(run "$d")
  [ "$first" = "sprint-check" ] || fail "the first due poll must emit sprint-check, got: '$first'"

  # Immediately again: the interval has not elapsed, so this must be silent.
  # Two wakes for one interval means paying for two agent turns to answer one
  # question - the exact race the atomic stamp exists to prevent.
  second=$(run "$d")
  [ -z "$second" ] || fail "a second poll inside the interval must be silent, got: '$second'"
  pass "fm-sprint-poll.sh: emits once when due, then holds until the interval elapses"
}

test_emits_again_once_the_interval_has_passed() {
  local d out
  d="$TMP_ROOT/elapsed"
  setup "$d" 'FM_SPRINT_HOURS=0-23
FM_SPRINT_DAYS=1-7
FM_SPRINT_INTERVAL=60'
  # A stamp far enough in the past that the interval has clearly elapsed.
  printf '%s\n' "$(( $(date +%s) - 600 ))" > "$d/state/sprint-poll.last"
  out=$(run "$d")
  [ "$out" = "sprint-check" ] || fail "a poll after the interval must emit, got: '$out'"
  pass "fm-sprint-poll.sh: emits again once the interval has elapsed"
}

# A corrupt stamp must not wedge the poll forever - silence would be permanent.
test_corrupt_stamp_does_not_wedge_the_poll() {
  local d out
  d="$TMP_ROOT/corrupt"
  setup "$d" 'FM_SPRINT_HOURS=0-23
FM_SPRINT_DAYS=1-7
FM_SPRINT_INTERVAL=60'
  printf 'not-a-timestamp\n' > "$d/state/sprint-poll.last"
  out=$(run "$d")
  [ "$out" = "sprint-check" ] || fail "a corrupt stamp must be treated as never-polled, got: '$out'"
  pass "fm-sprint-poll.sh: a corrupt stamp is treated as never-polled rather than wedging silence"
}

test_inert_without_config
test_outside_window_is_silent
test_emits_once_then_holds_for_the_interval
test_emits_again_once_the_interval_has_passed
test_corrupt_stamp_does_not_wedge_the_poll

# The shim is what makes the poll reachable at all: the watcher sweeps
# state/*.check.sh and nothing else. It was first created by hand, which worked
# in one home and would have been silently absent in every other - so bootstrap
# owning it is the actual fix, and this test is the one that would have caught
# the omission.
test_bootstrap_owns_the_shim() {
  local d shim
  d="$TMP_ROOT/shim"; mkdir -p "$d/config" "$d/state" "$d/data" "$d/projects"
  shim="$d/state/sprint-watch.check.sh"

  run_bootstrap() {
    env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$d" FM_CONFIG_OVERRIDE="$d/config" \
        FM_STATE_OVERRIDE="$d/state" FM_DATA_OVERRIDE="$d/data" \
        FM_PROJECTS_OVERRIDE="$d/projects" bash "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  }

  run_bootstrap
  [ ! -e "$shim" ] || fail "with no config the shim must NOT exist - the watcher must be untouched until opt-in"

  printf 'FM_SPRINT_INTERVAL=3600\n' > "$d/config/sprint-poll.env"
  run_bootstrap
  [ -x "$shim" ] || fail "bootstrap must create an executable shim once sprint-poll.env exists"
  grep -q 'fm-sprint-poll.sh' "$shim" || fail "the shim must forward to the repository script, not reimplement it"

  rm -f "$d/config/sprint-poll.env"
  run_bootstrap
  [ ! -e "$shim" ] || fail "removing the config must remove the shim, or the poll outlives its opt-in"
  pass "fm-sprint-poll.sh: bootstrap creates and removes the watcher shim with the config"
}

test_bootstrap_owns_the_shim
