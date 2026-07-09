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

# --- PR URL parsing (via a sourcing harness that reads the FM_SCM_* globals) --

# Parse a URL in a subshell that sources the library, print the resolved fields
# as "provider|number|owner|repo|orgurl|project|adorepo" (rc mirrors parse).
parse_fields() {
  local url=$1
  bash -c '
    . "'"$LIB"'"
    if fm_scm_parse_pr_url "'"$url"'" 2>/dev/null; then
      printf "%s|%s|%s|%s|%s|%s|%s" \
        "$FM_SCM_PROVIDER" "$FM_SCM_PR_NUMBER" "$FM_SCM_PR_OWNER" "$FM_SCM_PR_REPO" \
        "$FM_SCM_ADO_ORG_URL" "$FM_SCM_ADO_PROJECT" "$FM_SCM_ADO_REPO"
    else
      printf "RC1|%s" "$FM_SCM_PROVIDER"
      exit 1
    fi
  '
}

test_parse_github_url() {
  local got
  got=$(parse_fields "https://github.com/my-org/my-repo/pull/126/") \
    || fail "parse github: unexpected non-zero"
  [ "$got" = "github|126|my-org|my-repo|||" ] \
    || fail "parse github fields wrong: $got"
  pass "fm-scm-lib parses a GitHub PR URL into owner/repo/number"
}

test_parse_ado_devazure_url() {
  local got
  got=$(parse_fields "https://dev.azure.com/contoso/Platform/_git/api/pullrequest/42") \
    || fail "parse ado dev.azure: unexpected non-zero"
  [ "$got" = "ado|42|||https://dev.azure.com/contoso|Platform|api" ] \
    || fail "parse ado dev.azure fields wrong: $got"
  pass "fm-scm-lib parses a dev.azure.com PR URL into org-url/project/repo/number"
}

test_parse_ado_visualstudio_url() {
  local got
  got=$(parse_fields "https://contoso.visualstudio.com/Platform/_git/api/pullrequest/9") \
    || fail "parse ado visualstudio: unexpected non-zero"
  [ "$got" = "ado|9|||https://contoso.visualstudio.com|Platform|api" ] \
    || fail "parse ado visualstudio fields wrong: $got"
  pass "fm-scm-lib parses a *.visualstudio.com PR URL into org-url/project/repo/number"
}

test_parse_unrecognized_url_fails() {
  local got rc
  set +e
  got=$(parse_fields "https://gitlab.com/o/r/merge_requests/3" 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" = 1 ] || fail "parse unrecognized: expected rc 1, got $rc"
  case "$got" in RC1*) : ;; *) fail "parse unrecognized: expected RC1 marker, got $got" ;; esac
  pass "fm-scm-lib refuses an unrecognized PR URL"
}

test_parse_github_url
test_parse_ado_devazure_url
test_parse_ado_visualstudio_url
test_parse_unrecognized_url_fails

# --- normalized PR operations against gh and az mocks -----------------------

# A fakebin providing a `gh` that answers state/headRefOid and an `az` that
# answers `repos pr show`/`repos pr list` from JSON. Echoes the fakebin dir.
# Args: case_dir gh_state gh_head ado_status ado_head
make_host_mocks() {
  local case_dir=$1 gh_state=$2 gh_head=$3 ado_status=$4 ado_head=$5
  local fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"state,headRefOid"*) printf '%s\t%s\n' '$gh_state' '$gh_head' ;;
  *"headRefOid"*) printf '%s\n' '$gh_head' ;;
  *state*) printf '%s\n' '$gh_state' ;;
esac
exit 0
SH
  cat > "$fakebin/az" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"repos pr show"*)
    printf '%s\n' '{"status":"$ado_status","lastMergeSourceCommit":{"commitId":"$ado_head"},"sourceRefName":"refs/heads/feature"}'
    ;;
  *"repos pr list"*)
    printf '%s\n' '[{"pullRequestId":77}]'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/az"
  printf '%s\n' "$fakebin"
}

# Call a library function with the mock fakebin on PATH. Args: fakebin fn args...
call_lib() {
  local fakebin=$1; shift
  PATH="$fakebin:$PATH" bash -c '. "'"$LIB"'"; "$@"' _ "$@"
}

test_pr_state_github_and_ado() {
  local case_dir fakebin
  case_dir="$TMP_ROOT/state-both"; mkdir -p "$case_dir"
  fakebin=$(make_host_mocks "$case_dir" MERGED aaa completed bbb)

  [ "$(call_lib "$fakebin" fm_scm_pr_state github '' https://github.com/o/r/pull/1)" = MERGED ] \
    || fail "pr_state github: expected MERGED"
  [ "$(call_lib "$fakebin" fm_scm_pr_state ado '' https://dev.azure.com/org/proj/_git/r/pullrequest/1)" = MERGED ] \
    || fail "pr_state ado: completed should normalize to MERGED"
  pass "fm-scm-lib pr_state normalizes github MERGED and ado completed to MERGED"
}

test_pr_state_ado_non_merged() {
  local case_dir fakebin
  case_dir="$TMP_ROOT/state-active"; mkdir -p "$case_dir"
  fakebin=$(make_host_mocks "$case_dir" OPEN aaa active bbb)
  [ "$(call_lib "$fakebin" fm_scm_pr_state ado '' https://dev.azure.com/org/proj/_git/r/pullrequest/1)" = OPEN ] \
    || fail "pr_state ado: active should normalize to OPEN"
  pass "fm-scm-lib pr_state normalizes ado active to OPEN"
}

test_pr_head_github_and_ado() {
  local case_dir fakebin
  case_dir="$TMP_ROOT/head-both"; mkdir -p "$case_dir"
  fakebin=$(make_host_mocks "$case_dir" MERGED ghhead completed adohead)
  [ "$(call_lib "$fakebin" fm_scm_pr_head github '' https://github.com/o/r/pull/1)" = ghhead ] \
    || fail "pr_head github: expected ghhead"
  [ "$(call_lib "$fakebin" fm_scm_pr_head ado '' https://dev.azure.com/org/proj/_git/r/pullrequest/1)" = adohead ] \
    || fail "pr_head ado: expected adohead from lastMergeSourceCommit.commitId"
  pass "fm-scm-lib pr_head returns the head sha for github and ado"
}

test_pr_state_head_combined() {
  local case_dir fakebin got
  case_dir="$TMP_ROOT/state-head"; mkdir -p "$case_dir"
  fakebin=$(make_host_mocks "$case_dir" MERGED ghhead completed adohead)
  got=$(call_lib "$fakebin" fm_scm_pr_state_head ado '' https://dev.azure.com/org/proj/_git/r/pullrequest/1)
  [ "$got" = "$(printf 'MERGED\tadohead')" ] \
    || fail "pr_state_head ado: expected 'MERGED<tab>adohead', got '$got'"
  pass "fm-scm-lib pr_state_head returns normalized STATE and head in one call"
}

test_pr_number_for_branch_ado() {
  local case_dir fakebin
  case_dir="$TMP_ROOT/branch-ado"; mkdir -p "$case_dir/wt"
  fakebin=$(make_host_mocks "$case_dir" MERGED aaa completed bbb)
  [ "$(call_lib "$fakebin" fm_scm_pr_number_for_branch ado "$case_dir/wt" fm/x)" = 77 ] \
    || fail "pr_number_for_branch ado: expected 77 from az repos pr list"
  pass "fm-scm-lib pr_number_for_branch reads the ado pullRequestId"
}

test_pr_state_github_and_ado
test_pr_state_ado_non_merged
test_pr_head_github_and_ado
test_pr_state_head_combined
test_pr_number_for_branch_ado


