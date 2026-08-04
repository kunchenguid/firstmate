#!/usr/bin/env bash
# tests/fm-away-health.test.sh - the three-state away-supervision verdict
# (bin/fm-away-session.sh health).
#
# The away flag records that away mode was ENTERED. The supervisor dies on a
# session, process or host restart while that flag survives, so reading health
# from the flag states something false exactly when it matters most. This file
# pins that the verdict comes from the supervisor lock's liveness and that the
# three outcomes stay distinct:
#
#   active   the lock names a live process whose identity still matches
#   down     provably not running - no lock, a dead recorded pid, a recycled
#            pid, or a pid running something else
#   unknown  the lock exists but liveness genuinely cannot be decided here
#
# The unknown case is the one a boolean predicate would silently fold into
# "down", so it is driven deliberately: a live process whose identity cannot be
# read because neither a /proc-compatible source nor ps is available.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SESSION="$ROOT/bin/fm-away-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-away-health-tests)
SLEEPERS=""
cleanup() {
  local pid
  for pid in $SLEEPERS; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

health() {  # <home> [extra env assignments handled by caller]
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$SESSION" health
}

report() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$SESSION" health --report
}

field() {  # <health-output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

expect_supervision() {  # <home> <expected> <label>
  local out got
  out=$(health "$1")
  got=$(field "$out" supervision)
  [ "$got" = "$2" ] || fail "$3: supervision=$got, expected $2 (detail: $(field "$out" detail))"
}

# start_daemon_shaped_process <home>: a real process whose command line names
# the supervise daemon, so the identity-free fallback path recognises it.
start_daemon_shaped_process() {  # <home>
  local home=$1 script="$1/fm-supervise-daemon.sh" pid
  printf '#!/usr/bin/env bash\nexec sleep 300\n' > "$script"
  chmod +x "$script"
  # stdout and stderr are closed off deliberately: this helper runs inside a
  # command substitution, and a background child holding that pipe open would
  # make the substitution wait for the whole sleep.
  "$script" >/dev/null 2>&1 &
  pid=$!
  SLEEPERS="$SLEEPERS $pid"
  printf '%s\n' "$pid"
}

write_lock() {  # <home> <pid> [identity]
  local home=$1 pid=$2 identity=${3:-}
  mkdir -p "$home/state/.supervise-daemon.lock"
  printf '%s' "$pid" > "$home/state/.supervise-daemon.lock/pid"
  [ -z "$identity" ] || printf '%s' "$identity" > "$home/state/.supervise-daemon.lock/pid-identity"
}

identity_of() {  # <pid>
  bash -c '. "$1"/bin/fm-wake-lib.sh >/dev/null 2>&1; fm_pid_identity "$2"' _ "$ROOT" "$1"
}

# --- the three states -------------------------------------------------------

test_no_lock_is_down() {
  local home
  home=$(new_home no-lock)
  : > "$home/state/.afk"
  expect_supervision "$home" down 'away flag with no supervisor lock'
  case "$(report "$home")" in
    *"supervision is NOT running"*) : ;;
    *) fail "the report did not say supervision was not running: $(report "$home")" ;;
  esac
  pass "an away flag with no supervisor lock reports supervision down, not active"
}

test_a_live_matching_daemon_is_active() {
  local home pid
  home=$(new_home live-daemon)
  : > "$home/state/.afk"
  pid=$(start_daemon_shaped_process "$home")
  write_lock "$home" "$pid" "$(identity_of "$pid")"
  expect_supervision "$home" active 'live daemon with a matching identity'
  case "$(report "$home")" in
    *"supervision is running"*) : ;;
    *) fail "the report did not recognise a live supervisor: $(report "$home")" ;;
  esac
  pass "a live supervisor whose recorded identity still matches reports active"
}

test_a_dead_recorded_pid_is_down() {
  local home pid
  home=$(new_home dead-pid)
  : > "$home/state/.afk"
  pid=$(start_daemon_shaped_process "$home")
  write_lock "$home" "$pid" "$(identity_of "$pid")"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_supervision "$home" down 'lock naming a dead pid'
  pass "a lock left behind by a dead supervisor reports down"
}

test_a_recycled_pid_is_down() {
  local home pid
  home=$(new_home recycled-pid)
  : > "$home/state/.afk"
  pid=$(start_daemon_shaped_process "$home")
  # The pid is alive, but the recorded identity belongs to a different process,
  # which is exactly what a pid reused after a host restart looks like.
  write_lock "$home" "$pid" 'proc-starttime=1 cmdline-hex=deadbeef'
  expect_supervision "$home" down 'live pid whose recorded identity does not match'
  pass "a recorded pid recycled by an unrelated process reports down, not active"
}

test_an_unrelated_live_command_is_down() {
  local home pid
  home=$(new_home unrelated-command)
  : > "$home/state/.afk"
  sleep 300 >/dev/null 2>&1 &
  pid=$!
  SLEEPERS="$SLEEPERS $pid"
  # No identity file, so the verdict falls back to the command line, which
  # names something that is not the supervisor.
  write_lock "$home" "$pid"
  expect_supervision "$home" down 'live pid running an unrelated command'
  pass "a lock whose live pid runs an unrelated command reports down"
}

test_an_unreadable_owner_pid_is_unknown() {
  local home
  home=$(new_home unreadable-pid)
  : > "$home/state/.afk"
  mkdir -p "$home/state/.supervise-daemon.lock"
  : > "$home/state/.supervise-daemon.lock/pid"
  expect_supervision "$home" unknown 'lock present with an unreadable owner pid'
  pass "a lock with no readable owner pid reports unknown rather than guessing"
}

test_an_unreadable_identity_source_is_unknown() {
  local home pid fakebin out
  home=$(new_home unknown-identity)
  : > "$home/state/.afk"
  pid=$(start_daemon_shaped_process "$home")
  write_lock "$home" "$pid" "$(identity_of "$pid")"

  # Neither identity source is usable: no /proc-compatible tree, and a ps that
  # cannot answer. The process is genuinely alive, so "down" would be a lie and
  # "active" would be unproven.
  fakebin="$home/fakebin"
  mkdir -p "$fakebin" "$home/empty-proc"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/ps"
  chmod +x "$fakebin/ps"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROC_ROOT_OVERRIDE="$home/empty-proc" PATH="$fakebin:$PATH" \
    "$SESSION" health)
  [ "$(field "$out" supervision)" = unknown ] \
    || fail "an undecidable liveness read reported $(field "$out" supervision), expected unknown"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PROC_ROOT_OVERRIDE="$home/empty-proc" PATH="$fakebin:$PATH" \
    "$SESSION" health --report)
  case "$out" in
    *"could not be determined"*) : ;;
    *) fail "the unknown report did not say so plainly: $out" ;;
  esac
  case "$out" in
    *"supervision is running"*) fail "an undetermined state was reported as running: $out" ;;
  esac
  pass "a liveness read that genuinely cannot be decided reports unknown, never active and never down"
}

test_no_away_flag_reports_absent() {
  local home out
  home=$(new_home no-flag)
  out=$(health "$home")
  [ "$(field "$out" away)" = inactive ] || fail "away state was not reported inactive"
  [ "$(report "$home")" = absent ] || fail "the report for a home not in away mode was not 'absent'"
  pass "a home that is not in away mode reports absent"
}

test_no_lock_is_down
test_a_live_matching_daemon_is_active
test_a_dead_recorded_pid_is_down
test_a_recycled_pid_is_down
test_an_unrelated_live_command_is_down
test_an_unreadable_owner_pid_is_unknown
test_an_unreadable_identity_source_is_unknown
test_no_away_flag_reports_absent

echo "# fm-away-health.test.sh: all assertions passed"
