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
#   INVARIANT  every tests/*.test.sh reaches the owner, so a NEW suite cannot
#              skip isolation silently - the whole point of the invariant.
#   NOT-VACUOUS the invariant's matcher rejects a suite whose only mention of a
#              "lib.sh" is an unrelated bin/fm-*-lib.sh, which is the exact
#              substring-without-direction error this area has made before.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OWNER="$ROOT/bin/fm-test-env-lib.sh"

# Helper files that reach the owner themselves; a suite sourcing one of these is
# isolated through it. Each is proven to reach the owner below, so this list
# cannot rot into an unchecked allowance.
OWNER_HELPERS=(wake-helpers.sh fixtures.sh secondmate-helpers.sh)

# --- the matcher the invariant uses -----------------------------------------
#
# Matches a source directive at the start of a line, by PATH, never by loose
# substring. `.*/lib\.sh` requires a slash immediately before `lib.sh`, so
# `bin/fm-wake-lib.sh` and friends do not match - proven by the not-vacuous case.
reaches_owner() {
  local suite=$1 helper
  grep -Eq '^[[:space:]]*(\.|source)[[:space:]]+[^#]*/bin/fm-test-env-lib\.sh' "$suite" && return 0
  grep -Eq '^[[:space:]]*(\.|source)[[:space:]]+[^#]*/lib\.sh"?[[:space:]]*$' "$suite" && return 0
  for helper in "${OWNER_HELPERS[@]}"; do
    grep -Eq "^[[:space:]]*(\.|source)[[:space:]]+[^#]*/$helper" "$suite" && return 0
  done
  return 1
}

# --- OWNER ------------------------------------------------------------------

test_owner_clears_every_pointer_it_publishes() {
  local exported= name out
  # Build the polluted environment from the owner's OWN list, so a pointer added
  # there is covered here without editing this test.
  # shellcheck source=bin/fm-test-env-lib.sh
  . "$OWNER"
  for name in $FM_TEST_ENV_FLEET_POINTERS; do
    exported="$exported $name=/live-sentinel"
  done
  [ -n "$exported" ] || fail "the owner publishes no pointers to clear"

  # shellcheck disable=SC2086
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
  local suite missing=0 total=0 names=
  for suite in "$ROOT"/tests/*.test.sh; do
    total=$((total + 1))
    if ! reaches_owner "$suite"; then
      missing=$((missing + 1))
      names="$names"$'\n'"    $(basename "$suite")"
    fi
  done
  # A selection that found nothing would pass silently; refuse that.
  [ "$total" -gt 0 ] || fail "found no test suites to check, so this invariant is vacuous"
  [ "$missing" -eq 0 ] \
    || fail "these suites never reach bin/fm-test-env-lib.sh, so they can be handed the live fleet home:$names"
  pass "all $total behavior suites reach the fleet-environment isolation owner"
}

test_helpers_named_as_routes_really_reach_the_owner() {
  local helper path
  for helper in "${OWNER_HELPERS[@]}"; do
    path="$ROOT/tests/$helper"
    assert_present "$path" "helper allowed as an isolation route is missing: $helper"
    reaches_owner "$path" \
      || fail "$helper is allowed as an isolation route but does not reach the owner"
  done
  pass "every helper allowed as an isolation route reaches the owner itself"
}

test_matcher_rejects_an_unrelated_lib_substring() {
  local dir probe
  dir=$(fm_test_tmproot fm-test-env-lib)
  probe="$dir/decoy.test.sh"
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
  reaches_owner "$probe" \
    && fail "the matcher accepted a suite whose only lib.sh mentions are unrelated bin/ libraries"
  pass "the matcher rejects unrelated bin/fm-*-lib.sh mentions and a disclaiming comment"
}

test_matcher_accepts_each_real_route() {
  local dir probe
  dir=$(fm_test_tmproot fm-test-env-lib)

  probe="$dir/direct.test.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-test-env-lib.sh"' > "$probe"
  reaches_owner "$probe" || fail "the matcher rejected the direct route to the owner"

  probe="$dir/vialib.test.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"' > "$probe"
  reaches_owner "$probe" || fail "the matcher rejected the tests/lib.sh route"

  probe="$dir/viahelper.test.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"' > "$probe"
  reaches_owner "$probe" || fail "the matcher rejected the helper route"

  pass "the matcher accepts the direct, shared-library and helper routes"
}

# --- direct invocation ------------------------------------------------------

test_direct_invocation_is_isolated() {
  local dir suite out
  dir=$(fm_test_tmproot fm-test-env-lib)
  suite="$dir/probe.test.sh"
  # Shaped like a suite that owns its own reporters and trap: the case the 36
  # non-reachers are in, and the reason they route to the owner directly rather
  # than through tests/lib.sh.
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
test_helpers_named_as_routes_really_reach_the_owner
test_matcher_rejects_an_unrelated_lib_substring
test_matcher_accepts_each_real_route
test_direct_invocation_is_isolated

printf '# fm-test-env-lib.test.sh: all assertions passed\n'
