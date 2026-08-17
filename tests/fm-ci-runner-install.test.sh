#!/usr/bin/env bash
# Interface tests for the privileged self-hosted runner lifecycle script.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER=${FM_CI_INSTALLER_UNDER_TEST:-$ROOT/bin/fm-ci-runner-install.sh}
TMP_ROOT=$(fm_test_tmproot fm-ci-runner-install)

[ -x "$INSTALLER" ] || fail "bin/fm-ci-runner-install.sh must be executable"

help=$($INSTALLER --help) || fail "installer help failed"
assert_contains "$help" "install" "help must document install"
assert_contains "$help" "uninstall" "help must document rollback"
assert_contains "$help" "--token-stdin" "help must keep tokens off disk"
assert_contains "$help" "classic PAT" "help must name the runner-registration credential requirement"
assert_contains "$help" "/bin/bash" \
  "help must name the command shell required by tmux and Herdr CI tests"
assert_contains "$help" "locked" \
  "help must explain how the account stays login-disabled with a command shell"
assert_not_contains "$help" "ghp_" "help must not embed a credential"
pass "runner lifecycle help documents install, rollback, and token transport"

set +e
dependency_plan=$($INSTALLER dependencies 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "dependency planning failed: $dependency_plan"
while IFS= read -r package; do
  [ "$package" != npm ] || fail "dependency plan must never request Ubuntu's standalone npm package"
done <<<"$dependency_plan"
pass "dependency planning never requests npm alongside NodeSource nodejs"

fine_grained_token="api_$(printf 'a%.0s' {1..66})"
set +e
fine_grained_output=$(printf '%s\n' "$fine_grained_token" | \
  "$INSTALLER" install --repository pedromuller-del/firstmate --token-stdin 2>&1)
fine_grained_rc=$?
set -e
[ "$fine_grained_rc" -ne 0 ] || fail "fine-grained-PAT registration token was accepted"
assert_contains "$fine_grained_output" "fine-grained PAT" \
  "fine-grained token failure must name its credential class"
assert_contains "$fine_grained_output" "classic PAT" \
  "fine-grained token failure must name the compatible credential"
assert_not_contains "$fine_grained_output" "unbound variable" \
  "fine-grained token failure must not be masked by cleanup"
pass "fine-grained-PAT registration tokens receive an actionable diagnosis"

classic_token="B4VL$(printf 'b%.0s' {1..25})"
set +e
classic_output=$(printf '%s\n' "$classic_token" | \
  "$INSTALLER" install --repository pedromuller-del/firstmate --token-stdin 2>&1)
classic_rc=$?
set -e
[ "$classic_rc" -ne 0 ] || fail "unprivileged classic-token control unexpectedly installed"
assert_contains "$classic_output" "must run as root" \
  "classic-token control must reach the ordinary root boundary"
assert_not_contains "$classic_output" "fine-grained PAT" \
  "classic-token control must not be misclassified"
pass "classic-PAT registration token shape reaches the pristine install path"

opaque_token="B4VL$(printf 'c%.0s' {1..66})"
set +e
opaque_output=$(printf '%s\n' "$opaque_token" | \
  "$INSTALLER" install --repository pedromuller-del/firstmate --token-stdin 2>&1)
opaque_rc=$?
set -e
[ "$opaque_rc" -ne 0 ] || fail "unprivileged opaque-token control unexpectedly installed"
assert_contains "$opaque_output" "must run as root" \
  "opaque 70-character token must reach the ordinary root boundary"
assert_not_contains "$opaque_output" "fine-grained PAT" \
  "token length alone must not trigger the fine-grained diagnosis"
pass "fine-grained diagnosis requires both the api_ prefix and exact token shape"

printf '%s\n' \
  'Response status code does not indicate success: 404 (Not Found).' \
  'POST https://api.github.com/actions/runner-registration' \
  >"$TMP_ROOT/runner-404.out"
set +e
diagnosis=$(printf '%s\n' "$classic_token" | \
  "$INSTALLER" diagnose-registration --token-stdin \
    --runner-exit 1 --runner-output "$TMP_ROOT/runner-404.out" 2>&1)
diagnosis_rc=$?
set -e
[ "$diagnosis_rc" -ne 0 ] || fail "replayed runner-registration 404 was accepted"
assert_contains "$diagnosis" "runner-registration returned 404" \
  "404 replay must name the failed endpoint"
assert_contains "$diagnosis" "classic PAT" \
  "404 replay must recommend the compatible credential"
assert_not_contains "$diagnosis" "unbound variable" \
  "404 replay must not be masked by cleanup"
pass "runner-registration 404 replay reports the real cause cleanly"

set +e
printf '\n' | "$INSTALLER" install --repository pedromuller-del/firstmate --token-stdin \
  >"${TMPDIR:-/tmp}/fm-ci-runner-install-test.$$" 2>&1
rc=$?
set -e
rm -f "${TMPDIR:-/tmp}/fm-ci-runner-install-test.$$"
[ "$rc" -ne 0 ] || fail "an empty registration token was accepted"
pass "installer refuses an empty registration token"

set +e
printf '\n' | "$INSTALLER" uninstall --repository pedromuller-del/firstmate --token-stdin \
  >"${TMPDIR:-/tmp}/fm-ci-runner-uninstall-test.$$" 2>&1
rc=$?
set -e
rm -f "${TMPDIR:-/tmp}/fm-ci-runner-uninstall-test.$$"
[ "$rc" -ne 0 ] || fail "an empty removal token was accepted"
pass "rollback refuses an empty removal token"
