#!/usr/bin/env bash
# Tests for bin/fm-git-host-lib.sh: git-host classification and PR/MR URL
# parsing, the foundation increment for GitLab support consumed by the later
# merge/check (#2) and teardown (#3) increments.
#
# All fixtures are static strings; the suite hits NO network and needs no git
# repo, harness, or external tool.
#
# Matrix:
#   classify: github SSH + HTTPS, gitlab.com SSH + HTTPS, self-hosted gitlab
#             (gitlab.example.com) SSH + HTTPS, .git-suffix and trailing-slash
#             tolerance, ssh:// scheme form, an unknown host (bitbucket), and a
#             non-URL local path.
#   parse:    a GitHub pull URL, a GitLab MR URL with a THREE-segment namespace,
#             a single-segment-namespace GitLab MR URL, trailing-slash tolerance,
#             and several malformed URLs that must be rejected with empty stdout.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-git-host-lib.sh
. "$ROOT/bin/fm-git-host-lib.sh"

# --- host classification ----------------------------------------------------

# expect_classify <remote-url> <expected-token>
expect_classify() {
  local url=$1 want=$2 got
  got=$(fm_git_host_classify "$url")
  [ "$got" = "$want" ] \
    || fail "classify '$url': expected '$want', got '$got'"
}

test_classify_github() {
  expect_classify 'git@github.com:owner/repo.git' github
  expect_classify 'https://github.com/owner/repo.git' github
  expect_classify 'https://github.com/owner/repo' github
  pass "classifies GitHub SSH and HTTPS remotes as github"
}

test_classify_gitlab_dotcom() {
  expect_classify 'git@gitlab.com:group/subgroup/repo.git' gitlab
  expect_classify 'https://gitlab.com/group/repo.git' gitlab
  expect_classify 'https://gitlab.com/goosehead-insurance/custom-dev/goosehead-apps.git' gitlab
  pass "classifies gitlab.com SSH and HTTPS remotes as gitlab"
}

test_classify_gitlab_self_hosted() {
  expect_classify 'git@gitlab.example.com:group/subgroup/repo.git' gitlab
  expect_classify 'https://gitlab.example.com/group/repo' gitlab
  pass "classifies self-hosted gitlab.* SSH and HTTPS remotes as gitlab"
}

test_classify_tolerates_suffix_and_slash() {
  expect_classify 'https://github.com/owner/repo.git/' github
  expect_classify 'https://gitlab.com/group/repo/' gitlab
  expect_classify 'ssh://git@gitlab.example.com:2222/group/repo.git' gitlab
  pass "classification tolerates .git suffix, trailing slash, and ssh:// with a port"
}

test_classify_unknown() {
  expect_classify 'git@bitbucket.org:owner/repo.git' unknown
  expect_classify 'https://bitbucket.org/owner/repo.git' unknown
  expect_classify '/local/path/to/repo' unknown
  pass "classifies an unknown host and a non-URL path as unknown"
}

# --- PR/MR URL parsing ------------------------------------------------------

# expect_parse <url> <kind> <host> <path> <number>
expect_parse() {
  local url=$1 kind=$2 host=$3 path=$4 num=$5 got want
  want="$kind"$'\t'"$host"$'\t'"$path"$'\t'"$num"
  got=$(fm_pr_url_parse "$url") \
    || fail "parse '$url': expected success, got non-zero exit"
  [ "$got" = "$want" ] \
    || fail "parse '$url': expected '$want', got '$got'"
}

# expect_reject <url>: must fail non-zero AND print nothing to stdout.
expect_reject() {
  local url=$1 got rc
  set +e
  got=$(fm_pr_url_parse "$url")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "parse '$url': expected rejection, but it succeeded"
  [ -z "$got" ] || fail "parse '$url': rejected URL emitted stdout garbage: '$got'"
}

test_parse_github_pull() {
  expect_parse 'https://github.com/example/repo/pull/9' \
    github github.com example/repo 9
  expect_parse 'https://github.com/my-org/my-repo/pull/126/' \
    github github.com my-org/my-repo 126
  pass "parses a GitHub pull URL into kind/host/owner-repo/number"
}

test_parse_gitlab_deep_namespace() {
  # The real captain-facing shape: a three-segment namespace.
  expect_parse 'https://gitlab.com/goosehead-insurance/custom-dev/goosehead-apps/-/merge_requests/5924' \
    gitlab gitlab.com goosehead-insurance/custom-dev/goosehead-apps 5924
  pass "parses a GitLab MR URL with a three-segment namespace greedily"
}

test_parse_gitlab_single_namespace() {
  expect_parse 'https://gitlab.com/mygroup/-/merge_requests/3' \
    gitlab gitlab.com mygroup 3
  expect_parse 'https://gitlab.example.com/group/subgroup/proj/-/merge_requests/42/' \
    gitlab gitlab.example.com group/subgroup/proj 42
  pass "parses single-segment and self-hosted GitLab MR URLs, tolerating a trailing slash"
}

test_parse_rejects_malformed() {
  set -e
  expect_reject 'https://github.com/owner/repo/pull/'          # no number
  expect_reject 'https://github.com/owner/pull/1'              # missing repo segment
  expect_reject 'https://github.com/owner/repo/pull/abc'       # non-numeric
  expect_reject 'https://bitbucket.org/owner/repo/pull/1'      # wrong host for /pull/
  expect_reject 'https://gitlab.com/group/merge_requests/5'    # missing /-/ marker
  expect_reject 'https://gitlab.com/group/-/merge_requests/'   # no iid
  expect_reject 'not a url at all'                             # not a URL
  expect_reject ''                                             # empty
  pass "rejects malformed PR/MR URLs non-zero with no stdout garbage"
}

test_classify_github
test_classify_gitlab_dotcom
test_classify_gitlab_self_hosted
test_classify_tolerates_suffix_and_slash
test_classify_unknown
test_parse_github_pull
test_parse_gitlab_deep_namespace
test_parse_gitlab_single_namespace
test_parse_rejects_malformed
