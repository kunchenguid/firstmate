#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-reviewers.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-reviewers.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-reviewers-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

# The fake gh answers every query with the JSON shape GitHub returns and runs
# the --jq program it received with the real jq, so field selection is what is
# under test.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
printf '%s\n' "${GH_HOST-unset}" >> "${FM_TEST_GH_HOST_LOG:-/dev/null}"
serve() {
  case "$*" in
    "api /repos/o/r/pulls/7 --jq "*)
      printf '%s\n' '{"user":{"login":"prauthor"},"base":{"sha":"base123"}}'
      ;;
    "api /repos/o/r/pulls/7/files?per_page=100 --paginate --jq .[].filename")
      printf '%s\n' '[{"filename":"a.ts"},{"filename":"dir/b.ts"}]'
      ;;
    "api --method GET /repos/o/r/commits -f sha=base123 -f path=a.ts -F per_page=100 --jq "*)
      if [ "${FM_TEST_ONLY_AUTHOR:-0}" = 1 ]; then
        printf '%s\n' '[
          {"sha":"own1","author":{"login":"prauthor","type":"User"}},
          {"sha":"unmapped1","author":null}]'
      else
        printf '%s\n' '[
          {"sha":"carol1","author":{"login":"carol","type":"User"}},
          {"sha":"alice1","author":{"login":"alice","type":"User"}},
          {"sha":"own1","author":{"login":"prauthor","type":"User"}},
          {"sha":"bot1","author":{"login":"renovate[bot]","type":"Bot"}},
          {"sha":"bot2","author":{"login":"renovate[bot]","type":"Bot"}},
          {"sha":"bot3","author":{"login":"renovate[bot]","type":"Bot"}},
          {"sha":"unmapped1","author":null}]'
      fi
      ;;
    "api --method GET /repos/o/r/commits -f sha=base123 -f path=dir/b.ts -F per_page=100 --jq "*)
      if [ "${FM_TEST_ONLY_AUTHOR:-0}" = 1 ]; then
        printf '%s\n' '[{"sha":"own2","author":{"login":"prauthor","type":"User"}}]'
      else
        printf '%s\n' '[
          {"sha":"carol1","author":{"login":"carol","type":"User"}},
          {"sha":"carol2","author":{"login":"carol","type":"User"}}]'
      fi
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

run_reviewers() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" https://github.com/o/r/pull/7
}

test_candidates_use_api_logins_and_unique_commit_counts() {
  local out
  out=$(run_reviewers) || fail "reviewer fixture was refused"
  assert_contains "$out" $'carol\t2 recent commits' \
    "the top candidate's API-resolved login or deduplicated count is wrong"
  assert_contains "$out" $'alice\t1 recent commit' \
    "the single-commit candidate's mapped authorship evidence is missing"
  assert_not_contains "$out" 'prauthor' \
    "the PR author must not be a reviewer candidate"
  assert_not_contains "$out" 'renovate[bot]' \
    "a Bot account cannot review and must not be a candidate"
  pass "reviewer candidates use API-resolved logins and unique commits"
}

test_only_author_evidence_says_no_candidates() {
  local out
  out=$(FM_TEST_ONLY_AUTHOR=1 run_reviewers) || fail "author-only fixture was refused"
  [ "$out" = 'NO CANDIDATES: no mapped author other than the PR author' ] \
    || fail "author-only evidence was not explained plainly: $out"
  pass "author-only evidence produces no candidate and says why"
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

test_github_host_reaches_every_gh_call() {
  local log="$TMP_ROOT/gh-host.log" out
  unset GH_HOST
  : > "$log"
  out=$(FM_TEST_GH_HOST_LOG="$log" PATH="$FAKEBIN:$PATH" "$SCRIPT" https://git.example.org/o/r/pull/7) \
    || fail "a pull request on another GitHub host was refused: $out"
  assert_contains "$out" $'carol\t2 recent commits' "reviewers were not read from the other host"
  [ "$(wc -l < "$log")" -eq 4 ] || fail "expected the pull request, files, and two commit reads, saw: $(cat "$log")"
  [ "$(sort -u "$log")" = git.example.org ] \
    || fail "every gh call must target the pull request's host, saw: $(sort -u "$log")"

  : > "$log"
  FM_TEST_GH_HOST_LOG="$log" PATH="$FAKEBIN:$PATH" "$SCRIPT" https://github.com/o/r/pull/7 >/dev/null \
    || fail "the github.com pull request was refused"
  [ "$(sort -u "$log")" = unset ] \
    || fail "github.com must not select a host, saw: $(sort -u "$log")"
  pass "a pull request on another GitHub host is read at that host and github.com is untouched"
}


test_candidates_use_api_logins_and_unique_commit_counts
test_only_author_evidence_says_no_candidates
test_refusals_exit_nonzero
test_github_host_reaches_every_gh_call
