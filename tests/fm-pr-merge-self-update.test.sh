#!/usr/bin/env bash
# Behavior tests for the EVENT trigger of the automatic primary-checkout
# self-update: bin/fm-pr-merge.sh calling bin/fm-ff-lib.sh's
# primary_self_update() once, immediately, after it confirms a merge is
# firstmate's own repo. This closes the gap the cadence trigger
# (bin/fm-bootstrap.sh, covered in tests/fm-primary-self-update.test.sh)
# leaves open on its own: a PR merged mid-session, with no session restart
# to run the cadence sweep, previously left the primary checkout - and
# anything it locally serves, such as a Mission Control board - stale until
# whenever the next session happened to start.
#
# Both triggers call the identical function, so these cases pin only what is
# new here: the trigger fires for a firstmate-repo merge and correctly stays
# out of an unrelated project's merge, a block is reported without turning an
# otherwise-successful merge into a failure, and a failed merge never even
# attempts it. FM_ROOT's origin is set to a github.com-shaped URL with a
# local url.insteadOf rewrite so the fetch this trigger performs stays
# hermetic (no real network), while still exercising the real owner/repo
# match against a real GitHub-style remote URL. fm-pr-merge.sh redirects this
# call's output to stderr (matching its own evidence-check warnings), so
# SELF_UPDATE/SELF_UPDATE_BLOCKED assertions below read stderr, not stdout.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-self-update)

# gh-axi mock recording every invocation; its gh companion always resolves
# headRefOid, since the evidence-check path is exercised elsewhere and is
# not this file's concern.
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Task-state fixture: a state dir with one task's meta, an unrelated task
# worktree the evidence check will skip over (no directory-scoped changes
# possible with nothing on disk beyond the bare dir). Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/wt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# A fake FM_ROOT fixture: seed -> bare "true origin" (advanced one commit
# past the tracked clone) -> tracked clone, whose origin remote is a
# github.com-shaped URL rewritten locally via url.insteadOf so ff_target's
# fetch stays hermetic while the real owner/repo match logic still runs
# against a real GitHub-style remote string. Echoes the tracked clone path.
make_primary_fixture() {
  local label=$1 slug=$2
  local origin_url=${3:-https://github.com/$slug.git}
  local seed bare tracked origin_work
  seed="$TMP_ROOT/$label-seed"
  git init -q -b main "$seed"
  printf 'projects/\nstate/\ndata/\nconfig/\n' > "$seed/.gitignore"
  git -C "$seed" add .gitignore
  git -C "$seed" commit -q -m init
  bare="$TMP_ROOT/$label-origin.git"
  git clone --quiet --bare "$seed" "$bare" >/dev/null
  tracked="$TMP_ROOT/$label-tracked"
  git clone --quiet "$bare" "$tracked" >/dev/null
  git -C "$tracked" remote set-url origin "$origin_url"
  git -C "$tracked" config "url.file://$bare.insteadOf" "$origin_url"
  origin_work="$TMP_ROOT/$label-origin-work"
  git clone --quiet "$bare" "$origin_work" >/dev/null
  git -C "$origin_work" commit -q --allow-empty -m "upstream merge"
  git -C "$origin_work" push --quiet origin main
  printf '%s\n' "$tracked"
}

run_pr_merge() {
  local case_dir=$1 root=$2; shift 2
  FM_ROOT_OVERRIDE="$root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_firstmate_repo_merge_triggers_fast_forward() {
  local case_dir root rc
  case_dir=$(make_case matching-repo)
  root=$(make_primary_fixture matching-repo acme/firstmate)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"
  local before after
  before=$(git -C "$root" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" "$root" task-x1 https://github.com/acme/firstmate/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "matching-repo: fm-pr-merge should succeed"
  after=$(git -C "$root" rev-parse HEAD)
  [ "$before" != "$after" ] \
    || fail "matching-repo: primary checkout was not fast-forwarded after a firstmate-repo merge"
  pass "fm-pr-merge fast-forwards the primary checkout immediately after merging firstmate's own repo"
}

test_other_project_merge_never_touches_primary() {
  local case_dir root rc before after
  case_dir=$(make_case other-repo)
  root=$(make_primary_fixture other-repo acme/firstmate)
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"
  before=$(git -C "$root" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" "$root" task-x1 https://github.com/someone-else/other-project/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "other-repo: fm-pr-merge should succeed"
  after=$(git -C "$root" rev-parse HEAD)
  [ "$before" = "$after" ] \
    || fail "other-repo: an unrelated project's merge fast-forwarded the primary checkout; the trigger must scope to firstmate's own repo only"
  assert_not_contains "$(cat "$case_dir/stderr")" "SELF_UPDATE" \
    "other-repo: an unrelated project's merge must never attempt or report the primary self-update"
  pass "fm-pr-merge never fast-forwards the primary checkout for a merge of an unrelated project"
}

test_github_path_segment_lookalike_never_touches_primary() {
  local case_dir root rc before after
  case_dir=$(make_case github-path-lookalike)
  root=$(make_primary_fixture github-path-lookalike acme/firstmate \
    file:///srv/github.com/acme/firstmate.git)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"
  before=$(git -C "$root" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" "$root" task-x1 https://github.com/acme/firstmate/pull/45 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-path-lookalike: fm-pr-merge should succeed"
  after=$(git -C "$root" rev-parse HEAD)
  [ "$before" = "$after" ] \
    || fail "github-path-lookalike: a non-GitHub origin containing github.com in its path triggered the self-update"
  assert_not_contains "$(cat "$case_dir/stderr")" "SELF_UPDATE" \
    "github-path-lookalike: a non-GitHub origin must never attempt or report the primary self-update"
  pass "fm-pr-merge rejects a non-GitHub origin containing github.com in its path"
}

test_case_variant_github_host_triggers_fast_forward() {
  local case_dir root rc before after
  case_dir=$(make_case case-variant-host)
  root=$(make_primary_fixture case-variant-host acme/firstmate \
    https://GitHub.com/acme/firstmate.git)
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"
  before=$(git -C "$root" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" "$root" task-x1 https://github.com/acme/firstmate/pull/46 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "case-variant-host: fm-pr-merge should succeed"
  after=$(git -C "$root" rev-parse HEAD)
  [ "$before" != "$after" ] \
    || fail "case-variant-host: a case-variant GitHub host did not trigger the primary self-update"
  pass "fm-pr-merge accepts a case-variant GitHub host"
}

test_one_component_github_origin_never_touches_primary() {
  local case_dir root rc before after
  case_dir=$(make_case one-component-origin)
  root=$(make_primary_fixture one-component-origin acme/firstmate \
    https://github.com/acme)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"
  before=$(git -C "$root" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" "$root" task-x1 https://github.com/acme/acme/pull/47 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "one-component-origin: fm-pr-merge should succeed"
  after=$(git -C "$root" rev-parse HEAD)
  [ "$before" = "$after" ] \
    || fail "one-component-origin: a malformed GitHub origin triggered the self-update"
  assert_not_contains "$(cat "$case_dir/stderr")" "SELF_UPDATE" \
    "one-component-origin: a malformed GitHub origin must never attempt or report the primary self-update"
  pass "fm-pr-merge rejects a one-component GitHub origin"
}

test_git_ssh_origin_triggers_fast_forward() {
  local case_dir root rc before after
  case_dir=$(make_case git-ssh-origin)
  root=$(make_primary_fixture git-ssh-origin acme/firstmate \
    git@GitHub.com:acme/firstmate.git)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"
  before=$(git -C "$root" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" "$root" task-x1 https://github.com/acme/firstmate/pull/48 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "git-ssh-origin: fm-pr-merge should succeed"
  after=$(git -C "$root" rev-parse HEAD)
  [ "$before" != "$after" ] \
    || fail "git-ssh-origin: a GitHub SSH origin did not trigger the primary self-update"
  pass "fm-pr-merge accepts a GitHub SSH origin"
}

test_dirty_primary_blocked_without_failing_the_merge() {
  local case_dir root rc before after out
  case_dir=$(make_case dirty-repo)
  root=$(make_primary_fixture dirty-repo acme/firstmate)
  printf 'stray\n' > "$root/dirty.txt"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"
  before=$(git -C "$root" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" "$root" task-x1 https://github.com/acme/firstmate/pull/43 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "dirty-repo: a blocked self-update must never turn a successful merge into a failure"
  out=$(cat "$case_dir/stderr")
  assert_contains "$out" "SELF_UPDATE_BLOCKED:" "dirty-repo: fm-pr-merge did not report SELF_UPDATE_BLOCKED"
  assert_contains "$out" "stale code" "dirty-repo: SELF_UPDATE_BLOCKED did not warn that locally-served surfaces may be stale"
  after=$(git -C "$root" rev-parse HEAD)
  [ "$before" = "$after" ] || fail "dirty-repo: a dirty primary checkout was advanced despite being refused"
  [ -f "$root/dirty.txt" ] || fail "dirty-repo: the uncommitted change was lost"
  pass "fm-pr-merge reports a blocked primary self-update without failing an otherwise-successful merge"
}

test_merge_failure_never_attempts_self_update() {
  local case_dir root rc before after
  case_dir=$(make_case merge-fails)
  root=$(make_primary_fixture merge-fails acme/firstmate)
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  before=$(git -C "$root" rev-parse HEAD)

  set +e
  run_pr_merge "$case_dir" "$root" task-x1 https://github.com/acme/firstmate/pull/44 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  after=$(git -C "$root" rev-parse HEAD)
  [ "$before" = "$after" ] \
    || fail "merge-fails: the primary checkout was fast-forwarded even though the merge itself failed"
  pass "fm-pr-merge never attempts the primary self-update when the merge itself fails"
}

test_firstmate_repo_merge_triggers_fast_forward
test_other_project_merge_never_touches_primary
test_github_path_segment_lookalike_never_touches_primary
test_case_variant_github_host_triggers_fast_forward
test_one_component_github_origin_never_touches_primary
test_git_ssh_origin_triggers_fast_forward
test_dirty_primary_blocked_without_failing_the_merge
test_merge_failure_never_attempts_self_update
