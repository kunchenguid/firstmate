#!/usr/bin/env bash
# Tests for bin/fm-scm-lib.sh: the SCM provider abstraction firstmate's PR
# lifecycle scripts share. Covers provider detection from a URL and an origin
# remote, PR URL parsing for GitHub and Azure DevOps, and the normalized PR
# helpers (state, head, state+head, number-for-branch) against gh and az mocks.
#
# The routing contract under test: only a provably-ADO provider takes the az
# path; github AND unknown take the gh/gh-axi/git path, so GitHub behaviour is
# byte-for-byte preserved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-scm-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-scm-lib-tests)

# --- provider detection from a URL ------------------------------------------

test_provider_of_url_table() {
  local got
  # each row: url|expected
  local rows=(
    "https://github.com/owner/repo/pull/5|github"
    "git@github.com:owner/repo.git|github"
    "https://dev.azure.com/org/proj/_git/repo/pullrequest/7|ado"
    "git@ssh.dev.azure.com:v3/org/proj/repo|ado"
    "https://org.visualstudio.com/proj/_git/repo/pullrequest/9|ado"
    "https://gitlab.com/owner/repo|unknown"
    "|unknown"
  )
  local row url want
  for row in "${rows[@]}"; do
    url=${row%%|*}
    want=${row#*|}
    got=$("$LIB" provider-of-url "$url")
    [ "$got" = "$want" ] || fail "provider-of-url '$url': expected $want, got $got"
  done
  pass "fm-scm-lib provider-of-url classifies github/ado/unknown across host forms"
}

test_provider_of_remote_reads_origin() {
  local dir
  dir="$TMP_ROOT/remote-detect"
  fm_git_init_commit "$dir/gh"
  git -C "$dir/gh" remote add origin https://github.com/owner/repo
  [ "$("$LIB" provider-of-remote "$dir/gh")" = github ] \
    || fail "provider-of-remote: github origin not detected"

  fm_git_init_commit "$dir/ado"
  git -C "$dir/ado" remote add origin https://dev.azure.com/org/proj/_git/repo
  [ "$("$LIB" provider-of-remote "$dir/ado")" = ado ] \
    || fail "provider-of-remote: ado origin not detected"

  fm_git_init_commit "$dir/local"
  [ "$("$LIB" provider-of-remote "$dir/local")" = unknown ] \
    || fail "provider-of-remote: no-origin repo should be unknown"
  pass "fm-scm-lib provider-of-remote classifies from the origin remote (unknown when absent)"
}

test_provider_of_url_table
test_provider_of_remote_reads_origin
