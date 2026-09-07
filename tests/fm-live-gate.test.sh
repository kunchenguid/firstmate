#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's fm_live_gate, the single decision every
# live-harness guard opens with, and for the wiring that makes that decision
# reach the whole family.
#
# The gate is what turns "a live guard exists" into "a live guard actually ran
# on the machine that has the harness", so the cases below drive it the way a
# guard does: real scripts, executed as separate processes, with a fakebin PATH
# standing in for a host that does or does not have the tool. Nothing here reads
# tests/lib.sh's source text.
#
# The family sweep at the end runs every real live guard with FM_LIVE=0 and
# requires the shared refusal line, which is the only way to prove each guard is
# wired to the shared gate rather than to a private env check of its own. It is
# cheap because a disabled gate exits before a guard touches a harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This file starts dozens of short-lived child scripts that each source
# tests/lib.sh; the parent already ran the global stale-fixture sweep, so the
# children must not repeat it.
export FM_TEST_SKIP_ORPHAN_REAP=1

TMP_ROOT=$(fm_test_tmproot fm-live-gate)
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"

# A stand-in for a harness this host has: present on the fakebin PATH, and
# nothing the gate can confuse with a real one.
cat > "$BIN/fmfakeharness" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/fmfakeharness"

# guard <name> <gate args...>: write a guard script that opens with the shared
# gate and, if the gate lets it through, reports that it ran.
guard() {
  local name=$1
  shift
  local path="$TMP_ROOT/$name.test.sh"
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    printf '. "%s/tests/lib.sh"\n' "$ROOT"
    printf 'fm_live_gate'
    printf ' %s' "$@"
    printf '\n'
    printf 'printf "ran\\n"\n'
  } > "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# run_guard <path> [env assignment ...]: execute a guard on a PATH that carries
# only the fakebin plus the system essentials, capturing stdout and stderr.
run_guard() {
  local path=$1
  shift
  local out rc
  set +e
  out=$(env -u FM_LIVE "$@" PATH="$BIN:/usr/bin:/bin" "$path" 2>&1)
  rc=$?
  set -e
  printf '%s\n' "$rc"
  printf '%s\n' "$out"
}

test_default_on_runs_when_the_tool_is_installed() {
  local path result
  path=$(guard default-present default-on FM_FAKE_LIVE fmfakeharness)
  result=$(run_guard "$path")
  [ "$(printf '%s' "$result" | sed -n 1p)" = 0 ] || fail "a default-on guard with its tool installed must succeed: $result"
  assert_contains "$result" ran "a default-on guard must run with no variable set when its tool is installed"
}

test_default_on_skips_and_names_the_absent_tool() {
  local path result
  path=$(guard default-absent default-on FM_FAKE_LIVE fmmissingharness)
  result=$(run_guard "$path")
  [ "$(printf '%s' "$result" | sed -n 1p)" = 0 ] || fail "an absent tool must be a skip, not a failure: $result"
  assert_contains "$result" "skip: live: fmmissingharness absent" \
    "a capability skip must name the tool this host does not have"
  assert_not_contains "$result" ran "an absent tool must stop the guard before it runs"
}

test_opt_in_stays_off_until_asked() {
  local path result
  path=$(guard optin-idle opt-in FM_FAKE_LIVE fmfakeharness)
  result=$(run_guard "$path")
  [ "$(printf '%s' "$result" | sed -n 1p)" = 0 ] || fail "an unrequested opt-in guard must skip cleanly: $result"
  assert_contains "$result" "skip: live: opt-in; set FM_FAKE_LIVE=1 to run" \
    "an opt-in skip must name the variable that turns the guard on"
  assert_not_contains "$result" ran "a token-spending guard must not run unasked"
}

test_own_variable_turns_an_opt_in_guard_on() {
  local path result
  path=$(guard optin-on opt-in FM_FAKE_LIVE fmfakeharness)
  result=$(run_guard "$path" FM_FAKE_LIVE=1)
  [ "$(printf '%s' "$result" | sed -n 1p)" = 0 ] || fail "FM_FAKE_LIVE=1 must run the guard: $result"
  assert_contains "$result" ran "an explicitly requested opt-in guard must run"
}

test_requested_run_fails_rather_than_skipping_on_an_absent_tool() {
  local path result
  path=$(guard optin-strict opt-in FM_FAKE_LIVE fmmissingharness)
  result=$(run_guard "$path" FM_FAKE_LIVE=1)
  [ "$(printf '%s' "$result" | sed -n 1p)" = 1 ] || fail "a demanded run with no tool must fail, not skip: $result"
  assert_contains "$result" "FM_FAKE_LIVE was requested but fmmissingharness is not installed" \
    "the hard failure must name the request and the missing tool"
  assert_not_contains "$result" "skip:" "a demanded run must never report itself as a skip"
}

test_fm_live_turns_the_whole_family_off_and_on() {
  local path result
  path=$(guard fmlive-off default-on FM_FAKE_LIVE fmfakeharness)
  result=$(run_guard "$path" FM_LIVE=0)
  [ "$(printf '%s' "$result" | sed -n 1p)" = 0 ] || fail "FM_LIVE=0 must skip cleanly: $result"
  assert_contains "$result" "skip: live: disabled by FM_LIVE=0" "FM_LIVE=0 must say why it skipped"

  path=$(guard fmlive-on opt-in FM_FAKE_LIVE fmfakeharness)
  result=$(run_guard "$path" FM_LIVE=1)
  assert_contains "$result" ran "FM_LIVE=1 must turn an opt-in guard on"

  path=$(guard fmlive-on-strict opt-in FM_FAKE_LIVE fmmissingharness)
  result=$(run_guard "$path" FM_LIVE=1)
  [ "$(printf '%s' "$result" | sed -n 1p)" = 1 ] || fail "FM_LIVE=1 must make an absent tool a failure: $result"
}

test_a_guards_own_variable_wins_over_fm_live() {
  local path result
  path=$(guard own-off default-on FM_FAKE_LIVE fmfakeharness)
  result=$(run_guard "$path" FM_LIVE=1 FM_FAKE_LIVE=0)
  [ "$(printf '%s' "$result" | sed -n 1p)" = 0 ] || fail "an explicit per-guard opt-out must skip cleanly: $result"
  assert_contains "$result" "skip: live: disabled by FM_FAKE_LIVE=0" \
    "a guard's own 0 must win over FM_LIVE=1 and say so"
  assert_not_contains "$result" ran "a guard switched off by name must not run"
}

test_any_of_several_entry_points_turns_a_guard_on() {
  local path result
  path=$(guard multi opt-in FM_FAKE_LIVE,FM_FAKE_ALT_LIVE fmfakeharness)
  result=$(run_guard "$path")
  assert_contains "$result" "set FM_FAKE_LIVE=1 to run" \
    "a multi-entry guard must point at its primary variable when idle"
  result=$(run_guard "$path" FM_FAKE_ALT_LIVE=1)
  assert_contains "$result" ran "a secondary entry point must also turn the guard on"
}

test_gate_lets_a_guard_drive_the_real_fleet_scripts_under_a_gate_marker() {
  # The nine live guards that never sourced the shared helpers used to be
  # refused by bin/fm-gate-refuse-lib.sh whenever the pipeline ran them, because
  # the gate marker is set for every no-mistakes gate agent. Opening with the
  # shared gate is what carries the test-suite bypass into them.
  local path out rc
  path="$TMP_ROOT/bypass.test.sh"
  {
    printf '#!/usr/bin/env bash\nset -u\n'
    printf '. "%s/tests/lib.sh"\n' "$ROOT"
    printf 'fm_live_gate default-on FM_FAKE_LIVE fmfakeharness\n'
    printf '. "%s/bin/fm-gate-refuse-lib.sh"\n' "$ROOT"
    printf 'if fm_is_gate_agent; then printf "refused\\n"; else printf "allowed\\n"; fi\n'
  } > "$path"
  chmod +x "$path"
  set +e
  out=$(env -u FM_LIVE -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 \
    PATH="$BIN:/usr/bin:/bin" "$path" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a guard opened with the shared gate must not be refused"
  assert_contains "$out" allowed \
    "the shared gate must carry the test-suite bypass so a live guard can drive the real fleet scripts"
}

test_every_live_guard_is_wired_to_the_shared_gate() {
  local script out listing checked=0
  listing=$("$ROOT/bin/fm-test-run.sh" --family live-harness-optin --list) \
    || fail "could not list the live-harness family"
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    script="$ROOT/$script"
    # bin/fm-test-run.sh runs every script through bash, so a guard that is not
    # marked executable is still a real suite member here.
    out=$(FM_LIVE=0 bash "$script" 2>&1) || fail "$(basename "$script") must exit 0 when live guards are disabled"
    assert_contains "$out" "skip: live: disabled by FM_LIVE=0" \
      "$(basename "$script") must open with the shared live gate"
    checked=$((checked + 1))
  done <<EOF
$listing
EOF
  [ "$checked" -ge 20 ] || fail "expected the whole live-guard family to be swept, saw only $checked"
  pass "all $checked live guards refuse together on FM_LIVE=0"
}

test_default_on_runs_when_the_tool_is_installed
pass "a default-on guard runs wherever its tools are installed"
test_default_on_skips_and_names_the_absent_tool
pass "an absent tool is a named capability skip, not a silent pass"
test_opt_in_stays_off_until_asked
pass "a prompt-submitting guard stays off until it is asked for"
test_own_variable_turns_an_opt_in_guard_on
pass "a guard's own variable turns it on"
test_requested_run_fails_rather_than_skipping_on_an_absent_tool
pass "a demanded run refuses to pass as a skip"
test_fm_live_turns_the_whole_family_off_and_on
pass "FM_LIVE switches the whole family"
test_a_guards_own_variable_wins_over_fm_live
pass "a guard's own setting wins over FM_LIVE"
test_any_of_several_entry_points_turns_a_guard_on
pass "any entry point of a multi-mode guard turns it on"
test_gate_lets_a_guard_drive_the_real_fleet_scripts_under_a_gate_marker
pass "the shared gate carries the gate-refusal bypass into every live guard"
test_every_live_guard_is_wired_to_the_shared_gate
