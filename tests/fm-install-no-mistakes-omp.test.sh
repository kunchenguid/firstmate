#!/usr/bin/env bash
# Contract tests for the OMP-agent no-mistakes reinstall helper.
# Does not build no-mistakes or touch the live binary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-no-mistakes-omp.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

assert_present "$INSTALLER" "bin/fm-install-no-mistakes-omp.sh is missing"
assert_present "$BOOTSTRAP" "bin/fm-bootstrap.sh is missing"
[ -x "$INSTALLER" ] || fail "fm-install-no-mistakes-omp.sh must be executable"

# Non-comment lines only (comments may mention forbidden phrases as guidance).
code_lines() {
  grep -vE '^[[:space:]]*(#|$)' "$1"
}

test_installer_refuses_missing_source() {
  local out rc
  out=$(FM_NO_MISTAKES_OMP_SRC=/no/such/checkout HOME=/no/home \
    "$INSTALLER" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "missing source must fail"
  assert_contains "$out" "source checkout missing" \
    "missing source error must name the gap"
  pass "installer refuses a missing source checkout"
}

test_installer_refuses_non_omp_source() {
  local src out rc
  src=$(fm_test_tmproot fm-nm-omp-non-omp)/src
  mkdir -p "$src"
  printf 'all:\n\ttrue\n' > "$src/Makefile"
  out=$(FM_NO_MISTAKES_OMP_SRC="$src" "$INSTALLER" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "non-omp source must fail"
  assert_contains "$out" "omp.go" "non-omp refusal must mention omp.go"
  pass "installer refuses a checkout without omp.go"
}

test_installer_targets_gobin_not_gopath_bin() {
  assert_grep 'go env GOBIN' "$INSTALLER" \
    "installer must prefer go env GOBIN"
  assert_grep 'INSTALL_BIN' "$INSTALLER" \
    "installer must honor INSTALL_BIN override"
  code_lines "$INSTALLER" | grep -Fq 'make -C "$SRC" build' \
    || fail "installer must invoke make -C \"\$SRC\" build"
  code_lines "$INSTALLER" | grep -Eq 'make[[:space:]]+install' \
    && fail "installer must not invoke the Makefile install target"
  code_lines "$INSTALLER" | grep -Fq 'no-mistakes update' \
    && fail "installer must never run no-mistakes update"
  code_lines "$INSTALLER" | grep -Fq 'daemon stop' \
    && fail "installer must not stop the shared daemon"
  code_lines "$INSTALLER" | grep -Fq 'daemon start' \
    && fail "installer must not start the shared daemon"
  assert_grep 'omp start:' "$INSTALLER" \
    "installer must verify the omp agent marker before and after install"
  pass "installer targets GOBIN, builds only, and never updates upstream or restarts daemon"
}

test_bootstrap_omp_missing_points_at_helper() {
  assert_grep 'no_mistakes_has_omp_agent' "$BOOTSTRAP" \
    "bootstrap must define the omp-agent detector"
  assert_grep 'fm-install-no-mistakes-omp.sh' "$BOOTSTRAP" \
    "bootstrap must point omp-missing at the fork reinstall helper"
  assert_grep 'no_mistakes_omp_install_cmd' "$BOOTSTRAP" \
    "bootstrap must own a distinct omp install command"
  # Distinct path: omp-missing always uses no_mistakes_omp_install_cmd, not
  # the upstream install.sh URL.
  grep -n 'no_mistakes_has_omp_agent' "$BOOTSTRAP" | grep -q . \
    || fail "detector must be referenced"
  pass "bootstrap wires omp-missing to the fork reinstall helper"
}

test_installer_refuses_missing_source
test_installer_refuses_non_omp_source
test_installer_targets_gobin_not_gopath_bin
test_bootstrap_omp_missing_points_at_helper
