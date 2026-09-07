#!/usr/bin/env bash
# Credentialed regression for bin/fm-pr-state.sh against gh's own jq engine.
#
# gh evaluates --jq with gojq, not the jq binary. The hermetic suite runs the
# script's jq programs through the local jq, so only a real gh invocation proves
# they compile and produce the shape the script parses where they are actually
# executed. cli/cli#1 is a merged 2019 pull request, so its verdict is stable.
# That stability costs reach: a terminal pull request reports its state and
# stops, so this guard covers the pull-request read taken before that verdict.
# The required-check and review-history programs stay hermetic-only,
# the latter because it runs only behind a CHANGES_REQUESTED decision, which no
# public pull request holds stably.
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

test_pull_request_read_jq_programs_run_under_gh_engine() {
  local out status=0
  out=$("$SCRIPT" "$PR" 2>&1) || status=$?
  [ "$status" -eq 0 ] \
    || fail "fm-pr-state.sh refused a readable public pull request (exit $status): $out"
  assert_contains "$out" 'STATE: merged at 2019-10-04T16:01:04Z' \
    "the merged verdict must come from the live pull-request read"
  pass "fm-pr-state.sh's pull-request read programs are accepted by gh's jq engine"
}

# bin/fm-pr-poll.sh composes each of its two readings inside a gh field selector,
# for the same reason: no JSON processor is required on the watcher's PATH. That
# makes each selector's syntax and output shape a live fact - a hermetic fake gh
# can only replay a shape someone already assumed.
#
# The scalar reading is proven through the program that owns it: cli/cli#1 is a
# merged 2019 pull request, and the poll prints the merged token only once its
# own selector compiled and its own shape validation accepted the result.
test_poll_merge_terminal_runs_under_gh_engine() {
  local out
  out=$("$ROOT/bin/fm-pr-poll.sh" --validated github "$PR" github.com cli/cli 1 2>&1)
  [ "$out" = merged ] \
    || fail "the PR poll no longer reports the live merged pull request as merged: $out"
  pass "the PR poll's merge terminal compiles under gh's jq engine against a live merged pull request"
}

# The activity reading is unreachable through a merged pull request, because the
# merge terminal returns before it, so this program is asserted directly. It is
# the REST pull-request object rather than gh's pull-request view because
# .comments and .review_comments there are totals rather than the length of a
# single collection page; the totals themselves are not stable, so only the
# shape the poll validates is asserted.
test_poll_activity_selector_runs_under_gh_engine() {
  local line
  line=$(gh api /repos/cli/cli/pulls/1 \
    --jq '"comments=\(.comments) review_comments=\(.review_comments)"' \
    2>&1) || fail "gh rejected the poll's activity jq program: $line"
  [[ $line =~ ^comments=[0-9]+\ review_comments=[0-9]+$ ]] \
    || fail "the poll's activity read no longer composes the shape the poll validates: $line"
  pass "the PR poll's activity read compiles under gh's jq engine and composes the shape it validates"
}

# reviewDecision rides the same scalar selector as the merge terminal, so it
# costs no extra round trip; it is asserted separately because the merge
# terminal returns before printing it, and it is the only field that reports a
# review that left no comment behind.
test_poll_decision_selector_runs_under_gh_engine() {
  local line
  line=$(gh pr view "$PR" --json state,isDraft,headRefOid,reviewDecision \
    -q '"state=\(.state) draft=\(.isDraft) head=\(.headRefOid[0:12]) decision=\(if (.reviewDecision // "") == "" then "NONE" else .reviewDecision end)"' \
    2>&1) || fail "gh rejected the poll's scalar jq program: $line"
  [[ $line =~ ^state=(OPEN|CLOSED|MERGED)\ draft=(true|false)\ head=[0-9a-f]{12}\ decision=[A-Z_]+$ ]] \
    || fail "the poll's scalar read no longer composes the shape the poll validates: $line"
  pass "the PR poll's scalar read, reviewDecision included, compiles under gh's jq engine"
}

test_pull_request_read_jq_programs_run_under_gh_engine
test_poll_merge_terminal_runs_under_gh_engine
test_poll_decision_selector_runs_under_gh_engine
test_poll_activity_selector_runs_under_gh_engine
