#!/usr/bin/env bash
# Tests for bin/fm-seed-empty-repo.sh: the sixth sanctioned exception to hard
# rule #1 - seeding the first commit of a genuinely brand-new, zero-commit
# GitHub repo so a crewmate can get a worktree at all. The entire safety net is
# the live GitHub API verification, so this suite spends most of its matrix on
# refusal paths: any signal short of an unambiguous "empty on every branch"
# confirmation must refuse loudly and must never touch git commit or git push.
#
# Matrix:
#   (a) seeds and pushes a single empty commit on a genuinely empty repo
#   (b) refuses when repo size is non-zero
#   (c) refuses when the branches list is non-empty
#   (d) refuses when the commits API unexpectedly succeeds (real history exists)
#   (e) refuses when the commits API fails for an unrelated, inconclusive reason
#   (f) refuses when the project has no origin remote
#   (g) refuses when the origin remote is not GitHub
#   (h) refuses when the working tree is dirty
#   (i) refuses when the local default branch already has a commit
#   (j) refuses when the local branch disagrees with the remote's default branch
#   (k) refuses when gh-axi is not available to run the verification
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SEED="$ROOT/bin/fm-seed-empty-repo.sh"
TMP_ROOT=$(fm_test_tmproot fm-seed-empty-repo-tests)

# make_empty_clone <case_dir> <owner> <repo> [default_branch]: create a bare
# "remote" with zero commits at a path carrying a literal github.com/<owner>/<repo>
# segment (so the script's github.com URL parsing sees a real owner/repo while
# the actual git push stays local), then clone it to <case_dir>/proj. Echoes
# nothing; the clone lands at "$case_dir/proj".
make_empty_clone() {
  local case_dir=$1 owner=$2 repo=$3 branch=${4:-main} bare
  bare="$case_dir/remotes/github.com/$owner/$repo"
  mkdir -p "$bare"
  git init --quiet --bare "$bare"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$branch"
  git clone --quiet "file://$bare" "$case_dir/proj"
}

# gh-axi mock: logs every invocation, then answers the three calls the script
# makes based on env vars the test sets before invoking run_seed.
#   FM_TEST_REPO_SIZE       size: value for the base repo info call (default 0)
#   FM_TEST_DEFAULT_BRANCH  default_branch: value for the base repo info call
#   FM_TEST_BRANCHES        raw body for the branches call (default "[]")
#   FM_TEST_COMMITS_MODE    empty|success|error for the commits call
add_gh_axi_mock() {
  local case_dir=$1
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
path=${2:-}
case "$path" in
  */branches)
    printf '%s\n' "${FM_TEST_BRANCHES:-[]}"
    exit 0
    ;;
  */commits*)
    case "${FM_TEST_COMMITS_MODE:-empty}" in
      success)
        printf '%s\n' "[1]:" "  - sha: deadbeefcafefeed0000000000000000deadbeef"
        exit 0
        ;;
      error)
        echo 'error: "gh: API rate limit exceeded (HTTP 403)"' >&2
        exit 1
        ;;
      *)
        echo 'error: "gh: Git Repository is empty. (HTTP 409)"' >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'size: %s\n' "${FM_TEST_REPO_SIZE:-0}"
    printf 'default_branch: %s\n' "${FM_TEST_DEFAULT_BRANCH:-main}"
    exit 0
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# run_seed <case_dir> <proj-path>: invoke the script with this case's mock on
# PATH and the case's own gh-axi call log, honoring whatever FM_TEST_* env vars
# the test already exported.
run_seed() {
  local case_dir=$1 proj=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$SEED" "$proj"
}

test_seeds_and_pushes_genuinely_empty_repo() {
  local case_dir rc
  case_dir="$TMP_ROOT/happy-path"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example promo-reel-forge
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "happy-path: fm-seed-empty-repo should succeed on a genuinely empty repo"
  assert_grep 'seeded:' "$case_dir/stdout" "happy-path: missing success message"
  [ "$(git -C "$case_dir/proj" log --oneline | wc -l | tr -d ' ')" = 1 ] \
    || fail "happy-path: local branch should have exactly one commit"
  [ "$(git -C "$case_dir/proj" log -1 --format=%s)" = "Initial commit" ] \
    || fail "happy-path: commit message was not 'Initial commit'"
  [ "$(git -C "$case_dir/remotes/github.com/example/promo-reel-forge" log --oneline | wc -l | tr -d ' ')" = 1 ] \
    || fail "happy-path: the commit was not pushed to the remote"
  pass "fm-seed-empty-repo seeds and pushes a single empty commit on a genuinely empty repo"
}

test_refuses_nonzero_size() {
  local case_dir rc
  case_dir="$TMP_ROOT/nonzero-size"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example repo
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_REPO_SIZE=42 run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nonzero-size: fm-seed-empty-repo should refuse"
  assert_grep 'REFUSED:' "$case_dir/stderr" "nonzero-size: refusal was not loud"
  assert_grep 'non-zero size' "$case_dir/stderr" "nonzero-size: refusal did not explain the size mismatch"
  [ "$(git -C "$case_dir/proj" log --oneline 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "nonzero-size: a commit was created despite refusal"
  pass "fm-seed-empty-repo refuses a repo with non-zero size"
}

test_refuses_nonempty_branches() {
  local case_dir rc
  case_dir="$TMP_ROOT/nonempty-branches"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example repo
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_BRANCHES=$'[1]:\n  - name: main' run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nonempty-branches: fm-seed-empty-repo should refuse"
  assert_grep 'REFUSED:' "$case_dir/stderr" "nonempty-branches: refusal was not loud"
  assert_grep 'branch(es)' "$case_dir/stderr" "nonempty-branches: refusal did not explain the branch count"
  [ "$(git -C "$case_dir/proj" log --oneline 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "nonempty-branches: a commit was created despite refusal"
  pass "fm-seed-empty-repo refuses a repo with any existing branch"
}

test_refuses_commits_api_success() {
  local case_dir rc
  case_dir="$TMP_ROOT/commits-succeed"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example repo
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_COMMITS_MODE=success run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "commits-succeed: fm-seed-empty-repo should refuse"
  assert_grep 'REFUSED:' "$case_dir/stderr" "commits-succeed: refusal was not loud"
  assert_grep 'commit history' "$case_dir/stderr" "commits-succeed: refusal did not cite commit history"
  [ "$(git -C "$case_dir/proj" log --oneline 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "commits-succeed: a commit was created despite refusal"
  pass "fm-seed-empty-repo refuses when the commits API unexpectedly returns real history"
}

test_refuses_inconclusive_commits_failure() {
  local case_dir rc
  case_dir="$TMP_ROOT/commits-inconclusive"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example repo
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_COMMITS_MODE=error run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "commits-inconclusive: fm-seed-empty-repo should refuse"
  assert_grep 'REFUSED:' "$case_dir/stderr" "commits-inconclusive: refusal was not loud"
  assert_grep 'could not confirm' "$case_dir/stderr" \
    "commits-inconclusive: refusal did not distinguish an inconclusive failure from a confirmed-empty one"
  [ "$(git -C "$case_dir/proj" log --oneline 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "commits-inconclusive: a commit was created despite refusal"
  pass "fm-seed-empty-repo refuses when the commits API fails for a reason other than emptiness"
}

test_refuses_no_origin_remote() {
  local case_dir rc
  case_dir="$TMP_ROOT/no-origin"
  mkdir -p "$case_dir/proj"
  git init --quiet "$case_dir/proj"
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-origin: fm-seed-empty-repo should refuse"
  assert_grep 'error: ' "$case_dir/stderr" "no-origin: refusal message missing"
  assert_grep 'no origin remote' "$case_dir/stderr" "no-origin: refusal did not name the missing remote"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "no-origin: gh-axi was invoked despite no origin remote"
  pass "fm-seed-empty-repo refuses a project with no origin remote"
}

test_refuses_non_github_origin() {
  local case_dir rc bare
  case_dir="$TMP_ROOT/non-github"
  bare="$case_dir/remotes/gitlab.com/example/repo"
  mkdir -p "$bare"
  git init --quiet --bare "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone --quiet "file://$bare" "$case_dir/proj"
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "non-github: fm-seed-empty-repo should refuse"
  assert_grep 'not a GitHub repository' "$case_dir/stderr" "non-github: refusal did not name the problem"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "non-github: gh-axi was invoked despite a non-GitHub origin"
  pass "fm-seed-empty-repo refuses a project whose origin is not a GitHub URL"
}

test_refuses_dirty_working_tree() {
  local case_dir rc
  case_dir="$TMP_ROOT/dirty-tree"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example repo
  echo scratch > "$case_dir/proj/untracked.txt"
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-tree: fm-seed-empty-repo should refuse"
  assert_grep 'dirty working tree' "$case_dir/stderr" "dirty-tree: refusal did not name the dirty tree"
  [ "$(git -C "$case_dir/proj" log --oneline 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "dirty-tree: a commit was created despite refusal"
  pass "fm-seed-empty-repo refuses to seed a commit into a dirty working tree"
}

test_refuses_when_local_branch_already_seeded() {
  local case_dir rc
  case_dir="$TMP_ROOT/already-seeded"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example repo
  git -C "$case_dir/proj" commit --quiet --allow-empty -m "Initial commit"
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "already-seeded: fm-seed-empty-repo should refuse"
  assert_grep 'already has a commit' "$case_dir/stderr" "already-seeded: refusal did not name the existing local commit"
  [ "$(git -C "$case_dir/proj" log --oneline | wc -l | tr -d ' ')" = 1 ] \
    || fail "already-seeded: a second commit was created despite refusal"
  pass "fm-seed-empty-repo refuses when the local default branch already has a commit"
}

test_refuses_branch_mismatch() {
  local case_dir rc
  case_dir="$TMP_ROOT/branch-mismatch"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example repo main
  git -C "$case_dir/proj" symbolic-ref HEAD refs/heads/other
  add_gh_axi_mock "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_DEFAULT_BRANCH=main run_seed "$case_dir" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "branch-mismatch: fm-seed-empty-repo should refuse"
  assert_grep 'refusing to seed the wrong branch' "$case_dir/stderr" \
    "branch-mismatch: refusal did not explain the branch mismatch"
  pass "fm-seed-empty-repo refuses when the local branch disagrees with the remote's default branch"
}

test_refuses_without_gh_axi() {
  local case_dir rc
  case_dir="$TMP_ROOT/no-gh-axi"
  mkdir -p "$case_dir"
  make_empty_clone "$case_dir" example repo

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" PATH="/usr/bin:/bin" \
    "$SEED" "$case_dir/proj" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-gh-axi: fm-seed-empty-repo should refuse"
  assert_grep 'gh-axi is required' "$case_dir/stderr" "no-gh-axi: refusal did not name the missing tool"
  [ "$(git -C "$case_dir/proj" log --oneline 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
    || fail "no-gh-axi: a commit was created despite refusal"
  pass "fm-seed-empty-repo refuses when gh-axi is unavailable to verify emptiness"
}

test_seeds_and_pushes_genuinely_empty_repo
test_refuses_nonzero_size
test_refuses_nonempty_branches
test_refuses_commits_api_success
test_refuses_inconclusive_commits_failure
test_refuses_no_origin_remote
test_refuses_non_github_origin
test_refuses_dirty_working_tree
test_refuses_when_local_branch_already_seeded
test_refuses_branch_mismatch
test_refuses_without_gh_axi
