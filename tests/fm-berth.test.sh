#!/usr/bin/env bash
# Behavior tests for fm-berth.sh - opt-in per-project session berths.
#
# The property under test is the one that makes concurrent per-project sessions
# safe: two projects resolve to DIFFERENT state dirs (so their session locks,
# wake queues and task records cannot contend), while a single berth still
# refuses a second live session exactly as the per-home lock does today.
#
# Berths must also be inert by default: with no opt-in flag the home behaves
# precisely as it does now, which is what keeps other operators' homes safe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BERTH="$ROOT/bin/fm-berth.sh"

# A fake harness process that fm_harness_pid_alive classifies exactly as it
# would a real session. It must be a REAL EXECUTABLE named "claude", not a shell
# script named "claude": fm_harness_pid_alive matches `ps -o comm=` (the
# executable name) and only falls back to inspecting full argv for node/python
# processes. A `#!/usr/bin/env bash` script reports comm=bash and is correctly
# rejected, while a live session reports comm=claude - verified against this
# host's own running session. Copying `sleep` reproduces that shape.
start_fake_harness() { # dir -> echoes pid
  local dir=$1 shim="$1/claude" real
  mkdir -p "$dir"
  real=$(command -v sleep) || fail "cannot locate 'sleep' to build the harness shim"
  # SYMLINK, not a copy. fm_harness_pid_alive identifies a holder by the
  # basename of `ps -o comm=`, so the shim must EXEC under the name "claude" -
  # but copying the system `sleep` breaks its Apple code signature, and macOS
  # SIGKILLs the copy the instant it starts ("Killed: 9"). The fake holder was
  # therefore already dead by the time the berth looked, the berth correctly
  # reported a free lock, and the suite blamed the berth for "not refusing a
  # second session". Re-signing with `codesign -s -` does not help; a shell
  # wrapper would not either, since `comm` would then be the interpreter.
  # A symlink execs the real binary while `comm` still resolves to the link
  # name, on both BSD (full path) and Linux (bare name).
  ln -s "$real" "$shim" || fail "cannot create the harness shim at $shim"
  "$shim" 300 >/dev/null 2>&1 &
  echo $!
}

new_home() { # -> echoes a fresh fake FM_HOME
  local h; h=$(fm_test_tmproot)/home
  mkdir -p "$h/config" "$h/state"
  echo "$h"
}

# --- opt-in gate: default behaviour is unchanged ------------------------------

test_disabled_by_default() {
  local home out code
  home=$(new_home)
  out=$(FM_HOME="$home" "$BERTH" env proj 2>&1); code=$?
  [ "$code" -ne 0 ] || fail "berths must refuse without the opt-in flag"
  assert_contains "$out" "not enabled" "refusal names the missing opt-in"
  [ ! -d "$home/state/berths" ] || fail "a disabled home must not gain a berths dir"
  pass "berths are inert until the home opts in"
}

test_enabled_by_flag() {
  local home out
  home=$(new_home); : > "$home/config/berths"
  out=$(FM_HOME="$home" "$BERTH" env proj 2>&1) || fail "env failed once enabled: $out"
  assert_contains "$out" "FM_STATE_OVERRIDE=" "env emits the state override"
  pass "the opt-in flag enables berths"
}

# --- the concurrency property ------------------------------------------------

test_two_projects_get_disjoint_state() {
  local home a b
  home=$(new_home); : > "$home/config/berths"
  a=$(FM_HOME="$home" "$BERTH" path alpha) || fail "path alpha failed"
  b=$(FM_HOME="$home" "$BERTH" path beta)  || fail "path beta failed"
  [ "$a" != "$b" ] || fail "two projects must not share one state dir ($a)"
  assert_contains "$a" "state/berths/alpha" "alpha resolves under its own berth"
  assert_contains "$b" "state/berths/beta" "beta resolves under its own berth"
  pass "separate projects resolve to disjoint state dirs"
}

test_env_points_state_override_at_the_berth() {
  local home out dir
  home=$(new_home); : > "$home/config/berths"
  out=$(FM_HOME="$home" "$BERTH" env acme-web) || fail "env failed"
  dir=$(printf '%s\n' "$out" | sed -n 's/^export FM_STATE_OVERRIDE=//p')
  [ "$dir" = "$home/state/berths/acme-web" ] || fail "unexpected override: $dir"
  [ -d "$dir" ] || fail "env must create the berth state dir"
  assert_contains "$out" "export FM_BERTH=acme-web" "env records the berth name"
  pass "env redirects state at the berth and creates it"
}

test_only_state_is_redirected() {
  local home out
  home=$(new_home); : > "$home/config/berths"
  out=$(FM_HOME="$home" "$BERTH" env proj) || fail "env failed"
  assert_not_contains "$out" "FM_DATA_OVERRIDE" "v1 must not split data/"
  assert_not_contains "$out" "FM_CONFIG_OVERRIDE" "v1 must not split config/"
  assert_not_contains "$out" "FM_PROJECTS_OVERRIDE" "v1 must not split projects/"
  pass "only state/ is per berth; home knowledge stays shared"
}

# --- a single berth still admits only one live session -----------------------

test_live_holder_blocks_a_second_session() {
  local home dir pid out code
  home=$(new_home); : > "$home/config/berths"
  dir=$(FM_HOME="$home" "$BERTH" path proj)
  mkdir -p "$dir"
  pid=$(start_fake_harness "$(fm_test_tmproot)")
  printf '%s\n' "$pid" > "$dir/.lock"

  out=$(FM_HOME="$home" "$BERTH" env proj 2>&1); code=$?
  kill "$pid" 2>/dev/null || true
  [ "$code" -ne 0 ] || fail "a berth held by a live session must refuse a second"
  assert_contains "$out" "already held" "refusal explains the berth is taken"
  pass "one berth admits only one live session"
}

test_stale_lock_does_not_block() {
  local home dir pid out
  home=$(new_home); : > "$home/config/berths"
  dir=$(FM_HOME="$home" "$BERTH" path proj)
  mkdir -p "$dir"
  pid=$(start_fake_harness "$(fm_test_tmproot)")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$dir/.lock"

  out=$(FM_HOME="$home" "$BERTH" env proj 2>&1) || fail "a dead holder must not block: $out"
  assert_contains "$out" "FM_STATE_OVERRIDE=" "a stale berth is reusable"
  pass "a dead holder leaves the berth reusable"
}

test_status_and_list_report_holders() {
  local home dir pid out code
  home=$(new_home); : > "$home/config/berths"
  dir=$(FM_HOME="$home" "$BERTH" path proj); mkdir -p "$dir"
  out=$(FM_HOME="$home" "$BERTH" status proj) || fail "status failed on a free berth"
  assert_contains "$out" "free" "a fresh berth reads free"

  pid=$(start_fake_harness "$(fm_test_tmproot)")
  printf '%s\n' "$pid" > "$dir/.lock"
  out=$(FM_HOME="$home" "$BERTH" status proj); code=$?
  [ "$code" -eq 1 ] || fail "status must exit 1 while a berth is held"
  assert_contains "$out" "held" "status names the live holder"
  out=$(FM_HOME="$home" "$BERTH" list)
  assert_contains "$out" "proj" "list shows the berth"
  kill "$pid" 2>/dev/null || true
  pass "status and list report berth holders"
}

# --- slug validation (a slug becomes a directory name) -----------------------

test_slug_validation_refuses_unsafe_names() {
  local home code
  home=$(new_home); : > "$home/config/berths"
  for bad in "../escape" "a/b" ".hidden" 'semi;colon' "\$(id)" "" ; do
    FM_HOME="$home" "$BERTH" env "$bad" >/dev/null 2>&1; code=$?
    [ "$code" -ne 0 ] || fail "unsafe project name accepted: '$bad'"
  done
  [ ! -e "$home/state/escape" ] || fail "traversal created a dir outside the berth root"
  pass "unsafe project names are refused"
}

test_slug_length_bound() {
  local home long code
  home=$(new_home); : > "$home/config/berths"
  long=$(printf 'a%.0s' $(seq 1 65))
  FM_HOME="$home" "$BERTH" env "$long" >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] || fail "an over-long project name must be refused"
  pass "project names are length-bounded"
}

test_help_needs_no_optin() {
  local home out
  home=$(new_home)
  out=$(FM_HOME="$home" "$BERTH" --help 2>&1) || fail "--help must always work"
  assert_contains "$out" "berth" "help describes berths"
  pass "help works without opting in"
}

test_disabled_by_default
test_enabled_by_flag
test_two_projects_get_disjoint_state
test_env_points_state_override_at_the_berth
test_only_state_is_redirected
test_live_holder_blocks_a_second_session
test_stale_lock_does_not_block
test_status_and_list_report_holders
test_slug_validation_refuses_unsafe_names
test_slug_length_bound
test_help_needs_no_optin
echo "ALL PASS: fm-berth"
