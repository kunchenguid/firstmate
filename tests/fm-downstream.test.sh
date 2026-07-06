#!/usr/bin/env bash
# Tests for the downstream-user guard: bin/fm-downstream.sh detection plus the
# firstmate-self delivery-mode resolution and PR-seam backstop it feeds.
#
# The rule under test: a DOWNSTREAM instance (running a clone of the shared
# firstmate template whose origin owner differs from the authenticated login, or
# whose identity cannot be resolved) must ship its OWN firstmate changes
# local-only and never auto-PR them upstream. An OWNER instance keeps the full
# no-mistakes pipeline-and-PR path. Contributing upstream is an explicit
# FM_CONTRIBUTE=1 opt-in.
#
# Matrix:
#   (a) fm-downstream.sh: origin owner == login          -> owner (exit 0)
#   (b) fm-downstream.sh: origin owner != login          -> downstream (exit 1)
#   (c) fm-downstream.sh: identity unresolvable          -> downstream (exit 1)
#   (d) fm_github_owner_from_url parses common URL forms
#   (e) fm-project-mode.sh --firstmate-self: owner -> no-mistakes, downstream -> local-only
#   (f) fm-brief.sh --firstmate-self on a downstream instance -> local-only DOD + self-change note
#   (g) fm-pr-check.sh refuses a firstmate self-change PR when downstream, allows with FM_CONTRIBUTE=1
#   (h) fm-pr-merge.sh refuses a firstmate self-change PR when downstream, allows an owner instance
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-downstream)

# Build a git repo standing in for the firstmate repo, with a github origin owned
# by <owner> and a bin/ symlink so internal "$FM_ROOT/bin/..." calls resolve to
# the real toolbelt while origin/identity stay under test control.
make_fm_home() {  # <dir> <origin-owner>
  local dir=$1 owner=$2
  mkdir -p "$dir/data" "$dir/state"
  fm_git_init_commit "$dir"
  git -C "$dir" remote add origin "https://github.com/$owner/firstmate"
  ln -s "$ROOT/bin" "$dir/bin"
  printf '%s\n' "$dir"
}

# fakebin with gh/gh-axi stubs. With a non-empty <login>, `gh api user` answers
# it; with an empty <login>, both wrappers fail so identity is unresolvable.
make_fakebin() {  # <dir> <login>
  local dir=$1 login=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  if [ -n "$login" ]; then
    cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  "api user --jq .login") printf '%s\n' '$login'; exit 0 ;;
esac
exit 1
SH
  else
    cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  fi
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

test_owner_when_origin_owner_matches_login() {
  local home out rc
  home=$(make_fm_home "$TMP_ROOT/owner" acme)
  out=$(PATH="$(make_fakebin "$home" acme):$PATH" "$ROOT/bin/fm-downstream.sh" "$home"); rc=$?
  assert_contains "$out" "owner" "owner case should print owner"
  expect_code 0 "$rc" "owner case should exit 0"
  pass "fm-downstream: origin owner == login -> owner (exit 0)"
}

test_downstream_when_origin_owner_differs() {
  local home out rc
  home=$(make_fm_home "$TMP_ROOT/downstream" upstream-org)
  out=$(PATH="$(make_fakebin "$home" someuser):$PATH" "$ROOT/bin/fm-downstream.sh" "$home"); rc=$?
  assert_contains "$out" "downstream" "mismatched owner/login should print downstream"
  expect_code 1 "$rc" "downstream case should exit 1"
  pass "fm-downstream: origin owner != login -> downstream (exit 1)"
}

test_downstream_when_identity_unresolvable() {
  local home out rc
  home=$(make_fm_home "$TMP_ROOT/unresolvable" upstream-org)
  # Empty login: gh/gh-axi both fail, so login cannot be resolved -> safe default.
  out=$(PATH="$(make_fakebin "$home" ""):$PATH" "$ROOT/bin/fm-downstream.sh" "$home"); rc=$?
  assert_contains "$out" "downstream" "unresolvable identity should default to downstream"
  expect_code 1 "$rc" "unresolvable identity should exit 1 (downstream)"
  pass "fm-downstream: unresolvable identity -> downstream (safe default)"
}

test_owner_from_url_parsing() {
  # shellcheck source=bin/fm-downstream.sh
  . "$ROOT/bin/fm-downstream.sh"
  local got
  got=$(fm_github_owner_from_url "https://github.com/octo/repo.git") || fail "https URL did not parse"
  [ "$got" = octo ] || fail "https URL owner: expected octo, got $got"
  got=$(fm_github_owner_from_url "git@github.com:octo/repo.git") || fail "ssh scp URL did not parse"
  [ "$got" = octo ] || fail "ssh scp URL owner: expected octo, got $got"
  got=$(fm_github_owner_from_url "ssh://git@github.com/octo/repo") || fail "ssh:// URL did not parse"
  [ "$got" = octo ] || fail "ssh:// URL owner: expected octo, got $got"
  if fm_github_owner_from_url "https://gitlab.com/octo/repo" >/dev/null 2>&1; then
    fail "non-github URL should not parse a github owner"
  fi
  pass "fm-downstream: fm_github_owner_from_url parses https/scp/ssh github forms and rejects non-github"
}

test_project_mode_firstmate_self() {
  local home out
  # downstream -> local-only
  home=$(make_fm_home "$TMP_ROOT/pm-down" up-org)
  out=$(PATH="$(make_fakebin "$home" me):$PATH" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-project-mode.sh" --firstmate-self)
  [ "$out" = "local-only off" ] || fail "downstream firstmate-self: expected 'local-only off', got '$out'"
  # owner -> no-mistakes
  home=$(make_fm_home "$TMP_ROOT/pm-owner" me)
  out=$(PATH="$(make_fakebin "$home" me):$PATH" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-project-mode.sh" --firstmate-self)
  [ "$out" = "no-mistakes off" ] || fail "owner firstmate-self: expected 'no-mistakes off', got '$out'"
  pass "fm-project-mode --firstmate-self: downstream -> local-only, owner -> no-mistakes"
}

test_brief_firstmate_self_downstream_is_local_only() {
  local home id brief
  home=$(make_fm_home "$TMP_ROOT/brief-down" up-org)
  id="self-b1"
  PATH="$(make_fakebin "$home" me):$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$ROOT/bin/fm-brief.sh" "$id" firstmate --firstmate-self >/dev/null 2>&1 \
    || fail "fm-brief --firstmate-self failed"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "self brief was not scaffolded"
  assert_grep "ships **local-only**" "$brief" "downstream self brief should ship local-only"
  assert_grep "self-change" "$brief" "downstream self brief should explain it is a self-change"
  assert_grep "FM_CONTRIBUTE" "$home/bin/fm-downstream.sh" "opt-in env should be documented in fm-downstream.sh"
  assert_no_grep "no-mistakes doctor" "$brief" "downstream self brief must not use the no-mistakes pipeline path"
  pass "fm-brief --firstmate-self: downstream self-change gets a local-only, self-change-aware brief"
}

# Arrange a task meta whose project IS the firstmate repo, then exercise the PR
# seams. gh (used by fm-pr-check for pr_head) is stubbed to fail harmlessly.
write_self_task_meta() {  # <home> <id>
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$home/wt" \
    "project=$home" \
    "kind=ship" \
    "mode=local-only"
}

test_pr_check_refuses_self_downstream_allows_contribute() {
  local home id fakebin rc
  home=$(make_fm_home "$TMP_ROOT/prcheck" up-org)
  fakebin=$(make_fakebin "$home" me)
  id="self-c1"
  write_self_task_meta "$home" "$id"

  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-pr-check.sh" "$id" https://github.com/up-org/firstmate/pull/9 \
    > "$home/prcheck.out" 2> "$home/prcheck.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "downstream self-change PR check should be refused"
  assert_grep "refusing to arm a merge poll" "$home/prcheck.err" "refusal message missing"
  assert_absent "$home/state/$id.check.sh" "refused self-change must not arm a merge poll"

  # Explicit opt-in lets it through.
  set +e
  PATH="$fakebin:$PATH" FM_CONTRIBUTE=1 FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-pr-check.sh" "$id" https://github.com/up-org/firstmate/pull/9 \
    > "$home/prcheck2.out" 2> "$home/prcheck2.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "FM_CONTRIBUTE=1 should allow the self-change PR check"
  assert_present "$home/state/$id.check.sh" "FM_CONTRIBUTE=1 should arm the merge poll"
  pass "fm-pr-check: refuses downstream self-change PR, honors FM_CONTRIBUTE=1 opt-in"
}

test_pr_merge_refuses_self_downstream_allows_owner() {
  local home id fakebin rc
  # downstream -> refuse before any merge/recording.
  home=$(make_fm_home "$TMP_ROOT/prmerge-down" up-org)
  fakebin=$(make_fakebin "$home" me)
  id="self-m1"
  write_self_task_meta "$home" "$id"
  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-pr-merge.sh" "$id" https://github.com/up-org/firstmate/pull/9 \
    > "$home/prmerge.out" 2> "$home/prmerge.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "downstream self-change PR merge should be refused"
  assert_grep "refusing to merge a PR" "$home/prmerge.err" "merge refusal message missing"
  assert_no_grep "pr=https://github.com/up-org/firstmate/pull/9" "$home/state/$id.meta" \
    "refused self-change merge must not record pr="

  # owner instance -> the guard is a no-op (merge proceeds to gh-axi, which is
  # stubbed to fail; that failure is downstream of the guard, so a non-guard
  # error message proves the guard let it through).
  home=$(make_fm_home "$TMP_ROOT/prmerge-owner" me)
  fakebin=$(make_fakebin "$home" me)
  write_self_task_meta "$home" "$id"
  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-pr-merge.sh" "$id" https://github.com/me/firstmate/pull/9 \
    > "$home/prmerge-owner.out" 2> "$home/prmerge-owner.err"
  rc=$?
  set -e
  assert_no_grep "refusing to merge a PR" "$home/prmerge-owner.err" \
    "owner instance self-change merge must NOT be guard-refused"
  pass "fm-pr-merge: refuses downstream self-change PR, lets an owner instance through"
}

test_owner_when_origin_owner_matches_login
test_downstream_when_origin_owner_differs
test_downstream_when_identity_unresolvable
test_owner_from_url_parsing
test_project_mode_firstmate_self
test_brief_firstmate_self_downstream_is_local_only
test_pr_check_refuses_self_downstream_allows_contribute
test_pr_merge_refuses_self_downstream_allows_owner
