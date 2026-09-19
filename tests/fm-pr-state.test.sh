#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-state.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-state-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

HEAD=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
OLD_HEAD_1=2710bc5efc936efb70e95b86ca3582e9da7e60f4
OLD_HEAD_2=4dc2291e6969de1bf204fbdb53c9e57a8353d4e2

# The fake gh answers every query with the JSON shape GitHub returns and runs
# the --jq program it received with the real jq, so field selection is what is
# under test. The pull-request object speaks GitHub's own vocabulary: an
# uppercase state with MERGED as its own value, and a null mergeable while
# GitHub is still computing one.
# It evaluates with the local jq, while gh itself embeds gojq; the live guard in
# tests/fm-pr-state-live-e2e.test.sh runs the real engine.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
serve() {
  case "$*" in
    "pr view "*" --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq "*)
      jq -n --arg head "$head" --arg state "${FM_TEST_STATE-OPEN}" \
        --arg merged "${FM_TEST_MERGED_AT-}" --arg draft "${FM_TEST_DRAFT-false}" \
        --arg mergeable "${FM_TEST_VIEW_MERGEABLE-MERGEABLE}" \
        --arg decision "${FM_TEST_VIEW_REVIEW_DECISION-APPROVED}" \
        '{state: $state, mergedAt: (if $merged == "" then null else $merged end),
          isDraft: ($draft == "true"), headRefOid: $head,
          author: {login: "prauthor", is_bot: false},
          mergeable: (if $mergeable == "null" then null else $mergeable end),
          reviewDecision: $decision}'
      ;;
    "api /repos/o/r/pulls/7/reviews?per_page=100 --paginate --jq "*)
      printf '%s\n' "${FM_TEST_REVIEWS:-[]}"
      ;;
    "pr checks "*" --required --json name,state,bucket --jq "*)
      if [ -n "${FM_TEST_CHECKS_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_CHECKS_ERROR" >&2
        exit 1
      fi
      checks='[{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"},{"name":"optional","state":"SKIPPED","bucket":"skipping","workflow":"ci"}]'
      printf '%s\n' "${FM_TEST_REQUIRED_CHECKS:-$checks}"
      ;;
    *)
      printf 'unexpected gh call: %s\n' "$*" >&2
      exit 91
      ;;
  esac
}
prog=
prev=
for arg in "$@"; do
  [ "$prev" != --jq ] || prog=$arg
  prev=$arg
done
serve "$@" | jq -r "$prog"
SH
chmod +x "$FAKEBIN/gh"

run_state() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" https://github.com/o/r/pull/7
}

# reviews "<login> <state> <commit> <submitted_at>"... prints the JSON array
# GitHub's reviews endpoint returns for those submissions.
reviews() {
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | split(" +"; "")
    | {user: {login: .[0], type: .[1]}, state: .[2], commit_id: .[3], submitted_at: .[4]})'
}

test_clean_pr_is_silent_and_ignores_skipped_checks() {
  local out
  out=$(run_state) || fail "clean fixture was refused"
  [ -z "$out" ] || fail "clean fixture should be silent, got: $out"
  pass "a passing required check and a skipped one leave nothing to report"
}

test_terminal_state_is_the_whole_report() {
  local out
  out=$(FM_TEST_STATE=CLOSED FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "closed fixture was refused"
  [ "$out" = 'STATE: closed' ] \
    || fail "a closed pull request leaves the author nothing else to read, got: $out"

  out=$(FM_TEST_STATE=MERGED FM_TEST_MERGED_AT=2019-10-04T16:01:04Z \
    FM_TEST_VIEW_MERGEABLE=null FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "merged fixture was refused"
  [ "$out" = 'STATE: merged at 2019-10-04T16:01:04Z' ] \
    || fail "a merged pull request says so and reports no blocker after it, got: $out"
  pass "a terminal pull request reports that state and nothing else"
}

test_draft_is_a_blocker() {
  local out
  out=$(FM_TEST_DRAFT=true run_state) || fail "draft fixture was refused"
  assert_contains "$out" 'DRAFT: pull request is not ready for review' \
    "a draft pull request leaves the author something to do"
  pass "draft state blocks readiness"
}

test_stale_blocking_reviews_explain_a_blocking_decision() {
  local out history expected
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_2 2026-09-01T23:02:13Z" \
    "commenter User COMMENTED $OLD_HEAD_2 2026-09-01T23:10:00Z" \
    "alice User APPROVED $OLD_HEAD_2 2026-09-01T23:11:00Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "voided-review fixture was refused"
  expected=$(printf 'REVIEW DECISION: CHANGES_REQUESTED\nSTALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at %s' "$OLD_HEAD_2")
  [ "$out" = "$expected" ] \
    || fail "a stale verdict names the commit it was left at and no head this reading was not verified against, got: $out"
  assert_not_contains "$out" "$OLD_HEAD_1" \
    "a verdict the same reviewer later superseded is history, not a blocker"
  assert_not_contains "$out" 'commenter' \
    "a stale COMMENTED review is informational noise"
  assert_not_contains "$out" 'alice' \
    "a stale approval is not a concrete blocker"
  pass "stale changes-requested verdicts explain a blocking review decision"
}

test_approved_pr_with_only_stale_changes_requested_is_silent() {
  local out history
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "coderabbitai[bot] Bot APPROVED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=APPROVED FM_TEST_REVIEWS=$history run_state) \
    || fail "approved stale-review fixture was refused"
  [ -z "$out" ] || fail "an approved PR with only stale review history should be silent, got: $out"
  pass "approved PR ignores stale changes-requested history"
}

test_current_changes_requested_review_is_a_blocker() {
  local out history
  history=$(reviews "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "current-review fixture was refused"
  [ "$out" = $'REVIEW DECISION: CHANGES_REQUESTED\nREVIEW: coderabbitai[bot] CHANGES_REQUESTED' ] \
    || fail "a verdict left at the head under review blocks readiness and names no head, got: $out"
  pass "current changes-requested review blocks readiness"
}

test_changes_requested_decision_is_never_silent() {
  local out history
  history=$(reviews \
    "bob User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "bob User COMMENTED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "comment-after-changes fixture was refused"
  [ "$out" = $'REVIEW DECISION: CHANGES_REQUESTED\nREVIEW: bob CHANGES_REQUESTED' ] \
    || fail "a later COMMENTED review does not clear the reviewer's change request, got: $out"

  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "decision-only fixture was refused"
  [ "$out" = 'REVIEW DECISION: CHANGES_REQUESTED' ] \
    || fail "GitHub's blocking decision must be printed even without an explaining review, got: $out"
  pass "a CHANGES_REQUESTED decision is always reported"
}

test_authors_own_changes_requested_review_is_not_a_blocker() {
  local out history
  history=$(reviews "prauthor User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "self-review fixture was refused"
  assert_not_contains "$out" 'REVIEW: prauthor' \
    "the author's own verdict is not a reviewer blocking them"
  pass "the author's own review is never listed as a blocker"
}

test_pending_approval_is_not_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_REVIEW_DECISION=REVIEW_REQUIRED run_state) \
    || fail "review-required fixture was refused"
  [ -z "$out" ] || fail "awaiting approval is not a blocker this command reports, got: $out"
  pass "a pending approval is not reported as a blocker"
}

test_required_failure_is_a_blocker() {
  local out
  out=$(FM_TEST_REQUIRED_CHECKS='[{"name":"CI Status","state":"FAILURE","bucket":"fail","workflow":"ci"},{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' run_state) \
    || fail "blocked fixture was refused"
  assert_contains "$out" 'REQUIRED CHECK: CI Status (FAILURE)' \
    "required failure was not reported"
  assert_not_contains "$out" 'lint' \
    "a passing required check is not a blocker"
  pass "required failure blocks readiness"
}

# The next two cases supply gh's own "nothing reported" sentences through
# FM_TEST_CHECKS_ERROR, so they prove the behaviour GIVEN those strings and
# nothing about the strings themselves. A gh reword is invisible to this
# hermetic suite; only a run against a real gh would catch one.
test_unreported_required_checks_are_unconfirmed() {
  local out status
  out=$(FM_TEST_CHECKS_ERROR="no required checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported required checks was refused"
  [ "$out" = 'CHECKS: no required check has reported; readiness unconfirmed' ] \
    || fail "a head where nothing required has reported must not pass silently as ready, got: $out"
  # This asserts the branch taken for that sentence, not that gh still says it.

  status=0
  FM_TEST_CHECKS_ERROR='HTTP 502: Bad Gateway' run_state >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a real check lookup failure must still refuse"
  pass "given gh's sentence, an unreported required check is unconfirmed, other check lookup failures refuse"
}

test_no_reported_checks_is_unverified() {
  local out
  out=$(FM_TEST_CHECKS_ERROR="no checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported checks was refused"
  [ "$out" = 'CHECKS: none reported yet' ] \
    || fail "a head with no reported checks must read as unverified, not ready, got: $out"
  # This asserts the branch taken for that sentence, not that gh still says it.
  pass "given gh's sentence, a head with no reported checks is unverified rather than ready"
}

test_help_states_what_silence_means_and_what_is_out_of_scope() {
  local out
  out=$("$SCRIPT" --help) || fail "help was refused"
  assert_contains "$out" 'it does not mean the pull request is ready to merge' \
    "help must not let empty output read as a verdict that the pull request can merge"
  assert_contains "$out" 'is absent from what this command reads' \
    "help must name the limit: a required context that never reported is absent from what is read"
  assert_contains "$out" "Unresolved review-thread state is out of this command's scope" \
    "help must state the thread-resolution boundary without inventing a reason for it"
  pass "help states what empty output means and what is out of scope"
}

test_unknown_mergeability_is_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "unknown-mergeability fixture was refused"
  assert_contains "$out" 'MERGEABILITY: unknown' \
    "null mergeability must not be treated as clean"

  out=$(FM_TEST_VIEW_MERGEABLE=CONFLICTING run_state) \
    || fail "conflicting fixture was refused"
  assert_contains "$out" 'MERGEABILITY: conflicting' \
    "a conflicting merge state must be reported"
  pass "unknown and conflicting mergeability block readiness"
}

test_refusals_exit_nonzero() {
  local status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "missing argument refusal exited zero"

  status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" not-a-pr >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lookup refusal exited zero"

  local out
  status=0
  out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" 7 2>&1) || status=$?
  [ "$status" -ne 0 ] \
    || fail "a bare number resolves against the ambient repository and is not an address"
  assert_contains "$out" 'expected a GitHub pull-request URL' \
    "a bare number must be refused as an address, not attempted as a lookup"
  pass "argument and lookup refusals exit nonzero"
}

test_clean_pr_is_silent_and_ignores_skipped_checks
test_terminal_state_is_the_whole_report
test_draft_is_a_blocker
test_stale_blocking_reviews_explain_a_blocking_decision
test_approved_pr_with_only_stale_changes_requested_is_silent
test_current_changes_requested_review_is_a_blocker
test_changes_requested_decision_is_never_silent
test_authors_own_changes_requested_review_is_not_a_blocker
test_pending_approval_is_not_a_blocker
test_required_failure_is_a_blocker
test_unreported_required_checks_are_unconfirmed
test_no_reported_checks_is_unverified
test_help_states_what_silence_means_and_what_is_out_of_scope
test_unknown_mergeability_is_a_blocker
test_refusals_exit_nonzero
