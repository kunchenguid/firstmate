#!/usr/bin/env bash
# Contract tests for bin/fm-github-pr.py.
#
# The TOON fixtures were reduced from real gh-axi 0.1.25 output observed on
# 2026-08-02 and 2026-08-03, including a nonempty labels table from PR 8166.
# The fake accepts only the exact installed command forms used in production,
# so raw-gh flags such as --json or -q cannot make the suite falsely green.
# Every invocation below is hermetic coverage of those observed shapes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="${FM_TEST_GITHUB_ADAPTER:-$ROOT/bin/fm-github-pr.py}"
fm_test_tmproot_into TMP_ROOT fm-github-pr-tests
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "$*" in
  "api /repos/ruby-dlee/firstmate/pulls/1")
    case "${FM_TEST_API_MODE:-ok}" in
      ok) sed 's/^number: 72$/number: 1/' "$FM_TEST_API_FIXTURE" ;;
      boolean-number) sed 's/^number: 72$/number: true/' "$FM_TEST_API_FIXTURE" ;;
      *) exit 98 ;;
    esac
    ;;
  "pr view 1 --repo ruby-dlee/firstmate --full")
    case "${FM_TEST_CLAIMS_MODE:-ok}" in
      ok) sed 's/^  number: 72$/  number: 1/' "$FM_TEST_CLAIMS_FIXTURE" ;;
      boolean-number) sed 's/^  number: 72$/  number: true/' "$FM_TEST_CLAIMS_FIXTURE" ;;
      *) exit 98 ;;
    esac
    ;;
  "api /repos/ruby-dlee/firstmate/pulls/72")
    case "${FM_TEST_API_MODE:-ok}" in
      ok) cat "$FM_TEST_API_FIXTURE" ;;
      error) exit 42 ;;
      malformed) sed '/^  sha:/d' "$FM_TEST_API_FIXTURE" ;;
      malformed-array) sed 's/labels\[1\]/labels[2]/' "$FM_TEST_API_FIXTURE" ;;
      malformed-fieldless-array)
        sed \
          -e 's/^labels\[1\]{.*}:$/labels[1]:/' \
          -e 's/^  4307347680,bug,d73a4a,true,.*$/  bogus/' \
          "$FM_TEST_API_FIXTURE"
        ;;
      draft) sed 's/^draft: false$/draft: true/' "$FM_TEST_API_FIXTURE" ;;
      missing-draft) sed '/^draft: false$/d' "$FM_TEST_API_FIXTURE" ;;
      timeout-child)
        (sleep 2; printf leaked > "$FM_TEST_CHILD_MARKER") &
        sleep 30
        ;;
      boolean-number) sed 's/^number: 72$/number: true/' "$FM_TEST_API_FIXTURE" ;;
      *) exit 98 ;;
    esac
    ;;
  "pr view 72 --repo ruby-dlee/firstmate --full")
    case "${FM_TEST_CLAIMS_MODE:-ok}" in
      ok) cat "$FM_TEST_CLAIMS_FIXTURE" ;;
      error) exit 43 ;;
      boolean-number) sed 's/^  number: 72$/  number: true/' "$FM_TEST_CLAIMS_FIXTURE" ;;
      *) exit 98 ;;
    esac
    ;;
  "api PUT /repos/ruby-dlee/firstmate/pulls/72/merge --field sha=c9cbe79154013efcec9aa478f1476d0eff6c63df --field merge_method=squash")
    case "${FM_TEST_MERGE_MODE:-merged}" in
      merged) cat "$FM_TEST_MERGE_FIXTURE" ;;
      enqueued) cat "$FM_TEST_QUEUE_FIXTURE" ;;
      *) exit 98 ;;
    esac
    ;;
  *)
    echo "unsupported fake gh-axi invocation: $*" >&2
    exit 97
    ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

export FM_GH_AXI_BIN="$FAKEBIN/gh-axi"
export FM_TEST_GH_AXI_LOG="$TMP_ROOT/gh-axi.log"
export FM_TEST_API_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-pr-api.toon"
export FM_TEST_CLAIMS_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-pr-view-full.toon"
export FM_TEST_MERGE_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-merge-success.toon"
export FM_TEST_QUEUE_FIXTURE="$ROOT/tests/fixtures/gh-axi-merge-enqueued.toon"
PR_URL=https://github.com/ruby-dlee/firstmate/pull/72
BOOLEAN_PR_URL=https://github.com/ruby-dlee/firstmate/pull/1

call_merge_exact() {
  python3 - "$ADAPTER" "$PR_URL" <<'PY'
import importlib.util
import json
import sys

path, url = sys.argv[1:]
spec = importlib.util.spec_from_file_location("firstmate_github_pr_test_adapter", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
result = module.merge_exact(
    url,
    "c9cbe79154013efcec9aa478f1476d0eff6c63df",
    "squash",
    None,
    None,
)
print(json.dumps(result, sort_keys=True))
PY
}

test_snapshot_uses_observed_contract() {
  local output
  : > "$FM_TEST_GH_AXI_LOG"
  output=$("$ADAPTER" snapshot "$PR_URL") || fail "snapshot rejected observed gh-axi fixtures"
  python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["head_sha"] == "c9cbe79154013efcec9aa478f1476d0eff6c63df"
assert value["base_sha"] == "68f014697d0eea733a4e7c0294becff4e76c7bcf"
assert value["claims_document"].startswith("pull_request:\n")
assert value["claims_identity"] == {
    "number": 72,
    "title": "feat: observed contract fixture",
    "body": "Complete claims returned by --full.",
}
' <<< "$output" || fail "snapshot did not preserve the observed head, base, and claims"
  grep -qxF 'api /repos/ruby-dlee/firstmate/pulls/72' "$FM_TEST_GH_AXI_LOG" \
    || fail "snapshot did not use the observed gh-axi API form"
  grep -qxF 'pr view 72 --repo ruby-dlee/firstmate --full' "$FM_TEST_GH_AXI_LOG" \
    || fail "snapshot did not use the observed full-claims form"
  assert_no_grep '--json' "$FM_TEST_GH_AXI_LOG" \
    "snapshot regressed to unsupported raw-gh --json"
  assert_no_grep '-q' "$FM_TEST_GH_AXI_LOG" \
    "snapshot regressed to unsupported raw-gh -q"
  pass "GitHub snapshot accepts observed gh-axi arrays without trusting them"
}

test_lookup_errors_fail_closed() {
  local rc
  set +e
  FM_TEST_CLAIMS_MODE=error "$ADAPTER" snapshot "$PR_URL" > "$TMP_ROOT/error.out" 2> "$TMP_ROOT/error.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "claims lookup error"
  assert_grep 'GitHub state is unreviewed' "$TMP_ROOT/error.err" \
    "claims lookup error was not loud"

  set +e
  FM_TEST_API_MODE=malformed "$ADAPTER" snapshot "$PR_URL" > "$TMP_ROOT/malformed.out" 2> "$TMP_ROOT/malformed.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed API output"
  assert_grep 'missing head.sha' "$TMP_ROOT/malformed.err" \
    "malformed API output was not rejected"
  pass "GitHub lookup errors and malformed documents fail closed"
}

test_public_merge_subcommand_is_unavailable() {
  local rc
  : > "$FM_TEST_GH_AXI_LOG"
  set +e
  "$ADAPTER" merge "$PR_URL" c9cbe79154013efcec9aa478f1476d0eff6c63df squash \
    > "$TMP_ROOT/public-merge.out" 2> "$TMP_ROOT/public-merge.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "public adapter merge subcommand remained executable"
  [ ! -s "$FM_TEST_GH_AXI_LOG" ] || fail "public adapter merge reached gh-axi"
  pass "GitHub mutation is unavailable from the read-only adapter CLI"
}

test_merge_outcomes_distinguish_merged_from_enqueued() {
  local output
  : > "$FM_TEST_GH_AXI_LOG"
  output=$(FM_TEST_MERGE_MODE=merged call_merge_exact) \
    || fail "confirmed merge response was rejected"
  assert_contains "$output" '"merged": true' \
    "confirmed merge did not report merged"
  assert_contains "$output" '"outcome": "merged"' \
    "confirmed merge did not carry the merged outcome"
  assert_contains "$output" '"observed_state": "merged"' \
    "confirmed merge did not carry the merged observed state"
  [ "$(wc -l < "$FM_TEST_GH_AXI_LOG" | tr -d ' ')" -eq 2 ] \
    || fail "confirmed merge did not perform exactly one draft preflight"

  : > "$FM_TEST_GH_AXI_LOG"
  output=$(FM_TEST_MERGE_MODE=enqueued call_merge_exact) \
    || fail "successful queue submission was reported as a failure"
  assert_contains "$output" '"merged": false' \
    "queue submission claimed the PR was merged"
  assert_contains "$output" '"outcome": "enqueued/unconfirmed"' \
    "queue submission did not report enqueued/unconfirmed"
  assert_contains "$output" '"observed_state": "open"' \
    "queue submission did not report the independent open readback"
  assert_no_grep '"merged": true' <(printf '%s\n' "$output") \
    "queue submission claimed merged success"
  [ "$(wc -l < "$FM_TEST_GH_AXI_LOG" | tr -d ' ')" -eq 3 ] \
    || fail "queue submission did not perform one draft preflight and one readback"
  sed -n '3p' "$FM_TEST_GH_AXI_LOG" \
    | grep -qxF 'api /repos/ruby-dlee/firstmate/pulls/72' \
    || fail "queue readback did not inspect the same PR"
  pass "GitHub merge outcomes distinguish merged from enqueued/unconfirmed"
}

test_draft_refusal_is_fail_closed() {
  local mode rc
  for mode in draft missing-draft; do
    : > "$FM_TEST_GH_AXI_LOG"
    set +e
    FM_TEST_API_MODE=$mode call_merge_exact \
      > "$TMP_ROOT/$mode.out" 2> "$TMP_ROOT/$mode.err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$mode merge preflight"
    assert_no_grep '^api PUT ' "$FM_TEST_GH_AXI_LOG" \
      "$mode merge preflight reached the merge mutation"
  done
  assert_grep 'because it is a draft' "$TMP_ROOT/draft.err" \
    "draft refusal did not identify the draft"
  assert_grep 'draft status could not be determined' "$TMP_ROOT/missing-draft.err" \
    "missing draft status was not refused explicitly"
  pass "draft and undeterminable draft status both refuse before merge"
}

test_malformed_array_subtrees_fail_closed() {
  local mode rc
  for mode in malformed-array malformed-fieldless-array; do
    set +e
    FM_TEST_API_MODE=$mode "$ADAPTER" snapshot "$PR_URL" \
      > "$TMP_ROOT/$mode.out" 2> "$TMP_ROOT/$mode.err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$mode TOON array"
  done
  assert_grep 'declares 2 rows, found 1' "$TMP_ROOT/malformed-array.err" \
    "ignored TOON table rows were not strictly validated"
  assert_grep 'malformed gh-axi TOON scalar array item' \
    "$TMP_ROOT/malformed-fieldless-array.err" \
    "fieldless TOON array accepted a row without the required list marker"
  pass "unrelated TOON arrays are grammar-, count-, and row-validated before isolation"
}

test_timeout_reaps_gh_axi_children() {
  local marker rc
  marker="$TMP_ROOT/timeout-child-marker"
  set +e
  FM_TEST_API_MODE=timeout-child \
  FM_TEST_CHILD_MARKER="$marker" \
  FM_GH_AXI_TIMEOUT_SECONDS=1 \
    "$ADAPTER" snapshot "$PR_URL" > "$TMP_ROOT/timeout.out" 2> "$TMP_ROOT/timeout.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "timed-out gh-axi lookup"
  sleep 2.2
  [ ! -e "$marker" ] || fail "timed-out gh-axi child survived the adapter"
  assert_grep 'GitHub state is unreviewed' "$TMP_ROOT/timeout.err" \
    "timed-out lookup did not fail closed"
  pass "gh-axi timeouts terminate and reap the complete request process tree"
}

test_boolean_pr_numbers_fail_closed() {
  local mode rc
  for mode in api claims; do
    set +e
    if [ "$mode" = api ]; then
      FM_TEST_API_MODE=boolean-number "$ADAPTER" snapshot "$BOOLEAN_PR_URL" \
        > "$TMP_ROOT/boolean-$mode.out" 2> "$TMP_ROOT/boolean-$mode.err"
    else
      FM_TEST_CLAIMS_MODE=boolean-number "$ADAPTER" snapshot "$BOOLEAN_PR_URL" \
        > "$TMP_ROOT/boolean-$mode.out" 2> "$TMP_ROOT/boolean-$mode.err"
    fi
    rc=$?
    set -e
    expect_code 1 "$rc" "boolean PR number in $mode document"
    assert_grep 'returned PR True, expected 1' "$TMP_ROOT/boolean-$mode.err" \
      "boolean PR number was treated as integer 1 in $mode document"
  done
  pass "boolean PR numbers fail closed in API and claims documents"
}

if [ -n "${FM_TEST_CASE:-}" ]; then
  case "$FM_TEST_CASE" in
    test_malformed_array_subtrees_fail_closed|test_boolean_pr_numbers_fail_closed|\
    test_timeout_reaps_gh_axi_children|test_public_merge_subcommand_is_unavailable|\
    test_merge_outcomes_distinguish_merged_from_enqueued|\
    test_draft_refusal_is_fail_closed)
      "$FM_TEST_CASE"
      exit 0
      ;;
    *) fail "unknown focused GitHub adapter test: $FM_TEST_CASE" ;;
  esac
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-3 ]; then
  test_snapshot_uses_observed_contract
  test_malformed_array_subtrees_fail_closed
  test_boolean_pr_numbers_fail_closed
  test_timeout_reaps_gh_axi_children
  test_public_merge_subcommand_is_unavailable
  test_merge_outcomes_distinguish_merged_from_enqueued
  test_draft_refusal_is_fail_closed
  exit 0
fi

test_snapshot_uses_observed_contract
test_lookup_errors_fail_closed
test_public_merge_subcommand_is_unavailable
test_malformed_array_subtrees_fail_closed
test_boolean_pr_numbers_fail_closed
test_timeout_reaps_gh_axi_children
test_merge_outcomes_distinguish_merged_from_enqueued
test_draft_refusal_is_fail_closed
