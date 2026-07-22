#!/usr/bin/env bash
# Parity guard for firstmate's shell-lint definition.
#
# bin/fm-lint.sh must be the single owner that BOTH CI
# (.github/workflows/ci.yml) and the pre-push gate (.no-mistakes.yaml
# commands.lint) invoke, so the local lint can never diverge from CI again.
# Regression origin: with no commands.lint configured, the local no-mistakes
# lint step never ran the deterministic
# `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`, so PRs passed local
# validation yet failed that exact check in CI on info/warning findings such as
# SC2015, SC1007, and SC2034. A second axis was tool-version skew: CI's
# ShellCheck floated with the runner image and still emitted SC2015, which
# ShellCheck retired in 0.11.0. fm-lint.sh now pins one exact version and both
# gates resolve it, so command, file set, config, AND version all match.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-lint.sh"
CI="$ROOT/.github/workflows/ci.yml"
NM="$ROOT/.no-mistakes.yaml"
INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
# The authoritative file set the one owner must run.
CANON_TOOLBELT='lint_toolbelt=(bin/*.sh bin/backends/*.sh)'
CANON_TESTS='lint_tests=(tests/*.sh)'
# The pinned version, read from the single source (the one owner itself).
REQUIRED=$("$LINT" --required-version)

# True only when the resolved shellcheck is exactly the pinned version, so the
# lint-running tests below match what CI enforces instead of a runner default.
pinned_ready() {
  command -v shellcheck >/dev/null 2>&1 || return 1
  [ "$(shellcheck --version | awk '/^version:/ {print $2; exit}')" = "$REQUIRED" ]
}

test_owner_exists_and_executable() {
  assert_present "$LINT" "bin/fm-lint.sh is missing"
  [ -x "$LINT" ] || fail "bin/fm-lint.sh must be executable so CI/gate can run it directly"
  pass "one-owner lint script exists and is executable"
}

test_owner_defines_canonical_set() {
  assert_grep "$CANON_TOOLBELT" "$LINT" "fm-lint.sh must own the toolbelt/backend file set"
  assert_grep "$CANON_TESTS" "$LINT" "fm-lint.sh must own the behavior-test file set"
  # It must not weaken CI: no severity downgrade and no blanket disable/exclude
  # that would hide findings CI fails on.
  assert_no_grep '--severity' "$LINT" "fm-lint.sh must not lower severity below the CI default"
  assert_no_grep '--exclude' "$LINT" "fm-lint.sh must not blanket-exclude checks CI enforces"
  [ "$(grep -Fc 'shellcheck --norc' "$LINT")" -eq 2 ] || fail "both focused and canonical lint modes must ignore ambient configuration"
  pass "fm-lint.sh is the sole authoritative definition at CI-default severity"
}

test_ci_invokes_the_owner() {
  grep -Eq '^      - run: bin/fm-lint\.sh$' "$CI" || fail "CI lint job must invoke the one-owner script as a run step"
  # Guard against regression to an inline re-spelling of the command.
  assert_no_grep 'run: shellcheck' "$CI" "CI must call fm-lint.sh, not re-spell shellcheck inline"
  pass "CI lint job calls the one-owner script, not an inline command"
}

test_nomistakes_invokes_the_owner() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" || fail "no-mistakes commands.lint must map exactly to the one-owner script"
  pass "no-mistakes pre-push lint calls the one-owner script"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint.sh --required-version printed nothing"
  # The captain-agreed pin: adopt ShellCheck 0.11.0's rule set consistently,
  # which is also what drops the upstream-retired, false-positive-prone SC2015.
  assert_contains "$REQUIRED" "0.11.0" "fm-lint.sh must pin ShellCheck 0.11.0"
  pass "fm-lint.sh pins an explicit ShellCheck version ($REQUIRED)"
}

test_ci_installs_and_logs_the_pinned_version() {
  # CI must derive the version from the one owner (never hardcode a divergent
  # number) and log the resolved version as parity evidence.
  assert_grep "VERSION=\"\$(\"\$ROOT/bin/fm-lint.sh\" --required-version)\"" "$INSTALLER" "installer must read the version fm-lint.sh pins"
  [ "$(grep -Fc "bin/fm-install-shellcheck.sh \"\$RUNNER_TEMP/bin\"" "$CI")" -eq 2 ] || fail "both CI jobs must use the shared ShellCheck installer"
  assert_grep "ACTUAL_SHA256=\$(sha256sum" "$INSTALLER" "installer must calculate the ShellCheck archive checksum"
  assert_grep "[ \"\$ACTUAL_SHA256\" = \"\$SHA256\" ]" "$INSTALLER" "installer must verify the ShellCheck archive checksum"
  assert_grep "\"\$DESTINATION/shellcheck\" --version" "$INSTALLER" "installer must log the resolved ShellCheck version as evidence"
  pass "CI installs and logs the pinned ShellCheck version from the one owner"
}

test_rejects_wrong_shellcheck_version() {
  # Version-independent: a fake shellcheck reporting a different version must be
  # refused before any lint, proving local and CI cannot silently diverge.
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-ver)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.9.9\nlicense: x\nwebsite: y\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted a shellcheck version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint.sh did not name the required version on mismatch"
  assert_contains "$out" "0.9.9" "fm-lint.sh did not report the resolved (wrong) version"
  pass "fm-lint.sh refuses to lint under a non-pinned ShellCheck version"
}

test_catches_a_real_lint_defect() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): lint-defect regression check"
    return
  fi
  # A script with a genuine ShellCheck finding must make the one owner exit
  # non-zero, proving local now runs real shellcheck instead of the old no-op
  # lint step. We deliberately do NOT assert SC2015 (PR 475's actual failure):
  # ShellCheck removed SC2015 in the pinned 0.11.0, so asserting it would make
  # this test itself version-fragile - the very trap being fixed. SC1007 is a
  # warning present at default severity (and is itself one of the recurring
  # classes that slipped through, PR 474).
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-bad)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$("$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh passed a known-bad fixture"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not report the expected ShellCheck finding"
  pass "fm-lint.sh catches a real lint defect the old no-op gate passed"
}

test_ignores_ambient_shellcheck_opts() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): ambient options regression check"
    return
  fi
  local tmp bad out rc
  tmp=$(fm_test_tmproot fm-lint-opts)
  mkdir -p "$tmp"
  bad="$tmp/bad.sh"
  cat > "$bad" <<'SH'
#!/usr/bin/env bash
foo() {
  local a= b=
  echo "$a$b"
}
foo
SH
  rc=0
  out=$(SHELLCHECK_OPTS='--exclude=SC1007' "$LINT" "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh allowed ambient SHELLCHECK_OPTS to hide a finding"$'\n'"$out"
  assert_contains "$out" "SC1007" "fm-lint.sh did not neutralize ambient SHELLCHECK_OPTS"
  pass "fm-lint.sh ignores ambient ShellCheck options"
}

test_clean_fixture_passes() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): clean fixture check"
    return
  fi
  local tmp good rc
  tmp=$(fm_test_tmproot fm-lint-good)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  printf 'ok\n'
fi
SH
  rc=0
  "$LINT" "$good" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "fm-lint.sh flagged a clean fixture (exit $rc)"
  pass "fm-lint.sh passes a clean fixture"
}

test_parallel_output_and_failure_are_deterministic() {
  local tmp fakebin state out rc toolbelt_line tests_line
  tmp=$(fm_test_tmproot fm-lint-parallel)
  fakebin=$(fm_fakebin "$tmp")
  state="$tmp/state"
  mkdir -p "$state"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\nlicense: x\nwebsite: y\n'
  exit 0
fi
group=toolbelt
for arg in "$@"; do case "$arg" in tests/*) group=tests ;; esac; done
touch "$FM_LINT_TEST_STATE/active.$group"
active=$(find "$FM_LINT_TEST_STATE" -name 'active.*' | wc -l)
[ "$active" -le 2 ] || { printf 'too many workers: %s\n' "$active"; exit 9; }
sleep 1
printf 'finding-%s\n' "$group"
rm -f "$FM_LINT_TEST_STATE/active.$group"
[ "$group" != tests ]
SH
  chmod +x "$fakebin/shellcheck"

  rc=0
  out=$(FM_LINT_JOBS=2 FM_LINT_TEST_STATE="$state" PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "parallel lint hid a worker failure"
  assert_not_contains "$out" 'too many workers' "parallel lint exceeded its configured worker bound"
  assert_contains "$out" 'finding-tests' "parallel lint omitted the failing group"
  toolbelt_line=$(printf '%s\n' "$out" | grep -n 'finding-toolbelt' | cut -d: -f1)
  tests_line=$(printf '%s\n' "$out" | grep -n 'finding-tests' | cut -d: -f1)
  [ "$toolbelt_line" -lt "$tests_line" ] || fail "parallel lint output did not follow canonical group order"
  pass "parallel lint is bounded, deterministically ordered, and fails on any worker finding"
}

test_rejects_unbounded_worker_counts() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-jobs)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  printf 'version: 0.11.0\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  rc=0
  out=$(FM_LINT_JOBS=3 PATH="$fakebin:$PATH" "$LINT" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh accepted an unbounded worker count"
  assert_contains "$out" 'FM_LINT_JOBS must be 1 or 2' "fm-lint.sh did not explain the worker bound"
  pass "fm-lint.sh rejects worker counts above its documented bound"
}

test_parallel_groups_retain_sourced_file_context() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): sourced-file parallel parity check"
    return
  fi
  local tmp fixture helper consumer out rc
  tmp=$(fm_test_tmproot fm-lint-source)
  mkdir -p "$tmp"
  fixture="$tmp/fixture"
  mkdir -p "$fixture/bin/backends" "$fixture/tests"
  cp "$LINT" "$fixture/bin/fm-lint.sh"
  helper="$fixture/bin/helper.sh"
  consumer="$fixture/tests/consumer.sh"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
# shellcheck disable=SC2034 # The consumer sources this fixture variable.
sourced_value=ready
SH
  cat > "$consumer" <<SH
#!/usr/bin/env bash
# shellcheck source=$helper
. "$helper"
printf '%s\n' "\$sourced_value"
SH
  rc=0
  printf '#!/usr/bin/env bash\nset -u\n' > "$fixture/bin/backends/clean.sh"
  printf '#!/usr/bin/env bash\nset -u\n' > "$fixture/tests/clean.sh"
  out=$(FM_LINT_JOBS=2 "$fixture/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "parallel lint lost sourced-file context"$'\n'"$out"
  assert_not_contains "$out" 'SC1091' "parallel lint emitted the split-invocation source false positive"
  assert_not_contains "$out" 'SC2154' "parallel lint forgot variables defined by a sourced canonical file"
  pass "parallel groups retain the monolithic invocation's sourced-file context"
}

test_owner_exists_and_executable
test_owner_defines_canonical_set
test_ci_invokes_the_owner
test_nomistakes_invokes_the_owner
test_pins_an_explicit_version
test_ci_installs_and_logs_the_pinned_version
test_rejects_wrong_shellcheck_version
test_catches_a_real_lint_defect
test_ignores_ambient_shellcheck_opts
test_clean_fixture_passes
test_parallel_output_and_failure_are_deterministic
test_rejects_unbounded_worker_counts
test_parallel_groups_retain_sourced_file_context
