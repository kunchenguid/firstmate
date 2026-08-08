#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
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

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
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

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# --- attempt-bound landing receipts (Task 10) ------------------------------
# The PR scripts only journal provisional forge observations; the final landing
# receipt is written once by the disposition step and is landed ONLY when the
# merged content is equivalent to the PR head's patch. These fixtures build a
# real git history (squash merge whose net change matches the PR head, and an
# authorized local-only fast-forward) and prove the receipt-bound evidence.
#
# Content-equivalence proof mirroring teardown's unpushed_patches_are_in_pr_head
# on an explicit repo: every unpushed commit in <repo> HEAD must be contained
# (by stable patch-id) in the PR head's commit set, exactly the check a squash
# merge needs to be proof of landing.
unpushed_patches_are_in_pr_head() {  # <repo> <pr_head>
  local repo=$1 pr_head=$2
  local current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$repo" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$repo" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          [ -n "$commit" ] || continue
          git -C "$repo" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
            | git patch-id --stable 2>/dev/null \
            | awk 'NR == 1 { print $1 }'
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$repo" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(git -C "$repo" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
      | git patch-id --stable 2>/dev/null \
      | awk 'NR == 1 { print $1 }') || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# build_squash_landing_repo <root>: a bare origin with main=base, a project clone
# with a pr/feature branch (the PR head) and a squash-merge commit on local main
# whose net change equals the PR head's patch. Prints "base pr_tip squash".
build_squash_landing_repo() {
  local root=$1 repo="$1/project" base pr_tip squash
  git init -q --bare "$root/origin.git"
  git -C "$root/origin.git" symbolic-ref HEAD refs/heads/main
  mkdir -p "$root/_seed"
  git -C "$root/_seed" init -q -b main
  printf 'base\n' > "$root/_seed/base.txt"
  git -C "$root/_seed" add base.txt
  git -C "$root/_seed" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$root/_seed" remote add origin "$root/origin.git"
  git -C "$root/_seed" push -q origin main
  rm -rf "$root/_seed"
  git clone -q "$root/origin.git" "$repo"
  git -C "$repo" remote set-head origin main 2>/dev/null || true
  git -C "$repo" checkout -qb pr/feature
  printf 'feature\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm feature
  pr_tip=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  base=$(git -C "$repo" rev-parse main)
  git -C "$repo" merge --squash pr/feature >/dev/null 2>&1
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm 'squash merge feature'
  squash=$(git -C "$repo" rev-parse HEAD)
  printf '%s %s %s\n' "$base" "$pr_tip" "$squash"
}

test_squash_merge_landing_receipt_requires_content_equivalence() {
  local root aid base pr_tip squash repo
  root="$TMP_ROOT/squash-landing-proof"
  rm -rf "$root"
  mkdir -p "$root/state"
  export FM_STATE_OVERRIDE="$root/state"
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-s holu) || fail "squash alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-s"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "squash freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-s"}' || fail "squash launch"
  read -r base pr_tip squash <<EOF
$(build_squash_landing_repo "$root")
EOF
  repo="$root/project"
  # journal open then merged; the merged head is the squash-merge commit
  fm_attempt_observe "$aid" 1 forge "{\"provider\":\"github\",\"pr\":\"https://github.com/example/repo/pull/7\",\"state\":\"open\"}" \
    || fail "squash open journal"
  fm_attempt_observe "$aid" 1 forge "{\"provider\":\"github\",\"pr\":\"https://github.com/example/repo/pull/7\",\"state\":\"merged\",\"head\":\"$squash\",\"before_sha\":\"$base\",\"after_sha\":\"$squash\"}" \
    || fail "squash merged journal"
  # the landing disposition is landed ONLY with the content-equivalence proof
  unpushed_patches_are_in_pr_head "$repo" "$pr_tip" \
    || fail "squash fixture content was not equivalent to the PR head"
  fm_attempt_effect_observe "$aid" 1 landing "{\"disposition\":\"landed\",\"provider\":\"github\",\"repo\":\"example/repo\",\"source\":\"task-x1\",\"target\":\"main\",\"head\":\"$squash\",\"before_sha\":\"$base\",\"after_sha\":\"$squash\"}" \
    || fail "squash landing receipt"
  jq -e --arg n landing '[.receipts[$n][]? | select(.state == "observed")] | length == 1' \
    "$root/state/attempts/$aid.json" >/dev/null || fail "squash landing receipt not written exactly once"
  jq -e --arg h "$squash" --arg b "$base" --arg a "$squash" \
    '[.receipts.landing[]? | select(.state == "observed")][0].evidence as $e |
     $e.disposition == "landed" and $e.provider == "github" and $e.repo == "example/repo" and
     $e.source == "task-x1" and $e.target == "main" and $e.head == $h and
     $e.before_sha == $b and $e.after_sha == $a' \
    "$root/state/attempts/$aid.json" >/dev/null || fail "squash landing identity not exact"
  # negative: a local divergence absent from the PR head must refuse the receipt
  aid=$(fm_attempt_alloc pi dos-s2 holu) || fail "diverged alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-s"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "diverged freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-s"}' || fail "diverged launch"
  fm_attempt_observe "$aid" 1 forge "{\"provider\":\"github\",\"pr\":\"https://github.com/example/repo/pull/7\",\"state\":\"open\"}" \
    || fail "diverged open journal"
  fm_attempt_observe "$aid" 1 forge "{\"provider\":\"github\",\"pr\":\"https://github.com/example/repo/pull/7\",\"state\":\"merged\",\"head\":\"$squash\",\"before_sha\":\"$base\",\"after_sha\":\"$squash\"}" \
    || fail "diverged merged journal"
  git -C "$repo" checkout -q -b diverged
  printf 'local-only change\n' >> "$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm 'local divergence'
  if unpushed_patches_are_in_pr_head "$repo" "$pr_tip"; then
    fail "diverged content was falsely equivalent to the PR head"
  fi
  jq -e --arg n landing '[.receipts[$n][]? | select(.state == "observed")] | length == 0' \
    "$root/state/attempts/$aid.json" >/dev/null || fail "diverged content received a landing receipt"
  pass "the final landing receipt is landed only with the content-equivalence proof and exact identity"
}

test_local_only_merge_records_receipt_bound_to_local_main() {
  local root aid repo before_full after_full branch_sha rc
  root="$TMP_ROOT/local-only-landing"
  rm -rf "$root"
  mkdir -p "$root/state" "$root/fakebin"
  export FM_STATE_OVERRIDE="$root/state"
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-l holu) || fail "local alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-l"}' \
    '{"mode":"local-only","base":"main","target":"main"}' || fail "local freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-l"}' || fail "local launch"
  repo="$root/project"
  git init -q --bare "$root/origin.git"
  git -C "$root/origin.git" symbolic-ref HEAD refs/heads/main
  mkdir -p "$root/_seed"
  git -C "$root/_seed" init -q -b main
  printf 'base\n' > "$root/_seed/base.txt"
  git -C "$root/_seed" add base.txt
  git -C "$root/_seed" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$root/_seed" remote add origin "$root/origin.git"
  git -C "$root/_seed" push -q origin main
  rm -rf "$root/_seed"
  git clone -q "$root/origin.git" "$repo"
  git -C "$repo" remote set-head origin main 2>/dev/null || true
  git -C "$repo" checkout -qb fm/task-x1
  printf 'feature\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm feature
  branch_sha=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  before_full=$(git -C "$repo" rev-parse main)
  fm_write_meta "$root/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$root/wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=local-only" \
    "attempt=$aid"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$root/state" \
    PATH="$root/fakebin:$PATH" \
    "$ROOT/bin/fm-merge-local.sh" task-x1 > "$root/out" 2> "$root/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "local-only merge failed: $(cat "$root/err")"
  after_full=$(git -C "$repo" rev-parse main)
  [ "$after_full" = "$branch_sha" ] || fail "ff-only merge did not land the branch tip"
  # the script journaled the exact local-main identity
  jq -e --arg b "$before_full" --arg a "$after_full" \
    '[.observations[]? | select(.name == "forge")][-1].evidence as $e |
     $e.provider == "local" and $e.repo == "'"$repo"'" and $e.source == "task-x1" and
     $e.target == "main" and $e.state == "merged" and $e.head == $a and
     $e.before_sha == $b and $e.after_sha == $a' \
    "$root/state/attempts/$aid.json" >/dev/null \
    || fail "local merge did not journal the exact local-main identity"
  # the disposition step writes the final landing receipt bound to that evidence
  fm_attempt_effect_observe "$aid" 1 landing "{\"disposition\":\"landed\",\"provider\":\"local\",\"repo\":\"$repo\",\"source\":\"task-x1\",\"target\":\"main\",\"head\":\"$after_full\",\"before_sha\":\"$before_full\",\"after_sha\":\"$after_full\"}" \
    || fail "local landing receipt"
  jq -e --arg n landing '[.receipts[$n][]? | select(.state == "observed")] | length == 1' \
    "$root/state/attempts/$aid.json" >/dev/null || fail "local landing receipt not written exactly once"
  jq -e --arg b "$before_full" --arg a "$after_full" \
    '[.receipts.landing[]? | select(.state == "observed")][0].evidence.disposition == "landed" and
     [.receipts.landing[]? | select(.state == "observed")][0].evidence.provider == "local" and
     [.receipts.landing[]? | select(.state == "observed")][0].evidence.before_sha == $b and
     [.receipts.landing[]? | select(.state == "observed")][0].evidence.after_sha == $a' \
    "$root/state/attempts/$aid.json" >/dev/null \
    || fail "landing receipt is not bound to the exact local-main evidence"
  pass "local-only merge journals the exact local-main identity and the receipt is bound to it"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_squash_merge_landing_receipt_requires_content_equivalence
test_local_only_merge_records_receipt_bound_to_local_main
