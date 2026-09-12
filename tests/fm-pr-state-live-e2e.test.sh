#!/usr/bin/env bash
# Credentialed regression for bin/fm-pr-state.sh against gh's own jq engine.
#
# gh evaluates --jq with gojq, not the jq binary. The hermetic suite runs the
# script's jq programs through the local jq, so only a real gh invocation proves
# they compile and produce the shape the script parses where they are actually
# executed. cli/cli#1 is a merged 2019 pull request, so its verdict is stable.
# The review-history program stays hermetic-only: it runs only behind a
# CHANGES_REQUESTED decision, which no public pull request holds stably.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The shared gate is the live-harness family's one on/off contract: it is what
# lets FM_LIVE=0 turn every live guard off together, and tests/fm-live-gate.test.sh
# sweeps the whole family for it. The trailing tool list replaces a hand-rolled
# gh presence check; authentication is not a tool check and stays below.
fm_live_gate opt-in FM_PR_STATE_LIVE_E2E gh

SCRIPT="$ROOT/bin/fm-pr-state.sh"
PR=https://github.com/cli/cli/pull/1

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

test_every_jq_program_runs_under_gh_engine() {
  local out status=0
  out=$("$SCRIPT" "$PR" 2>&1) || status=$?
  [ "$status" -eq 0 ] \
    || fail "fm-pr-state.sh refused a readable public pull request (exit $status): $out"
  assert_contains "$out" 'STATE: merged at 2019-10-04T16:01:04Z' \
    "the merged verdict must come from the live REST object"
  pass "fm-pr-state.sh's jq programs are accepted by gh's own jq engine"
}

test_every_jq_program_runs_under_gh_engine
