#!/usr/bin/env bash
# Regression tests for preserving committed work through an isolated Treehouse return.
#
# Each case creates a private scratch pool via TREEHOUSE_ROOT. It never inspects or
# returns a worktree from the operator's live pool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fm-treehouse-return fm-treehouse-return@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-return)
TREEHOUSE=$(command -v treehouse 2>/dev/null || true)

[ -n "$TREEHOUSE" ] || {
  printf '%s\n' 'skip: treehouse not found'
  exit 0
}

make_case() {  # <name>
  local name=$1 case_dir repo pool home fakebin
  case_dir="$TMP_ROOT/$name"
  repo="$case_dir/repo"
  pool="$case_dir/pool"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m baseline
  (
    cd "$repo" || exit 1
    "$TREEHOUSE" init --root "$pool" >/dev/null
  ) || return 1
  fm_fake_exit0 "$fakebin" tmux no-mistakes gh gh-axi
  printf '%s\n' "$case_dir"
}

lease_worktree() {  # <case-dir> <holder>
  local case_dir=$1 holder=$2
  (
    cd "$case_dir/repo" || exit 1
    TREEHOUSE_ROOT="$case_dir/pool" "$TREEHOUSE" get --lease --lease-holder "$holder"
  )
}

write_teardown_meta() {  # <case-dir> <task-id> <worktree>
  local case_dir=$1 task_id=$2 worktree=$3
  fm_write_meta "$case_dir/home/state/$task_id.meta" \
    "window=firstmate:fm-$task_id" \
    "endpoint_task_id=$task_id" \
    "worktree=$worktree" \
    "project=$case_dir/repo" \
    'kind=ship' \
    'mode=local-only'
}

run_teardown() {  # <case-dir> <task-id>
  local case_dir=$1 task_id=$2
  FM_HOME="$case_dir/home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  TREEHOUSE_ROOT="$case_dir/pool" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$task_id" --force
}

test_detached_head_commit_is_rescued_before_real_return() {
  local case_dir wt head out rescue_refs branch remote_head
  case_dir=$(make_case detached-head)
  wt=$(lease_worktree "$case_dir" detached-return) || fail "could not lease isolated detached-head worktree"
  branch=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)
  [ -z "$branch" ] || fail "scratch pool worktree unexpectedly started attached to $branch"
  git -C "$wt" commit -q --allow-empty -m detached-work
  head=$(git -C "$wt" rev-parse HEAD)
  git -C "$case_dir/repo" update-ref refs/remotes/origin/detached-only "$head"
  remote_head=$(git -C "$case_dir/repo" rev-parse refs/remotes/origin/detached-only)
  [ "$remote_head" = "$head" ] || fail "could not stage the detached commit under only a remote-tracking ref"
  write_teardown_meta "$case_dir" detached-return "$wt"

  out=$(run_teardown "$case_dir" detached-return) \
    || fail "detached committed work teardown failed: $out"
  rescue_refs=$(git -C "$case_dir/repo" for-each-ref --contains="$head" --format='%(refname)' \
    refs/firstmate/rescue/detached-return)
  [ -n "$rescue_refs" ] || fail "detached committed work had no rescue ref after real Treehouse return"
  assert_contains "$out" 'RESCUED: committed work' \
    "detached return did not report its rescue"
  pass "Treehouse return rescues a detached-head commit despite a remote-tracking ref"
}

test_attached_branch_returns_without_rescue_ref() {
  local case_dir wt head out rescue_refs durable_head
  case_dir=$(make_case attached-branch)
  wt=$(lease_worktree "$case_dir" branch-return) || fail "could not lease isolated attached-branch worktree"
  git -C "$wt" checkout -q -b fm/treehouse-return-branch
  git -C "$wt" commit -q --allow-empty -m branch-work
  head=$(git -C "$wt" rev-parse HEAD)
  write_teardown_meta "$case_dir" branch-return "$wt"

  out=$(run_teardown "$case_dir" branch-return) \
    || fail "branch committed work teardown failed: $out"
  durable_head=$(git -C "$case_dir/repo" rev-parse refs/heads/fm/treehouse-return-branch)
  [ "$durable_head" = "$head" ] || fail "branch commit did not survive real Treehouse return"
  rescue_refs=$(git -C "$case_dir/repo" for-each-ref --format='%(refname)' \
    refs/firstmate/rescue/branch-return)
  [ -z "$rescue_refs" ] || fail "safe branch return created unnecessary rescue refs: $rescue_refs"
  assert_not_contains "$out" 'RESCUED: committed work' \
    "safe branch return reported an unnecessary rescue"
  pass "Treehouse return preserves an attached branch without rescue-ref litter"
}

test_unreadable_reachability_refuses_before_treehouse_return() {
  local case_dir unreadable marker out rc
  case_dir="$TMP_ROOT/unreadable"
  unreadable="$case_dir/unreadable-worktree"
  marker="$case_dir/treehouse-return-called"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin" "$case_dir/repo" "$case_dir/pool" "$unreadable"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  : > "${FM_TREEHOUSE_RETURN_MARKER:?}"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  write_teardown_meta "$case_dir" unreadable-return "$unreadable"

  set +e
  out=$(FM_TREEHOUSE_RETURN_MARKER="$marker" run_teardown "$case_dir" unreadable-return 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unreadable worktree unexpectedly returned"
  [ ! -e "$marker" ] || fail "unreadable reachability check allowed Treehouse return"
  assert_contains "$out" 'REFUSED: cannot determine committed-work reachability' \
    "unreadable return did not report its concrete refusal"
  assert_present "$case_dir/home/state/unreadable-return.meta" \
    "unreadable return removed task metadata after refusal"
  pass "unreadable committed-work reachability refuses before Treehouse return"
}

test_detached_head_commit_is_rescued_before_real_return
test_attached_branch_returns_without_rescue_ref
test_unreadable_reachability_refuses_before_treehouse_return
