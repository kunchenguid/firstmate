#!/usr/bin/env bash
# Portable OMP harness identity regression for bin/fm-harness.sh.
#
# OMP advertises Pi environment variables but is a distinct binary, so its
# Firstmate launch marker must beat PI_CODING_AGENT and its own exact command
# name must identify a hand-launched OMP process through ancestry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

test_omp_marker_beats_shared_pi_marker() {
  local out
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u CLAUDECODE -u GROK_AGENT \
    FM_OMP_HARNESS=omp PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed \
    "$HARNESS")
  [ "$out" = omp ] || fail "the OMP marker must beat PI_CODING_AGENT, got '$out'"
  pass "fm-harness: OMP's launch marker wins over the shared Pi marker"
}

test_omp_exact_command_ancestry() {
  local dir bin out
  dir="$TMP_ROOT/ancestry"
  mkdir -p "$dir"
  for bin in omp ompx my-omp; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u CLAUDECODE \
      -u PI_CODING_AGENT -u FM_PI_HARNESS -u FM_OMP_HARNESS -u GROK_AGENT \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    if [ "$bin" = omp ]; then
      [ "$out" = omp ] || fail "an OMP process ancestor resolved '$out', expected omp"
    else
      [ "$out" != omp ] || fail "unrelated process '$bin' was misidentified as OMP"
    fi
  done
  pass "fm-harness: OMP is detected by its exact process name, never a substring"
}

test_omp_marker_beats_shared_pi_marker
test_omp_exact_command_ancestry

echo "all fm-omp-harness tests passed"
