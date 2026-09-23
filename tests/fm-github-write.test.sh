#!/usr/bin/env bash
# Behavioral tests for the bounded direct-PR and autonomous GitHub merge entry
# point, including authoritative identity derivation, refusal paths, Automic
# Vault routing, and digest-bound changed-script invalidation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-github-write-tests)
REAL_GIT=$(command -v git) || fail "git is required"

make_case() {
  local name=$1 home project wt id=task-x1
  home="$TMP_ROOT/$name/home"
  project="$TMP_ROOT/$name/project"
  wt="$TMP_ROOT/$name/worktree"
  mkdir -p "$home/bin" "$home/state" "$project"
  cp "$ROOT/bin/fm-github-write.sh" "$ROOT/bin/fm-github-write-av.sh" \
    "$ROOT/bin/fm-pr-merge.sh" "$home/bin/"
  chmod +x "$home/bin/"*.sh
  git init -q -b main "$project"
  git -C "$project" commit -q --allow-empty -m baseline
  git -C "$project" remote add origin git@github.com:base-owner/sample.git
  git -C "$project" remote set-url --push origin git@github.com:push-owner/sample.git
  git -C "$project" update-ref refs/remotes/origin/main "$(git -C "$project" rev-parse HEAD)"
  git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$project" config extensions.worktreeConfig true
  git -C "$project" worktree add -q -b "fm/$id" "$wt"
  cat > "$home/state/$id.meta" <<EOF
worktree=$wt
project=$project
kind=ship
mode=direct-PR
yolo=on
EOF
  printf 'Pull request body.\n' > "$wt/pr-body.md"
  printf '%s|%s|%s|%s\n' "$home" "$project" "$wt" "$id"
}

add_tools() {
  local case_dir=$1
  local fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" push "*)
    printf '%s\n' "$*" >> "$FM_TEST_GIT_LOG"
    printf 'To github.com:push-owner/sample.git\n'
    exit 0
    ;;
esac
exec "$FM_TEST_REAL_GIT" "$@"
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "api /repos/"*)
    if [ -s "$FM_TEST_EXISTING_PR" ]; then
      count=$(awk 'NF { n++ } END { print n + 0 }' "$FM_TEST_EXISTING_PR")
      printf '[%s]{number,url}:\n' "$count"
      while IFS=$'\t' read -r number url; do
        [ -n "$number" ] || continue
        printf '  %s,"%s"\n' "$number" "$url"
      done < "$FM_TEST_EXISTING_PR"
    else
      printf '[]\n'
    fi
    ;;
  "pr create")
    printf 'created:\n  number: 41\n  url: "https://github.com/base-owner/sample/pull/41"\n'
    ;;
  "pr edit") ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/git" "$fakebin/gh-axi"
}

run_write() {
  local home=$1 wt=$2; shift 2
  local case_dir=${home%/home}
  (
    cd "$wt" || exit 1
    FM_GITHUB_WRITE_ACTIVE=1 \
    FM_TEST_REAL_GIT="$REAL_GIT" \
    FM_TEST_GIT_LOG="$case_dir/git.log" \
    FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_EXISTING_PR="$case_dir/existing-pr" \
    PATH="$case_dir/fakebin:$PATH" \
      "$home/bin/fm-github-write.sh" "$@"
  )
}

run_shared_write() {
  local home=$1 wt=$2; shift 2
  local case_dir=${home%/home}
  (
    cd "$wt" || exit 1
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_GITHUB_WRITE_ACTIVE=1 \
    FM_TEST_REAL_GIT="$REAL_GIT" \
    FM_TEST_GIT_LOG="$case_dir/git.log" \
    FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_EXISTING_PR="$case_dir/existing-pr" \
    PATH="$case_dir/fakebin:$PATH" \
      "$ROOT/bin/fm-github-write.sh" "$@"
  )
}

assert_no_write_calls() {
  local case_dir=$1
  [ ! -s "$case_dir/git.log" ] || fail "refused case attempted a git push"
  [ ! -s "$case_dir/gh.log" ] || fail "refused case attempted a GitHub call"
}

test_direct_pr_derives_identity_and_creates_pr() {
  local rec home project wt id case_dir out
  rec=$(make_case direct-create)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}
  add_tools "$case_dir"
  out=$(run_write "$home" "$wt" direct-pr "$id" --title 'Bounded change' --body-file "$wt/pr-body.md") \
    || fail "bounded direct-PR create failed"
  assert_contains "$out" "https://github.com/base-owner/sample/pull/41" \
    "direct-PR did not return the canonical PR URL"
  assert_grep "push --porcelain ssh://git@github.com/push-owner/sample.git HEAD:refs/heads/fm/$id" \
    "$case_dir/git.log" "direct-PR push did not use the derived exact destination and branch"
  assert_grep "api /repos/base-owner/sample/pulls?state=open&per_page=2&head=push-owner%3Afm%2F$id&base=main" \
    "$case_dir/gh.log" "direct-PR lookup did not use the derived base and head identities"
  assert_grep "pr create --repo base-owner/sample --base main --head push-owner:fm/$id" \
    "$case_dir/gh.log" "direct-PR create did not stay on the derived PR identity"
  pass "bounded direct-PR derives project, fork, branch, base, and PR identity from Firstmate records"
}

test_direct_pr_updates_only_matching_pr() {
  local rec home project wt id case_dir out
  rec=$(make_case direct-update)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}
  add_tools "$case_dir"
  printf '17\thttps://github.com/base-owner/sample/pull/17\n' > "$case_dir/existing-pr"
  out=$(run_write "$home" "$wt" direct-pr "$id" --title 'Updated title' --body-file "$wt/pr-body.md") \
    || fail "bounded direct-PR update failed"
  [ "$out" = 'https://github.com/base-owner/sample/pull/17' ] \
    || fail "direct-PR update returned the wrong URL: $out"
  assert_grep 'pr edit 17 --repo base-owner/sample --title Updated title' "$case_dir/gh.log" \
    "direct-PR did not update the one matching PR"
  assert_no_grep 'pr create' "$case_dir/gh.log" "direct-PR created a duplicate PR"
  pass "bounded direct-PR updates only the canonical open PR for its exact branch"
}

test_direct_pr_uses_isolated_home_with_shared_code() {
  local rec home project wt id case_dir out
  rec=$(make_case isolated-home)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}
  add_tools "$case_dir"
  out=$(run_shared_write "$home" "$wt" direct-pr "$id" --title 'Isolated home' --body-file "$wt/pr-body.md") \
    || fail "shared direct-PR entry point ignored the isolated Firstmate home"
  assert_contains "$out" "https://github.com/base-owner/sample/pull/41" \
    "shared direct-PR entry point did not publish from isolated-home task metadata"
  pass "shared direct-PR code resolves task metadata from the selected isolated home"
}

test_direct_pr_refusals_precede_writes() {
  local rec home project wt id case_dir out rc outside other

  rec=$(make_case wrong-cwd)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}; add_tools "$case_dir"
  set +e
  out=$(run_write "$home" "$project" direct-pr "$id" --title title --body-file "$wt/pr-body.md" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'recorded worktree' "wrong cwd refusal was unclear"
  assert_no_write_calls "$case_dir"

  rec=$(make_case wrong-branch)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}; add_tools "$case_dir"
  git -C "$wt" branch -m not-the-task
  set +e
  out=$(run_write "$home" "$wt" direct-pr "$id" --title title --body-file "$wt/pr-body.md" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" "branch fm/$id" "wrong branch refusal was unclear"
  assert_no_write_calls "$case_dir"

  rec=$(make_case origin-mismatch)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}; add_tools "$case_dir"
  git -C "$wt" config --worktree remote.origin.url git@github.com:other/sample.git
  set +e
  out=$(run_write "$home" "$wt" direct-pr "$id" --title title --body-file "$wt/pr-body.md" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'remote.origin.url' "origin mismatch refusal was unclear"
  assert_no_write_calls "$case_dir"

  rec=$(make_case url-rewrite)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}; add_tools "$case_dir"
  git -C "$wt" config --worktree url.ext::evil.insteadOf ssh://git@github.com/
  set +e
  out=$(run_write "$home" "$wt" direct-pr "$id" --title title --body-file "$wt/pr-body.md" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'would change the verified push destination' \
    "Git URL rewrite refusal was unclear"
  assert_no_write_calls "$case_dir"

  rec=$(make_case wrong-mode)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}; add_tools "$case_dir"
  perl -0pi -e 's/mode=direct-PR/mode=no-mistakes/' "$home/state/$id.meta"
  set +e
  out=$(run_write "$home" "$wt" direct-pr "$id" --title title --body-file "$wt/pr-body.md" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'not direct-PR' "wrong mode refusal was unclear"
  assert_no_write_calls "$case_dir"

  rec=$(make_case body-outside)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}; add_tools "$case_dir"
  outside="$case_dir/outside.md"; printf 'body\n' > "$outside"
  set +e
  out=$(run_write "$home" "$wt" direct-pr "$id" --title title --body-file "$outside" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'inside the task worktree' "outside body refusal was unclear"
  assert_no_write_calls "$case_dir"

  rec=$(make_case duplicate-pr)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}; add_tools "$case_dir"
  printf '17\thttps://github.com/base-owner/sample/pull/17\n18\thttps://github.com/base-owner/sample/pull/18\n' > "$case_dir/existing-pr"
  set +e
  out=$(run_write "$home" "$wt" direct-pr "$id" --title title --body-file "$wt/pr-body.md" 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'more than one open pull request' "duplicate PR refusal was unclear"
  [ "$(wc -l < "$case_dir/git.log" | tr -d ' ')" -eq 1 ] || fail "duplicate PR case did not limit itself to one exact push"
  assert_no_grep 'pr create\|pr edit' "$case_dir/gh.log" "duplicate PR case attempted a PR write"

  pass "direct-PR refuses wrong task, branch, origin, mode, body, and ambiguous PR identity"
}

test_merge_requires_yolo_and_bound_guard_script() {
  local rec home project wt id case_dir out rc
  rec=$(make_case merge-boundary)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}; add_tools "$case_dir"
  perl -0pi -e 's/yolo=on/yolo=off/' "$home/state/$id.meta"
  set +e
  out=$(run_write "$home" "$wt" merge "$id" https://github.com/base-owner/sample/pull/9 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'does not carry standing autonomous merge authority' \
    "yolo-off merge refusal was unclear"
  assert_no_write_calls "$case_dir"

  perl -0pi -e 's/yolo=off/yolo=on/' "$home/state/$id.meta"
  printf '# changed after review\n' >> "$home/bin/fm-pr-merge.sh"
  set +e
  out=$(run_write "$home" "$wt" merge "$id" https://github.com/base-owner/sample/pull/9 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'changed after the reviewed GitHub-write declaration' \
    "changed merge guard did not invalidate reviewed authority"
  assert_no_write_calls "$case_dir"
  pass "autonomous merge requires recorded yolo authority and the exact reviewed guarded merge script"
}

test_automic_selection_and_wrapper_content_binding() {
  local rec home project wt id case_dir fakeav out rc
  rec=$(make_case automic-routing)
  IFS='|' read -r home project wt id <<EOF
$rec
EOF
  case_dir=${home%/home}
  fakeav="$case_dir/fake-av"
  cat > "$fakeav" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$home/bin/fm-github-write-av.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_TEST_AV_LOG"
SH
  chmod +x "$fakeav" "$home/bin/fm-github-write-av.sh"
  (
    cd "$wt" || exit 1
    FM_AUTOMIC_VAULT_BIN="$fakeav" FM_TEST_AV_LOG="$case_dir/av.log" \
      "$home/bin/fm-github-write.sh" direct-pr "$id" --title title --body-file "$wt/pr-body.md"
  ) || fail "Automic routing probe failed"
  assert_grep "direct-pr $id --title title --body-file $wt/pr-body.md" "$case_dir/av.log" \
    "installed Automic path did not route through the Blessed Script wrapper"

  cp "$ROOT/bin/fm-github-write-av.sh" "$home/bin/fm-github-write-av.sh"
  printf '# changed implementation\n' >> "$home/bin/fm-github-write.sh"
  set +e
  out=$(/bin/bash "$home/bin/fm-github-write-av.sh" help 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] && assert_contains "$out" 'changed after this Automic Vault declaration was reviewed' \
    "changed delivery implementation inherited the old declaration"
  pass "Automic installations select the Blessed path and implementation changes invalidate its content binding"
}

test_direct_pr_derives_identity_and_creates_pr
test_direct_pr_updates_only_matching_pr
test_direct_pr_uses_isolated_home_with_shared_code
test_direct_pr_refusals_precede_writes
test_merge_requires_yolo_and_bound_guard_script
test_automic_selection_and_wrapper_content_binding

printf '\nAll fm-github-write tests passed.\n'
