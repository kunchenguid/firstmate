#!/usr/bin/env bash
# End-to-end git tests for branch cleanup across origin and the no-mistakes
# daemon's separate bare remote.
# Every case uses real repositories, refs,
# pushes, worktrees, and expected-old-value remote deletion. GitHub responses
# are simulated only where a squash merge requires the existing PR-head proof.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CLEANUP="$ROOT/bin/fm-branch-cleanup.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-branch-cleanup-tests)

commit_file() {
  local repo=$1 file=$2 content=$3 message=$4
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" add -- "$file"
  git -C "$repo" commit -qm "$message"
}

make_project() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git init -q "$dir/seed"
  git -C "$dir/seed" symbolic-ref HEAD refs/heads/main
  commit_file "$dir/seed" baseline.txt baseline baseline
  git clone -q --bare "$dir/seed" "$dir/origin.git"
  git clone -q --bare "$dir/seed" "$dir/no-mistakes.git"
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main
  git -C "$dir/project" remote add no-mistakes "$dir/no-mistakes.git"
  printf '%s\n' "$dir"
}

remote_branch_exists() {
  git --git-dir="$1" show-ref --verify --quiet "refs/heads/$2"
}

local_branch_exists() {
  git -C "$1" show-ref --verify --quiet "refs/heads/$2"
}

test_full_sweep_deletes_only_proven_inactive_branches() {
  local dir repo out active_wt
  dir=$(make_project full-sweep)
  repo="$dir/project"

  git -C "$repo" checkout -qb fm/landed
  commit_file "$repo" landed.txt landed landed
  git -C "$repo" push -q origin fm/landed
  git -C "$repo" push -q no-mistakes fm/landed
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --ff-only fm/landed
  git -C "$repo" push -q origin main

  git -C "$repo" checkout -qb fm/unlanded
  commit_file "$repo" unlanded.txt unlanded unlanded
  git -C "$repo" push -q origin fm/unlanded
  git -C "$repo" push -q no-mistakes fm/unlanded
  git -C "$repo" checkout -q main

  git -C "$repo" checkout -qb fm/active
  commit_file "$repo" active.txt active active
  git -C "$repo" push -q origin fm/active
  git -C "$repo" push -q no-mistakes fm/active
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --ff-only fm/active
  git -C "$repo" push -q origin main
  active_wt="$dir/active-wt"
  git -C "$repo" worktree add -q "$active_wt" fm/active

  out=$(PATH="$dir/fakebin:$PATH" "$CLEANUP" "$repo")

  assert_contains "$out" "pruned origin/fm/landed" "full sweep did not delete the landed GitHub branch"
  assert_contains "$out" "pruned no-mistakes/fm/landed" "full sweep did not delete the landed no-mistakes branch"
  local_branch_exists "$repo" fm/landed && fail "full sweep left the landed local branch"
  remote_branch_exists "$dir/origin.git" fm/landed && fail "full sweep left origin/fm/landed"
  remote_branch_exists "$dir/no-mistakes.git" fm/landed && fail "full sweep left no-mistakes/fm/landed"

  local_branch_exists "$repo" fm/unlanded || fail "full sweep deleted unlanded local work"
  remote_branch_exists "$dir/origin.git" fm/unlanded || fail "full sweep deleted unlanded origin work"
  remote_branch_exists "$dir/no-mistakes.git" fm/unlanded || fail "full sweep deleted unlanded no-mistakes work"
  local_branch_exists "$repo" fm/active || fail "full sweep deleted a checked-out local branch"
  remote_branch_exists "$dir/origin.git" fm/active || fail "full sweep deleted a checked-out origin branch"
  remote_branch_exists "$dir/no-mistakes.git" fm/active || fail "full sweep deleted a checked-out no-mistakes branch"
  pass "full sweep deletes landed refs from both real remotes and preserves unlanded or checked-out branches"
}

test_squash_landed_branch_uses_shared_github_proof() {
  local dir repo branch_tip squash_dir fakebin out
  dir=$(make_project squash-sweep)
  repo="$dir/project"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"

  git -C "$repo" checkout -qb fm/squash-landed
  commit_file "$repo" feature.txt hello feature
  branch_tip=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q origin fm/squash-landed
  git -C "$repo" push -q no-mistakes fm/squash-landed
  git -C "$repo" checkout -q main

  squash_dir="$dir/squash"
  git clone -q "$dir/origin.git" "$squash_dir"
  commit_file "$squash_dir" feature.txt hello squash
  git -C "$squash_dir" push -q origin main

  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' 'count: 1 (showing first 1)' 'pull_requests[1]{number,state}:' '  7,merged' ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view") printf '%s\t%s\n' MERGED '$branch_tip' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"

  out=$(PATH="$fakebin:$PATH" "$CLEANUP" "$repo")

  assert_contains "$out" "pruned origin/fm/squash-landed" "squash sweep did not delete the merged GitHub branch"
  assert_contains "$out" "pruned no-mistakes/fm/squash-landed" "squash sweep did not delete the no-mistakes branch"
  local_branch_exists "$repo" fm/squash-landed && fail "squash sweep left the local branch"
  remote_branch_exists "$dir/origin.git" fm/squash-landed && fail "squash sweep left the origin branch"
  remote_branch_exists "$dir/no-mistakes.git" fm/squash-landed && fail "squash sweep left the no-mistakes branch"
  pass "on-demand cleanup reuses the merged-PR proof for squash-landed tips across both remotes"
}

test_remote_advance_after_proof_is_preserved() {
  local dir repo fakebin old_tip new_tip real_git marker
  dir=$(make_project remote-race)
  repo="$dir/project"
  fakebin="$dir/fakebin"
  marker="$dir/race-injected"
  mkdir -p "$fakebin"

  git -C "$repo" checkout -qb fm/race
  commit_file "$repo" landed.txt landed landed
  old_tip=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q origin fm/race
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --ff-only fm/race
  git -C "$repo" push -q origin main

  git -C "$repo" checkout -qb race-replacement fm/race
  commit_file "$repo" later.txt unlanded "later remote work"
  new_tip=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q origin "$new_tip:refs/heads/race-replacement"
  git -C "$repo" checkout -q main
  git -C "$repo" branch -D race-replacement >/dev/null
  [ "$old_tip" != "$new_tip" ] || fail "remote-race: replacement tip did not advance"

  real_git=$(command -v git)
cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
is_delete=0
for arg in "$@"; do
  [ "$arg" != :refs/heads/fm/race ] || is_delete=1
done
if [ "$is_delete" -eq 1 ] && [ ! -e "$FM_RACE_MARKER" ]; then
  "$FM_REAL_GIT" --git-dir="$FM_RACE_ORIGIN" update-ref refs/heads/fm/race "$FM_RACE_NEW_TIP"
  : > "$FM_RACE_MARKER"
fi
exec "$FM_REAL_GIT" "$@"
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/git" "$fakebin/gh-axi" "$fakebin/gh"

  FM_REAL_GIT="$real_git" FM_RACE_MARKER="$marker" \
  FM_RACE_ORIGIN="$dir/origin.git" FM_RACE_NEW_TIP="$new_tip" \
  PATH="$fakebin:$PATH" "$CLEANUP" "$repo" >/dev/null

  assert_present "$marker" "remote-race: the test did not advance the remote at deletion time"
  [ "$(git --git-dir="$dir/origin.git" rev-parse refs/heads/fm/race)" = "$new_tip" ] \
    || fail "remote-race: cleanup deleted or rewound the concurrently advanced remote tip"
  pass "an exact-tip lease preserves a remote branch that advances after landedness proof"
}

test_pr_merge_delete_flag_drives_real_origin_deletion() {
  local dir repo fakebin state branch_tip
  dir=$(make_project merge-delete)
  repo="$dir/project"
  fakebin="$dir/fakebin"
  state="$dir/state"
  mkdir -p "$fakebin" "$state"

  git -C "$repo" checkout -qb fm/merge-delete
  commit_file "$repo" feature.txt delete-me feature
  branch_tip=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q origin fm/merge-delete
  fm_write_meta "$state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$repo" "project=$repo" "kind=ship" "mode=no-mistakes"

  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view") printf '%s\n' '$branch_tip' ;;
esac
SH
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/gh-axi.log'
case "\${1:-} \${2:-}" in
  "pr merge")
    case " \$* " in
      *' --delete-branch '*) git --git-dir='$dir/origin.git' update-ref -d refs/heads/fm/merge-delete ;;
      *) exit 1 ;;
    esac
    ;;
esac
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  assert_grep 'pr merge 7 --repo example/repo --squash --delete-branch' "$dir/gh-axi.log" \
    "fm-pr-merge did not send --delete-branch through the simulated GitHub adapter"
  remote_branch_exists "$dir/origin.git" fm/merge-delete \
    && fail "simulated GitHub merge left the real scratch origin branch"
  pass "fm-pr-merge's delete flag drives branch deletion against a real scratch origin"
}

test_full_sweep_deletes_only_proven_inactive_branches
test_squash_landed_branch_uses_shared_github_proof
test_remote_advance_after_proof_is_preserved
test_pr_merge_delete_flag_drives_real_origin_deletion
