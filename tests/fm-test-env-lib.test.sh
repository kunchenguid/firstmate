#!/usr/bin/env bash
# tests/fm-test-env-lib.test.sh - the shared fleet-environment isolation owner
# (bin/fm-test-env-lib.sh) and the repo-wide invariant that every behavior suite
# reaches it.
#
# Firstmate exports the live home into a worker's environment, so a suite started
# from inside a worker inherits pointers at the real fleet home unless something
# clears them. On 2026-08-31 that cost four fake task records written straight
# into the live fleet home by a full-suite run from a task worktree.
#
# Four things are covered here:
#   OWNER      fm_test_env_isolate clears every pointer it publishes, driven from
#              its own published list so this test cannot hold a stale copy.
#   REFUSAL    a pointer that survives is reported and refused, not ignored.
#   INVARIANT  every tests/*.test.sh reaches the owner in its original top-level
#              process before writing through an inherited fleet pointer.
#   NOT-VACUOUS the executable probe rejects unrelated or unexecuted references
#              and isolation confined to a subshell or child process.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-test-env-lib.sh"
PROBE_EXIT_STATUS=91

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

make_probe_root() {
  local probe_root=$1
  mkdir -p "$probe_root"
  cp -R "$ROOT/bin" "$probe_root/bin"
  cp -R "$ROOT/tests" "$probe_root/tests"
  cat > "$probe_root/bin/fm-test-env-lib.sh" <<'SH'
#!/usr/bin/env bash
fm_test_env_isolate() {
  printf '%s\t%s\n' "$FM_TEST_ENV_PROBE_SUITE" "$$" > "$FM_TEST_ENV_PROBE_MARKER"
  exit "$FM_TEST_ENV_PROBE_EXIT_STATUS"
}
SH
}

probe_suite_reaches_owner() {
  local probe_root=$1 suite=$2 suite_name marker suite_pid_file suite_pid private_tmp output sentinel sentinel_entry pointer rc=0
  local polluted=()
  suite_name=$(basename "$suite")
  marker="$probe_root/$suite_name.reached-owner"
  suite_pid_file="$probe_root/$suite_name.suite-pid"
  private_tmp="$probe_root/tmp/$suite_name"
  output="$probe_root/$suite_name.output"
  sentinel="$probe_root/live-home-sentinel/$suite_name"
  mkdir -p "$private_tmp" "$sentinel"
  [ -z "$(find "$sentinel" -mindepth 1 -print -quit)" ] || return 1
  for pointer in $FM_TEST_ENV_FLEET_POINTERS; do
    polluted+=("$pointer=$sentinel/$pointer")
  done
  # shellcheck disable=SC2016 # the suite must record its own PID at run time.
  fm_run_timed 2 env "${polluted[@]}" \
    TMPDIR="$private_tmp" \
    FM_TEST_ENV_PROBE_MARKER="$marker" \
    FM_TEST_ENV_PROBE_SUITE="$suite_name" \
    FM_TEST_ENV_PROBE_EXIT_STATUS="$PROBE_EXIT_STATUS" \
    bash -c 'printf "%s\n" "$$" > "$1"; exec bash "$2"' \
      _ "$suite_pid_file" "$suite" > "$output" 2>&1 || rc=$?
  sentinel_entry=$(find "$sentinel" -mindepth 1 -print -quit)
  [ -z "$sentinel_entry" ] || return 1
  [ "$rc" -eq "$PROBE_EXIT_STATUS" ] || return 1
  [ -f "$marker" ] || return 1
  [ -f "$suite_pid_file" ] || return 1
  suite_pid=$(cat "$suite_pid_file")
  [ "$(cat "$marker")" = "$suite_name"$'\t'"$suite_pid" ]
}

# --- OWNER ------------------------------------------------------------------

test_owner_clears_every_pointer_it_publishes() {
  local exported='' name out
  # Build the polluted environment from the owner's OWN list, so a pointer added
  # there is covered here without editing this test.
  # shellcheck source=bin/fm-test-env-lib.sh
  . "$OWNER"
  for name in $FM_TEST_ENV_FLEET_POINTERS; do
    exported="$exported $name=/live-sentinel"
  done
  [ -n "$exported" ] || fail "the owner publishes no pointers to clear"

  # shellcheck disable=SC2086
  # shellcheck disable=SC2016 # the child must expand the owner's pointer names at run time.
  out=$(env $exported bash -c '
    . "$1"
    fm_test_env_isolate || { echo "ISOLATE-FAILED"; exit 1; }
    for n in $FM_TEST_ENV_FLEET_POINTERS; do
      eval "v=\${$n:-}"
      [ -z "$v" ] || printf "SURVIVED %s=%s\n" "$n" "$v"
    done
  ' _ "$OWNER" 2>&1)

  assert_not_contains "$out" "SURVIVED" "every published pointer must be cleared"
  assert_not_contains "$out" "ISOLATE-FAILED" "isolate must succeed on a clearable environment"
  pass "the owner clears every fleet pointer it publishes"
}

test_owner_is_not_vacuous() {
  local out
  # Disconfirming check: if the pointers were never set, the case above would
  # pass without proving anything. Prove the sentinel genuinely reaches a child.
  out=$(FM_HOME=/live-sentinel bash -c 'printf "%s\n" "${FM_HOME:-<unset>}"')
  [ "$out" = /live-sentinel ] \
    || fail "the sentinel never reached the child, so the clearing case is vacuous"
  pass "the pollution sentinel genuinely reaches a child process"
}

# --- REFUSAL ----------------------------------------------------------------

test_unclearable_pointer_is_refused() {
  local out rc=0
  # A readonly variable cannot be unset, so isolate must report it and fail
  # rather than returning success over a still-live pointer.
  out=$(bash -c '
    . "$1"
    readonly FM_HOME=/live-sentinel
    fm_test_env_isolate
  ' _ "$OWNER" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "isolate returned success while FM_HOME survived"
  assert_contains "$out" "FM_HOME" "the refusal must name the pointer it could not clear"
  pass "a pointer that cannot be cleared is named and refused"
}

# --- INVARIANT --------------------------------------------------------------

test_every_suite_reaches_the_owner() {
  local dir probe_root suite missing=0 total=0 names=
  dir=$(fm_test_tmproot fm-test-env-lib-invariant)
  probe_root="$dir/repo"
  make_probe_root "$probe_root"
  for suite in "$probe_root"/tests/*.test.sh; do
    total=$((total + 1))
    if ! probe_suite_reaches_owner "$probe_root" "$suite"; then
      missing=$((missing + 1))
      names="$names"$'\n'"    $(basename "$suite")"
    fi
  done
  # A selection that found nothing would pass silently; refuse that.
  [ "$total" -gt 0 ] || fail "found no test suites to check, so this invariant is vacuous"
  [ "$missing" -eq 0 ] \
    || fail "these suites never isolate their top-level shell through bin/fm-test-env-lib.sh, so they can be handed the live fleet home:$names"
  pass "all $total behavior suites reach the fleet-environment isolation owner"
}

test_probe_rejects_an_unrelated_lib_substring() {
  local dir probe_root probe
  dir=$(fm_test_tmproot fm-test-env-lib)
  probe_root="$dir/repo"
  make_probe_root "$probe_root"
  probe="$probe_root/tests/decoy.test.sh"
  # The recorded trap: counting by the substring "lib.sh" matched unrelated
  # bin/fm-*-lib.sh sources and a comment saying a suite does NOT source it.
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
# This suite does not source tests/lib.sh.
set -u
. "$ROOT/bin/fm-wake-lib.sh"
. "$ROOT/bin/fm-tmux-lib.sh"
. "$ROOT/bin/fm-classify-lib.sh"
SH
  probe_suite_reaches_owner "$probe_root" "$probe" \
    && fail "the probe accepted a suite whose only lib.sh mentions are unrelated bin/ libraries"
  pass "the probe rejects unrelated bin/fm-*-lib.sh mentions and a disclaiming comment"
}

test_probe_rejects_an_unexecuted_owner_reference() {
  local dir probe_root probe
  dir=$(fm_test_tmproot fm-test-env-lib)
  probe_root="$dir/repo"
  make_probe_root "$probe_root"
  probe="$probe_root/tests/heredoc-decoy.test.sh"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
set -u
cat > "${TMPDIR}/unused-source.sh" <<'DECOY'
. "$ROOT/bin/fm-test-env-lib.sh"
DECOY
SH
  probe_suite_reaches_owner "$probe_root" "$probe" \
    && fail "the probe accepted an owner reference that was only written by an unexecuted heredoc"
  pass "the probe rejects an owner reference that never executes"
}

test_probe_rejects_isolation_inside_a_subshell() {
  local dir probe_root probe output marker
  dir=$(fm_test_tmproot fm-test-env-lib)
  probe_root="$dir/repo"
  make_probe_root "$probe_root"
  probe="$probe_root/tests/subshell-decoy.test.sh"
  output="$probe_root/subshell-decoy.test.sh.output"
  marker="$probe_root/subshell-decoy.test.sh.reached-owner"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
set -u
(
  . "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-test-env-lib.sh"
  fm_test_env_isolate
)
printf 'PARENT_FM_HOME=%s\n' "$FM_HOME"
SH
  probe_suite_reaches_owner "$probe_root" "$probe" \
    && fail "the probe accepted isolation that executed only inside a subshell"
  assert_present "$marker" "the subshell decoy never reached the owner"
  assert_contains "$(cat "$output")" "PARENT_FM_HOME=$probe_root/live-home-sentinel/subshell-decoy.test.sh/FM_HOME" \
    "the subshell decoy did not prove that its parent retained the fleet pointer"
  pass "the probe rejects isolation that leaves the top-level shell exposed"
}

test_probe_rejects_isolation_inside_a_child() {
  local dir probe_root probe output marker
  dir=$(fm_test_tmproot fm-test-env-lib)
  probe_root="$dir/repo"
  make_probe_root "$probe_root"
  probe="$probe_root/tests/child-decoy.test.sh"
  output="$probe_root/child-decoy.test.sh.output"
  marker="$probe_root/child-decoy.test.sh.reached-owner"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
set -u
bash -c '
  . "$1"
  fm_test_env_isolate
' _ "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-test-env-lib.sh"
rc=$?
printf 'FORWARDED_STATUS=%s\n' "$rc"
exit "$rc"
SH
  probe_suite_reaches_owner "$probe_root" "$probe" \
    && fail "the probe accepted isolation that executed only inside a child process"
  assert_present "$marker" "the child decoy never reached the owner"
  assert_contains "$(cat "$output")" "FORWARDED_STATUS=$PROBE_EXIT_STATUS" \
    "the child decoy did not forward the isolation status"
  pass "the probe rejects child isolation with a forwarded exit status"
}

test_probe_rejects_a_pre_isolation_write() {
  local dir probe_root probe written marker
  dir=$(fm_test_tmproot fm-test-env-lib)
  probe_root="$dir/repo"
  make_probe_root "$probe_root"
  probe="$probe_root/tests/pre-isolation-write.test.sh"
  written="$probe_root/live-home-sentinel/pre-isolation-write.test.sh/FM_HOME/touched"
  marker="$probe_root/pre-isolation-write.test.sh.reached-owner"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
set -u
mkdir -p "$FM_HOME"
printf 'touched\n' > "$FM_HOME/touched"
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-test-env-lib.sh"
fm_test_env_isolate
SH
  probe_suite_reaches_owner "$probe_root" "$probe" \
    && fail "the probe accepted a fleet-home write before isolation"
  assert_present "$written" "the decoy did not write through its inherited FM_HOME pointer"
  assert_present "$marker" "the decoy did not invoke the owner after writing through FM_HOME"
  pass "the probe rejects a fleet-home write before isolation"
}

test_probe_accepts_each_real_route() {
  local dir probe_root probe
  dir=$(fm_test_tmproot fm-test-env-lib)
  probe_root="$dir/repo"
  make_probe_root "$probe_root"

  probe="$probe_root/tests/direct.test.sh"
  # shellcheck disable=SC2016 # the decoy must resolve its own source path at run time.
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-test-env-lib.sh"' \
    'fm_test_env_isolate || exit 2' > "$probe"
  probe_suite_reaches_owner "$probe_root" "$probe" \
    || fail "the probe rejected the direct route to the owner"

  probe="$probe_root/tests/vialib.test.sh"
  # shellcheck disable=SC2016 # the decoy must resolve its own source path at run time.
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"' > "$probe"
  probe_suite_reaches_owner "$probe_root" "$probe" \
    || fail "the probe rejected the tests/lib.sh route"

  probe="$probe_root/tests/viahelper.test.sh"
  # shellcheck disable=SC2016 # the decoy must resolve its own source path at run time.
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"' > "$probe"
  probe_suite_reaches_owner "$probe_root" "$probe" \
    || fail "the probe rejected the helper route"

  pass "the probe accepts the direct, shared-library and helper routes"
}

# --- direct invocation ------------------------------------------------------

test_direct_invocation_is_isolated() {
  local dir suite out
  dir=$(fm_test_tmproot fm-test-env-lib)
  suite="$dir/probe.test.sh"
  # Shaped like a suite that owns its own reporters and trap: the reason such
  # suites route to the owner directly rather than through tests/lib.sh.
  cat > "$suite" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-test-env-lib.sh"
fm_test_env_isolate || exit 2
for n in \$FM_TEST_ENV_FLEET_POINTERS; do
  eval "v=\\\${\$n:-}"
  [ -z "\$v" ] || printf 'SURVIVED %s=%s\n' "\$n" "\$v"
done
printf 'PROBE-RAN\n'
SH
  out=$(FM_HOME=/live-sentinel FM_STATE_OVERRIDE=/live-sentinel/state \
    FM_DATA_OVERRIDE=/live-sentinel/data bash "$suite" 2>&1)
  assert_contains "$out" "PROBE-RAN" "the probe suite must actually run"
  assert_not_contains "$out" "SURVIVED" "a directly invoked suite must not see the live fleet home"
  pass "a directly invoked suite that routes to the owner is isolated"
}

test_owner_clears_every_pointer_it_publishes
test_owner_is_not_vacuous
test_unclearable_pointer_is_refused
test_every_suite_reaches_the_owner
test_probe_rejects_an_unrelated_lib_substring
test_probe_rejects_an_unexecuted_owner_reference
test_probe_rejects_isolation_inside_a_subshell
test_probe_rejects_isolation_inside_a_child
test_probe_rejects_a_pre_isolation_write
test_probe_accepts_each_real_route
test_direct_invocation_is_isolated

printf '# fm-test-env-lib.test.sh: all assertions passed\n'
