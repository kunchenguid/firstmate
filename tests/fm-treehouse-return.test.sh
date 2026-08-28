#!/usr/bin/env bash
# Regression tests for preserving committed work through an isolated Treehouse return.
#
# Each case creates a private scratch pool pinned in its own repo's treehouse.toml.
# It never inspects or returns a worktree from the operator's live pool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fm-treehouse-return fm-treehouse-return@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-return)
TREEHOUSE=$(command -v treehouse 2>/dev/null || true)

# shellcheck source=bin/fm-treehouse-return-lib.sh
. "$ROOT/bin/fm-treehouse-return-lib.sh"

# Expected-failure captures below must not leak errexit into the rest of the
# suite: this file runs without `set -e`, so a bare `set -e` after a capture
# would silently arm errexit for every later case and abort the run at the first
# unguarded nonzero command. These save and restore whatever mode was in effect.
FM_ERREXIT_PREV=off
errexit_off() {
  case $- in
    *e*) FM_ERREXIT_PREV=on ;;
    *) FM_ERREXIT_PREV=off ;;
  esac
  set +e
}
errexit_restore() {
  if [ "$FM_ERREXIT_PREV" = on ]; then set -e; else set +e; fi
}

fake_treehouse_bin() {  # <fakebin-dir>
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  : > "${FM_TREEHOUSE_RETURN_MARKER:?}"
fi
exit 0
SH
  chmod +x "$1/treehouse"
}

make_case() {  # <name>
  local name=$1 case_dir repo pool home fakebin
  case_dir="$TMP_ROOT/$name"
  repo="$case_dir/repo"
  pool="$case_dir/pool"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin" "$case_dir/fakehome"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m baseline
  # Pin the pool in the repo's own treehouse.toml rather than through `init
  # --root` or TREEHOUSE_ROOT: the repo-level config is the one pool selector
  # every supported Treehouse build honors, so this case stays isolated on the
  # CI-pinned binary too instead of falling back to the operator's real pool.
  printf 'max_trees = 4\nroot = "%s"\n' "$pool" > "$repo/treehouse.toml" || return 1
  fm_fake_exit0 "$fakebin" tmux no-mistakes gh gh-axi
  printf '%s\n' "$case_dir"
}

lease_worktree() {  # <case-dir> <holder>
  local case_dir=$1 holder=$2
  (
    cd "$case_dir/repo" || exit 1
    HOME="$case_dir/fakehome" TREEHOUSE_ROOT="$case_dir/pool" \
      "$TREEHOUSE" get --lease --lease-holder "$holder"
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
  mkdir -p "$case_dir/fakehome" || return 1
  HOME="$case_dir/fakehome" \
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
  local case_dir unreadable marker out rc repo
  case_dir="$TMP_ROOT/unreadable"
  unreadable="$case_dir/unreadable-worktree"
  repo="$case_dir/repo"
  marker="$case_dir/treehouse-return-called"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin" "$case_dir/pool"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  fake_treehouse_bin "$case_dir/fakebin"
  fm_git_worktree "$repo" "$unreadable" fm/unreadable-return
  # Keep the .git entry so this remains a Git worktree subject, but make its
  # linked-worktree admin pointer unreadable. The guard must refuse rather than
  # treating this as the harmless ordinary-directory pass-through case.
  printf 'gitdir: %s\n' "$case_dir/missing-worktree-admin" > "$unreadable/.git"
  write_teardown_meta "$case_dir" unreadable-return "$unreadable"

  errexit_off
  out=$(FM_TREEHOUSE_RETURN_MARKER="$marker" run_teardown "$case_dir" unreadable-return 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] || fail "unreadable worktree unexpectedly returned"
  [ ! -e "$marker" ] || fail "unreadable reachability check allowed Treehouse return"
  assert_contains "$out" 'REFUSED: cannot determine committed-work reachability' \
    "unreadable return did not report its concrete refusal"
  assert_present "$case_dir/home/state/unreadable-return.meta" \
    "unreadable return removed task metadata after refusal"
  pass "unreadable committed-work reachability refuses before Treehouse return"
}

# --- guard-level regressions (no live Treehouse binary required) -------------

make_guard_case() {  # <name>
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  fake_treehouse_bin "$case_dir/fakebin"
  printf '%s\n' "$case_dir"
}

fake_orca_bin() {  # <fakebin-dir>
  cat > "$1/orca" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'status '*) printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  'worktree show')
    if [ -n "${FM_ORCA_SHOW_UNRESOLVABLE:-}" ]; then
      printf '{"ok":true,"result":{"worktree":{"id":"wt-1"}}}\n'
      exit 0
    fi
    printf '{"ok":true,"result":{"worktree":{"id":"wt-1","path":"%s"}}}\n' "${FM_ORCA_WT_PATH:?}"
    ;;
  'worktree rm')
    : > "${FM_ORCA_RM_MARKER:?}"
    rm -rf "${FM_ORCA_WT_PATH:?}"
    printf '{"ok":true,"result":{}}\n'
    ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
exit 0
SH
  chmod +x "$1/orca"
}

# An Orca task record: Orca owns the worktree and deletes it at teardown instead
# of returning it to a Treehouse pool.
write_orca_meta() {  # <case-dir> <task-id> <worktree> <project>
  local case_dir=$1 task_id=$2 worktree=$3 project=$4
  fm_write_meta "$case_dir/home/state/$task_id.meta" \
    "window=fm-$task_id" \
    "endpoint_task_id=$task_id" \
    'terminal=term-7' \
    "worktree=$worktree" \
    "project=$project" \
    'backend=orca' \
    'orca_worktree_id=wt-1' \
    'kind=ship' \
    'mode=local-only'
}

run_orca_teardown() {  # <case-dir> <task-id> <worktree>
  local case_dir=$1 task_id=$2 worktree=$3
  FM_HOME="$case_dir/home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_ORCA_WT_PATH="$worktree" \
  FM_ORCA_RM_MARKER="$case_dir/orca-worktree-removed" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$task_id" --force
}

test_orca_detached_commit_is_rescued_before_worktree_removal() {
  local case_dir proj wt head out rescue_refs
  case_dir=$(make_guard_case orca-detached)
  fake_orca_bin "$case_dir/fakebin"
  proj="$case_dir/project"
  wt="$case_dir/orca-worktree"
  fm_git_worktree "$proj" "$wt" fm/orca-branch
  git -C "$wt" checkout -q --detach
  git -C "$wt" commit -q --allow-empty -m unnamed-orca-work
  head=$(git -C "$wt" rev-parse HEAD)
  write_orca_meta "$case_dir" orca-detached "$wt" "$proj"

  out=$(run_orca_teardown "$case_dir" orca-detached "$wt" 2>&1) \
    || fail "Orca teardown over a detached committed worktree failed: $out"
  assert_present "$case_dir/orca-worktree-removed" "Orca teardown never removed its worktree"
  rescue_refs=$(git -C "$proj" for-each-ref --contains="$head" --format='%(refname)' \
    refs/firstmate/rescue/orca-detached)
  [ -n "$rescue_refs" ] || fail "Orca worktree deletion dropped an unreferenced commit: $out"
  assert_contains "$out" 'RESCUED: committed work' \
    "Orca deletion did not report its rescue"
  pass "Orca worktree deletion rescues an unreferenced detached-head commit first"
}

test_orca_guard_refusal_preserves_the_worktree() {
  local case_dir proj wt head out rc
  case_dir=$(make_guard_case orca-refusal)
  fake_orca_bin "$case_dir/fakebin"
  proj="$case_dir/project"
  wt="$case_dir/orca-worktree"
  fm_git_worktree "$proj" "$wt" fm/orca-branch
  git -C "$wt" checkout -q --detach
  git -C "$wt" commit -q --allow-empty -m unnamed-orca-work
  head=$(git -C "$wt" rev-parse HEAD)
  # A file at refs/firstmate/rescue/<id> blocks the <id>/<timestamp> ref below
  # it, so this commit can be neither certified nor rescued. It points at the
  # baseline, so it never makes HEAD durable by itself.
  mkdir -p "$proj/.git/refs/firstmate/rescue"
  git -C "$proj" rev-parse refs/heads/fm/orca-branch \
    > "$proj/.git/refs/firstmate/rescue/orca-refusal"
  write_orca_meta "$case_dir" orca-refusal "$wt" "$proj"

  errexit_off
  out=$(run_orca_teardown "$case_dir" orca-refusal "$wt" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -eq 5 ] \
    || fail "an Orca committed-work guard refusal did not keep its reserved status (got $rc): $out"
  [ ! -e "$case_dir/orca-worktree-removed" ] \
    || fail "guard refusal still let Orca delete the worktree: $out"
  [ -d "$wt" ] || fail "guard refusal deleted the Orca worktree holding unreferenced commits: $out"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] \
    || fail "preserved Orca worktree no longer holds its unreferenced commit"
  assert_contains "$out" "$wt" "Orca guard refusal did not name the preserved worktree"
  assert_contains "$out" 'REFUSED: cannot create rescue ref' \
    "Orca guard refusal did not report why the committed work could not be rescued"
  pass "an Orca committed-work guard refusal preserves the worktree instead of deleting it"
}

test_unborn_head_passes_through_without_refusing() {
  local case_dir wt out rc
  case_dir="$TMP_ROOT/unborn-head"
  wt="$case_dir/worktree"
  mkdir -p "$case_dir"
  # `git init` with nothing committed: HEAD names no commit at all, so there is
  # no committed work to certify and nothing a removal could lose.
  git init -q "$wt"

  errexit_off
  out=$(fm_treehouse_return_guard unborn-head "$wt" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -eq 0 ] || fail "an unborn HEAD refused a return that can lose nothing: $out"
  [ -z "$out" ] || fail "an unborn HEAD reported a rescue or refusal it never needed: $out"
  pass "an unborn HEAD passes through instead of refusing forever"
}

test_deleted_branch_ref_is_not_mistaken_for_an_unborn_head() {
  local case_dir repo wt head out rc
  case_dir="$TMP_ROOT/deleted-branch-ref"
  repo="$case_dir/repo"
  wt="$case_dir/worktree"
  mkdir -p "$case_dir"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m baseline
  git -C "$repo" worktree add -q "$wt" -b fm/deleted-branch
  git -C "$wt" commit -q --allow-empty -m committed-work
  head=$(git -C "$wt" rev-parse HEAD)
  # An out-of-band ref deletion git does not block the way it blocks `branch -D`
  # on a checked-out branch. HEAD still points at the missing ref, so it looks
  # exactly like an unborn HEAD - but the commit is real and the worktree is now
  # the only thing naming it.
  git -C "$repo" update-ref -d refs/heads/fm/deleted-branch
  [ "$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}' || true)" != "$head" ] \
    || fail "fixture did not reproduce a HEAD that no longer resolves"

  errexit_off
  out=$(fm_treehouse_return_guard deleted-branch-ref "$wt" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] \
    || fail "a branch ref deleted out of band was treated as an unborn HEAD: $out"
  assert_contains "$out" 'REFUSED: cannot determine committed-work reachability' \
    "a deleted branch ref did not refuse with a concrete reason"
  pass "a branch ref deleted while checked out refuses instead of passing as unborn"
}

test_unreadable_branch_ref_is_not_mistaken_for_an_unborn_head() {
  local case_dir wt head out rc
  case_dir="$TMP_ROOT/unborn-vs-damaged"
  wt="$case_dir/worktree"
  mkdir -p "$case_dir"
  git init -q "$wt"
  git -C "$wt" commit -q --allow-empty -m committed-work
  head=$(git -C "$wt" rev-parse HEAD)
  # The branch HEAD points at still exists in the ref store, but its contents
  # can no longer be read. That is a damaged worktree, not an unborn one, so it
  # must keep failing closed even though HEAD no longer resolves.
  git -C "$wt" pack-refs --all
  rm -f "$wt/.git/packed-refs"
  mkdir -p "$wt/.git/refs/heads"
  printf 'not-a-sha\n' > "$wt/.git/refs/heads/$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo main)"

  errexit_off
  out=$(fm_treehouse_return_guard unborn-vs-damaged "$wt" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] \
    || fail "a damaged branch ref was treated as an unborn HEAD and passed through: $out"
  assert_contains "$out" 'REFUSED: cannot determine committed-work reachability' \
    "a damaged branch ref did not refuse with a concrete reason"
  [ -n "$head" ] || fail "fixture never produced a commit to protect"
  pass "an unreadable branch ref still refuses instead of passing as unborn"
}

test_disabled_reflog_cannot_prove_an_unborn_head() {
  local case_dir repo wt head out rc
  case_dir="$TMP_ROOT/disabled-reflog"
  repo="$case_dir/repo"
  wt="$case_dir/worktree"
  mkdir -p "$case_dir"
  git init -q "$repo"
  # With reflogs off, a worktree that does hold commits leaves the same empty
  # HEAD reflog an unborn one does, so emptiness alone proves nothing here.
  git -C "$repo" config core.logAllRefUpdates false
  git -C "$repo" commit -q --allow-empty -m baseline
  git -C "$repo" worktree add -q "$wt" -b fm/no-reflog
  git -C "$wt" commit -q --allow-empty -m committed-work
  head=$(git -C "$wt" rev-parse HEAD)
  git -C "$repo" update-ref -d refs/heads/fm/no-reflog
  [ "$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}' || true)" != "$head" ] \
    || fail "fixture did not reproduce a HEAD that no longer resolves"

  errexit_off
  out=$(fm_treehouse_return_guard disabled-reflog "$wt" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] \
    || fail "an empty reflog from a disabled reflog config passed as an unborn HEAD: $out"
  assert_contains "$out" 'REFUSED: cannot determine committed-work reachability' \
    "a disabled reflog config did not refuse with a concrete reason"
  pass "an empty reflog cannot prove an unborn HEAD when reflogs are disabled"
}

test_pooled_teardown_drops_a_redundant_task_branch() {
  local case_dir repo wt marker out rescue_refs
  case_dir="$TMP_ROOT/pooled-branch-drop"
  repo="$case_dir/repo"
  wt="$case_dir/pool-worktree"
  marker="$case_dir/treehouse-return-called"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin" "$case_dir/pool"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  fake_treehouse_bin "$case_dir/fakebin"
  # No commits of its own, so the project's own branch already contains this
  # HEAD and the task branch names nothing that could be lost with it.
  fm_git_worktree "$repo" "$wt" fm/pooled-droppable
  write_teardown_meta "$case_dir" pooled-droppable "$wt"

  out=$(FM_TREEHOUSE_RETURN_MARKER="$marker" run_teardown "$case_dir" pooled-droppable 2>&1) \
    || fail "pooled teardown over contained branch work failed: $out"
  assert_present "$marker" "pooled teardown never returned the worktree"
  git -C "$repo" rev-parse --verify --quiet refs/heads/fm/pooled-droppable >/dev/null \
    && fail "pooled teardown left a redundant task branch in the shared repo: $out"
  rescue_refs=$(git -C "$repo" for-each-ref --format='%(refname)' refs/firstmate/rescue)
  [ -z "$rescue_refs" ] \
    || fail "pooled teardown minted a rescue ref while dropping a redundant branch: $rescue_refs"
  pass "pooled teardown drops a task branch whose commits another ref already holds"
}

test_pooled_teardown_keeps_a_task_branch_that_is_the_only_durable_ref() {
  local case_dir repo wt head marker out rescue_refs
  case_dir="$TMP_ROOT/pooled-branch-keep"
  repo="$case_dir/repo"
  wt="$case_dir/pool-worktree"
  marker="$case_dir/treehouse-return-called"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin" "$case_dir/pool"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  fake_treehouse_bin "$case_dir/fakebin"
  fm_git_worktree "$repo" "$wt" fm/pooled-only-ref
  # Committed on the task branch and never merged locally: that branch is the
  # one durable local ref naming this work, so the return must not drop it.
  git -C "$wt" commit -q --allow-empty -m branch-pool-work
  head=$(git -C "$wt" rev-parse HEAD)
  write_teardown_meta "$case_dir" pooled-only-ref "$wt"

  out=$(FM_TREEHOUSE_RETURN_MARKER="$marker" run_teardown "$case_dir" pooled-only-ref 2>&1) \
    || fail "pooled teardown over branch work failed: $out"
  assert_present "$marker" "pooled teardown never returned the worktree"
  [ "$(git -C "$repo" rev-parse --verify --quiet refs/heads/fm/pooled-only-ref)" = "$head" ] \
    || fail "pooled teardown dropped the only durable ref naming its committed work: $out"
  rescue_refs=$(git -C "$repo" for-each-ref --format='%(refname)' refs/firstmate/rescue)
  [ -z "$rescue_refs" ] \
    || fail "pooled teardown minted a rescue ref for already-durable branch work: $rescue_refs"
  pass "pooled teardown keeps a task branch that is the only durable ref"
}

test_pooled_guard_refusal_keeps_hooks_and_reserved_status() {
  local case_dir repo wt head marker out rc
  case_dir="$TMP_ROOT/pooled-guard-refusal"
  repo="$case_dir/repo"
  wt="$case_dir/pool-worktree"
  marker="$case_dir/treehouse-return-called"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" \
    "$case_dir/fakebin" "$case_dir/pool"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  fake_treehouse_bin "$case_dir/fakebin"
  fm_git_worktree "$repo" "$wt" fm/pooled-refusal
  git -C "$wt" checkout -q --detach
  git -C "$wt" commit -q --allow-empty -m unnamed-pool-work
  head=$(git -C "$wt" rev-parse HEAD)
  mkdir -p "$wt/.claude"
  printf '{}\n' > "$wt/.claude/settings.local.json"
  # A file at refs/firstmate/rescue/<id> blocks the <id>/<timestamp> ref below
  # it, so this detached commit can be neither certified nor rescued.
  mkdir -p "$repo/.git/refs/firstmate/rescue"
  git -C "$repo" rev-parse refs/heads/fm/pooled-refusal \
    > "$repo/.git/refs/firstmate/rescue/pooled-refusal"
  write_teardown_meta "$case_dir" pooled-refusal "$wt"

  errexit_off
  out=$(FM_TREEHOUSE_RETURN_MARKER="$marker" run_teardown "$case_dir" pooled-refusal 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -eq 5 ] \
    || fail "a pooled committed-work guard refusal did not keep its reserved status (got $rc): $out"
  [ ! -e "$marker" ] || fail "the guard refusal still handed the worktree to treehouse: $out"
  [ -d "$wt" ] || fail "the guard refusal deleted the pooled worktree: $out"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] \
    || fail "the preserved pooled worktree no longer holds its unreferenced commit"
  assert_present "$wt/.claude/settings.local.json" \
    "the guard refusal stripped the preserved worktree's harness hook file"
  assert_present "$case_dir/home/state/pooled-refusal.meta" \
    "the guard refusal removed the pooled task record"
  assert_contains "$out" 'REFUSED: cannot create rescue ref' \
    "the pooled guard refusal did not report why the committed work could not be rescued"
  assert_not_contains "$out" 'error: treehouse return failed' \
    "the pooled guard refusal was mislabeled as a treehouse return failure"
  pass "a pooled guard refusal preserves the worktree's hooks and keeps its reserved status"
}

test_broken_ref_store_still_rescues_detached_commit() {
  local case_dir repo wt head marker out rescue_refs
  case_dir=$(make_guard_case broken-ref-store)
  repo="$case_dir/repo"
  wt="$case_dir/worktree"
  marker="$case_dir/treehouse-return-called"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m baseline
  git -C "$repo" worktree add -q --detach "$wt" HEAD
  git -C "$wt" commit -q --allow-empty -m detached-work
  head=$(git -C "$wt" rev-parse HEAD)
  # A truncated loose ref left by a killed process: `git for-each-ref` still
  # exits 0 but prints a diagnostic while matching nothing.
  printf 'not-a-sha\n' > "$repo/.git/refs/heads/broken"
  write_teardown_meta "$case_dir" broken-refs-return "$wt"

  out=$(FM_TREEHOUSE_RETURN_MARKER="$marker" run_teardown "$case_dir" broken-refs-return 2>&1) \
    || fail "teardown over a damaged ref store failed: $out"
  rescue_refs=$(git -C "$repo" for-each-ref --contains="$head" --format='%(refname)' \
    refs/firstmate/rescue/broken-refs-return)
  [ -n "$rescue_refs" ] || fail "damaged ref store made the durability check fail open: $out"
  assert_contains "$out" 'RESCUED: committed work' \
    "damaged ref store return did not report its rescue"
  assert_present "$marker" "rescued return never reached Treehouse"
  pass "a damaged ref store does not fake durability for detached committed work"
}

test_non_repository_path_passes_through_without_borrowing_an_enclosing_repo() {
  local case_dir outer ordinary marker out
  case_dir=$(make_guard_case nested-repo)
  outer="$case_dir/outer"
  ordinary="$outer/pool/ordinary-directory"
  marker="$case_dir/treehouse-return-called"
  mkdir -p "$ordinary" "$case_dir/repo"
  git init -q "$outer"
  git -C "$outer" commit -q --allow-empty -m enclosing
  write_teardown_meta "$case_dir" nested-return "$ordinary"

  out=$(FM_TREEHOUSE_RETURN_MARKER="$marker" run_teardown "$case_dir" nested-return 2>&1) \
    || fail "ordinary non-repository directory did not pass through teardown: $out"
  assert_present "$marker" "non-repository directory did not reach the return path"
  assert_not_contains "$out" 'REFUSED: cannot determine committed-work reachability' \
    "ordinary directory was mistaken for the enclosing repository's worktree"
  pass "a non-repository directory passes through without borrowing an enclosing repository"
}

test_guard_refusal_preserves_child_worktree_commits() {
  local case_dir home subhome childproj childwt head out rc
  case_dir="$TMP_ROOT/child-guard-refusal"
  home="$case_dir/home"
  subhome="$case_dir/subhome"
  childproj="$subhome/projects/alpha"
  childwt="$case_dir/child-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$case_dir/fakebin"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  fake_treehouse_bin "$case_dir/fakebin"

  fm_git_worktree "$childproj" "$childwt" fm/child-branch
  git -C "$childwt" checkout -q --detach
  git -C "$childwt" commit -q --allow-empty -m unnamed-child-work
  head=$(git -C "$childwt" rev-parse HEAD)
  mkdir -p "$childwt/.claude"
  printf '{}\n' > "$childwt/.claude/settings.local.json"
  # A file at refs/firstmate/rescue/<child-id> blocks the <id>/<timestamp> ref
  # below it, so this detached commit can be neither certified nor rescued. It
  # points at the baseline, so it never makes HEAD durable by itself.
  mkdir -p "$childproj/.git/refs/firstmate/rescue"
  git -C "$childproj" rev-parse refs/heads/fm/child-branch \
    > "$childproj/.git/refs/firstmate/rescue/child"

  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_secondmate_meta "$home/state/domain.meta" "$subhome"
  printf '%s\n' \
    "- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/child.meta" \
    'window=firstmate:fm-child' \
    'endpoint_task_id=child' \
    "worktree=$childwt" \
    "project=$childproj" \
    'harness=echo' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off'

  errexit_off
  out=$(FM_HOME="$home" FM_TREEHOUSE_RETURN_MARKER="$case_dir/treehouse-return-called" \
    PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" domain --force 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] || fail "forced teardown ignored an unrescuable child commit: $out"
  [ -d "$childwt" ] || fail "guard refusal deleted the child worktree holding unreferenced commits: $out"
  [ "$(git -C "$childwt" rev-parse HEAD)" = "$head" ] \
    || fail "child worktree no longer holds its unreferenced commit"
  assert_present "$childwt/.claude/settings.local.json" \
    "guard refusal stripped the preserved child worktree's harness hook file"
  assert_contains "$out" "$childwt" \
    "guard refusal did not name the preserved child worktree"
  assert_contains "$out" 'REFUSED: cannot create rescue ref' \
    "guard refusal did not report why the committed work could not be rescued"
  pass "a committed-work guard refusal preserves the child worktree and its commits"
}

# Build a forced-secondmate teardown case whose only child is an Orca ship task
# holding a detached-HEAD commit. Orca deletes that child worktree rather than
# returning it to a pool, so the committed-work guard is the only thing standing
# between the commit and a force-removal.
make_child_orca_case() {  # <name>
  local name=$1 case_dir home subhome childproj childwt
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  subhome="$case_dir/subhome"
  # The child project repo lives outside the secondmate home: teardown removes
  # the home itself, so a rescue ref only proves durability in a repository that
  # outlives it.
  childproj="$case_dir/projects/alpha"
  childwt="$case_dir/child-orca-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$case_dir/fakebin"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  fake_treehouse_bin "$case_dir/fakebin"
  fake_orca_bin "$case_dir/fakebin"

  fm_git_worktree "$childproj" "$childwt" fm/child-orca-branch
  git -C "$childwt" checkout -q --detach
  git -C "$childwt" commit -q --allow-empty -m unnamed-child-orca-work

  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_secondmate_meta "$home/state/domain.meta" "$subhome"
  printf '%s\n' \
    "- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)" \
    > "$home/data/secondmates.md"
  write_orca_meta "$case_dir" child-orca "$childwt" "$childproj"
  mv "$case_dir/home/state/child-orca.meta" "$subhome/state/child-orca.meta"
  printf '%s\n' "$case_dir"
}

# <orca-worktree-path> is what the fake Orca CLI reports for the recorded
# worktree id, so a case can record one path and have Orca resolve another.
run_child_orca_teardown() {  # <case-dir> <orca-worktree-path>
  local case_dir=$1 orca_wt=$2
  FM_HOME="$case_dir/home" \
  FM_TREEHOUSE_RETURN_MARKER="$case_dir/treehouse-return-called" \
  FM_ORCA_WT_PATH="$orca_wt" \
  FM_ORCA_RM_MARKER="$case_dir/child-orca-worktree-removed" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" domain --force 2>&1
}

test_child_orca_stale_record_still_guards_the_removed_worktree() {
  local case_dir childproj live head out rescue_refs
  case_dir=$(make_child_orca_case child-orca-stale-record)
  childproj="$case_dir/projects/alpha"
  live="$case_dir/live-orca-worktree"
  # The recorded path is stale - renamed or re-provisioned - while the recorded
  # id still resolves to a live worktree holding an uncommitted-to-any-ref
  # commit. That worktree is what Orca actually removes.
  git -C "$childproj" worktree add -q --detach "$live" HEAD
  git -C "$live" commit -q --allow-empty -m unnamed-live-orca-work
  head=$(git -C "$live" rev-parse HEAD)
  fm_write_meta "$case_dir/subhome/state/child-orca.meta" \
    'window=fm-child-orca' \
    'endpoint_task_id=child-orca' \
    'terminal=term-7' \
    "worktree=$case_dir/renamed-away-orca-worktree" \
    "project=$childproj" \
    'backend=orca' \
    'orca_worktree_id=wt-1' \
    'kind=ship' \
    'mode=local-only'

  out=$(run_child_orca_teardown "$case_dir" "$live") \
    || fail "forced secondmate teardown over a stale child Orca record failed: $out"
  assert_present "$case_dir/child-orca-worktree-removed" \
    "forced secondmate teardown never removed the worktree the recorded id resolves to"
  rescue_refs=$(git -C "$childproj" for-each-ref --contains="$head" --format='%(refname)' \
    refs/firstmate/rescue/child-orca)
  [ -n "$rescue_refs" ] \
    || fail "a stale child Orca record let Orca delete an unreferenced commit: $out"
  assert_contains "$out" 'RESCUED: committed work' \
    "the id-resolved child Orca removal did not report its rescue"
  pass "a stale child Orca record still guards the worktree its id resolves to"
}

test_child_orca_unresolvable_id_refuses_instead_of_removing() {
  local case_dir childproj live head out rc
  case_dir=$(make_child_orca_case child-orca-unresolvable)
  childproj="$case_dir/projects/alpha"
  live="$case_dir/live-orca-worktree"
  # The record's path is stale and Orca answers `worktree show` without a path,
  # so the worktree its id would remove cannot be inspected at all - while
  # `worktree rm` on that same id still succeeds.
  git -C "$childproj" worktree add -q --detach "$live" HEAD
  git -C "$live" commit -q --allow-empty -m unnamed-live-orca-work
  head=$(git -C "$live" rev-parse HEAD)
  fm_write_meta "$case_dir/subhome/state/child-orca.meta" \
    'window=fm-child-orca' \
    'endpoint_task_id=child-orca' \
    'terminal=term-7' \
    "worktree=$case_dir/renamed-away-orca-worktree" \
    "project=$childproj" \
    'backend=orca' \
    'orca_worktree_id=wt-1' \
    'kind=ship' \
    'mode=local-only'

  errexit_off
  out=$(FM_ORCA_SHOW_UNRESOLVABLE=1 run_child_orca_teardown "$case_dir" "$live")
  rc=$?
  errexit_restore
  [ "$rc" -eq 5 ] \
    || fail "an unresolvable child Orca id did not refuse with the reserved status (got $rc): $out"
  [ ! -e "$case_dir/child-orca-worktree-removed" ] \
    || fail "an unresolvable child Orca id still asked Orca to remove a worktree: $out"
  [ -d "$live" ] \
    || fail "an unresolvable child Orca id deleted an uncertified worktree: $out"
  [ "$(git -C "$live" rev-parse HEAD)" = "$head" ] \
    || fail "the preserved Orca worktree no longer holds its unreferenced commit"
  assert_present "$case_dir/subhome/state/child-orca.meta" \
    "an unresolvable child Orca id removed the child task record"
  assert_contains "$out" 'REFUSED: cannot resolve Orca worktree id' \
    "an unresolvable child Orca id did not report why removal could not be certified"
  assert_contains "$out" 'clear orca_worktree_id=' \
    "an unresolvable child Orca id did not name a recovery step for an already-removed worktree"
  pass "an unresolvable child Orca worktree id refuses instead of removing uncertified work"
}

test_child_orca_id_path_mismatch_refuses_removal() {
  local case_dir childproj childwt other other_head child_head out rc rescue_refs
  case_dir=$(make_child_orca_case child-orca-mismatch)
  childproj="$case_dir/projects/alpha"
  childwt="$case_dir/child-orca-worktree"
  other="$case_dir/other-orca-worktree"
  child_head=$(git -C "$childwt" rev-parse HEAD)
  # The recorded id now resolves to a different worktree than the child record
  # names - an id reuse or re-provision. Its detached commit is exactly the work
  # a removal by id would destroy without ever being certified.
  git -C "$childproj" worktree add -q --detach "$other" HEAD
  git -C "$other" commit -q --allow-empty -m unnamed-other-orca-work
  other_head=$(git -C "$other" rev-parse HEAD)

  errexit_off
  out=$(run_child_orca_teardown "$case_dir" "$other")
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] || fail "forced teardown removed an Orca worktree the guard never certified: $out"
  [ ! -e "$case_dir/child-orca-worktree-removed" ] \
    || fail "forced teardown asked Orca to remove a mismatched worktree: $out"
  [ -d "$other" ] \
    || fail "the worktree the recorded id resolves to was deleted uncertified: $out"
  [ "$(git -C "$other" rev-parse HEAD)" = "$other_head" ] \
    || fail "the mismatched Orca worktree no longer holds its unreferenced commit"
  [ -d "$childwt" ] || fail "an id/path mismatch deleted the recorded child worktree: $out"
  [ "$(git -C "$childwt" rev-parse HEAD)" = "$child_head" ] \
    || fail "the recorded child worktree no longer holds its unreferenced commit"
  rescue_refs=$(git -C "$childproj" for-each-ref --format='%(refname)' refs/firstmate/rescue)
  [ -z "$rescue_refs" ] \
    || fail "an id/path mismatch rescued and then abandoned a worktree: $rescue_refs"
  assert_present "$case_dir/subhome/state/child-orca.meta" \
    "an id/path mismatch removed the child Orca task record"
  assert_contains "$out" 'REFUSED: Orca worktree id' \
    "an id/path mismatch did not report which worktree the recorded id resolves to"
  pass "a child Orca id that resolves to another worktree refuses instead of removing it"
}

# A secondmate home that occupies a Treehouse slot of the firstmate repo, so its
# teardown goes through the pooled home return rather than a plain removal.
test_secondmate_home_return_reports_a_guard_refusal_as_one() {
  local case_dir fmroot home subhome head out rc
  case_dir="$TMP_ROOT/home-return-guard-refusal"
  fmroot="$case_dir/fmroot"
  home="$case_dir/home"
  subhome="$case_dir/subhome"
  mkdir -p "$home/state" "$home/data" "$case_dir/fakebin"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi
  fake_treehouse_bin "$case_dir/fakebin"

  git init -q "$fmroot"
  mkdir -p "$fmroot/bin"
  fm_fake_exit0 "$fmroot/bin" fm-guard.sh
  git -C "$fmroot" commit -q --allow-empty -m baseline
  git -C "$fmroot" worktree add -q --detach "$subhome" HEAD
  git -C "$subhome" commit -q --allow-empty -m unnamed-home-work
  head=$(git -C "$subhome" rev-parse HEAD)
  # A file at refs/firstmate/rescue/<id> blocks the <id>/<timestamp> ref below
  # it, so this detached commit can be neither certified nor rescued.
  mkdir -p "$fmroot/.git/refs/firstmate/rescue"
  git -C "$fmroot" rev-parse HEAD > "$fmroot/.git/refs/firstmate/rescue/domain"
  mkdir -p "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_secondmate_meta "$home/state/domain.meta" "$subhome"
  printf '%s\n' \
    "- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)" \
    > "$home/data/secondmates.md"

  errexit_off
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$fmroot" \
    FM_TREEHOUSE_RETURN_MARKER="$case_dir/treehouse-return-called" \
    PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" domain --force 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] || fail "secondmate home return ignored an unrescuable commit: $out"
  [ "$rc" -eq 5 ] \
    || fail "a home committed-work guard refusal did not keep its reserved status (got $rc): $out"
  [ ! -e "$case_dir/treehouse-return-called" ] \
    || fail "the guard refusal still handed the home to treehouse: $out"
  [ -d "$subhome" ] || fail "the guard refusal deleted the secondmate home: $out"
  [ "$(git -C "$subhome" rev-parse HEAD)" = "$head" ] \
    || fail "the preserved secondmate home no longer holds its unreferenced commit"
  assert_present "$home/state/domain.meta" "the guard refusal removed the secondmate task record"
  assert_contains "$out" 'REFUSED: cannot create rescue ref' \
    "the home guard refusal did not report why the committed work could not be rescued"
  assert_contains "$out" 'REFUSED: committed work in secondmate home' \
    "the home guard refusal was not reported as one"
  assert_not_contains "$out" 'error: treehouse return failed' \
    "the home guard refusal was mislabeled as a treehouse return failure"
  pass "a secondmate home guard refusal reports itself and keeps its reserved status"
}

test_child_orca_detached_commit_is_rescued_before_removal() {
  local case_dir childproj childwt head out rescue_refs
  case_dir=$(make_child_orca_case child-orca-rescue)
  childproj="$case_dir/projects/alpha"
  childwt="$case_dir/child-orca-worktree"
  head=$(git -C "$childwt" rev-parse HEAD)

  out=$(run_child_orca_teardown "$case_dir" "$childwt") \
    || fail "forced secondmate teardown over a detached child Orca commit failed: $out"
  assert_present "$case_dir/child-orca-worktree-removed" \
    "forced secondmate teardown never removed its child Orca worktree"
  rescue_refs=$(git -C "$childproj" for-each-ref --contains="$head" --format='%(refname)' \
    refs/firstmate/rescue/child-orca)
  [ -n "$rescue_refs" ] || fail "child Orca removal dropped an unreferenced commit: $out"
  assert_contains "$out" 'RESCUED: committed work' \
    "child Orca removal did not report its rescue"
  pass "forced child Orca removal rescues an unreferenced detached-head commit first"
}

test_child_orca_guard_refusal_preserves_the_worktree() {
  local case_dir childproj childwt head out rc
  case_dir=$(make_child_orca_case child-orca-refusal)
  childproj="$case_dir/projects/alpha"
  childwt="$case_dir/child-orca-worktree"
  head=$(git -C "$childwt" rev-parse HEAD)
  # A file at refs/firstmate/rescue/<child-id> blocks the <id>/<timestamp> ref
  # below it, so this detached commit can be neither certified nor rescued. It
  # points at the baseline, so it never makes HEAD durable by itself.
  mkdir -p "$childproj/.git/refs/firstmate/rescue"
  git -C "$childproj" rev-parse refs/heads/fm/child-orca-branch \
    > "$childproj/.git/refs/firstmate/rescue/child-orca"

  errexit_off
  out=$(run_child_orca_teardown "$case_dir" "$childwt")
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] || fail "forced teardown ignored an unrescuable child Orca commit: $out"
  [ ! -e "$case_dir/child-orca-worktree-removed" ] \
    || fail "guard refusal still let Orca delete the child worktree: $out"
  [ -d "$childwt" ] || fail "guard refusal deleted the child Orca worktree holding unreferenced commits: $out"
  [ "$(git -C "$childwt" rev-parse HEAD)" = "$head" ] \
    || fail "preserved child Orca worktree no longer holds its unreferenced commit"
  assert_present "$case_dir/subhome/state/child-orca.meta" \
    "guard refusal removed the child Orca task record"
  assert_contains "$out" "$childwt" "child Orca guard refusal did not name the preserved worktree"
  assert_contains "$out" 'REFUSED: cannot create rescue ref' \
    "child Orca guard refusal did not report why the committed work could not be rescued"
  pass "a child Orca committed-work guard refusal preserves the worktree instead of deleting it"
}

test_ambient_git_dir_cannot_turn_a_non_repository_path_into_a_worktree() {
  local case_dir other target out rc
  case_dir="$TMP_ROOT/ambient-git-dir"
  other="$case_dir/other-repo"
  target="$case_dir/no-git-here"
  mkdir -p "$target"
  git init -q "$other"
  git -C "$other" commit -q --allow-empty -m durable-elsewhere

  errexit_off
  out=$(GIT_DIR="$other/.git" GIT_WORK_TREE="$other" \
    fm_treehouse_return_guard ambient-return "$target" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -eq 0 ] || fail "an ambient GIT_DIR turned an ordinary directory into a worktree: $out"
  assert_not_contains "$out" 'RESCUED: committed work' \
    "ambient GIT_DIR made the guard inspect an unrelated repository"
  pass "an inherited GIT_DIR cannot turn an ordinary directory into a worktree"
}

test_unrescuable_commit_reports_the_concrete_git_reason() {
  local case_dir repo wt out rc
  case_dir="$TMP_ROOT/rescue-ref-blocked"
  repo="$case_dir/repo"
  wt="$case_dir/worktree"
  mkdir -p "$case_dir"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m baseline
  git -C "$repo" worktree add -q --detach "$wt" HEAD
  git -C "$wt" commit -q --allow-empty -m detached-work
  # A file at refs/firstmate/rescue/<id> blocks the <id>/<timestamp> ref below it,
  # so update-ref fails for a reason only its stderr carries. It points at the
  # baseline so it never makes the detached HEAD durable by itself.
  mkdir -p "$repo/.git/refs/firstmate/rescue"
  git -C "$repo" rev-parse HEAD > "$repo/.git/refs/firstmate/rescue/blocked-return"

  errexit_off
  out=$(fm_treehouse_return_guard blocked-return "$wt" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] || fail "guard accepted a worktree whose rescue ref could not be created"
  assert_contains "$out" 'REFUSED: cannot create rescue ref' \
    "blocked rescue ref did not refuse"
  assert_contains "$out" "exists; cannot create" \
    "blocked rescue ref discarded the concrete git reason"
  pass "an unrescuable commit refuses with the concrete git reason"
}

test_durable_branch_returns_even_with_an_unusable_task_id() {
  local case_dir repo wt out rc rescue_refs
  case_dir="$TMP_ROOT/unusable-task-id"
  repo="$case_dir/repo"
  wt="$case_dir/worktree"
  mkdir -p "$case_dir"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m baseline
  git -C "$repo" worktree add -q "$wt" -b fm/durable-branch HEAD
  git -C "$wt" commit -q --allow-empty -m branch-work

  errexit_off
  out=$(fm_treehouse_return_guard '' "$wt" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -eq 0 ] || fail "durable branch work was blocked by an unusable task id: $out"
  assert_not_contains "$out" 'REFUSED' "durable branch return refused over the task id"
  rescue_refs=$(git -C "$repo" for-each-ref --format='%(refname)' refs/firstmate/rescue)
  [ -z "$rescue_refs" ] || fail "durable branch return created rescue refs: $rescue_refs"
  pass "durable branch work returns even when the task id cannot name a rescue ref"
}

test_unusable_task_id_refuses_unrescuable_committed_work() {
  local case_dir repo wt out rc
  case_dir="$TMP_ROOT/unusable-task-id-detached"
  repo="$case_dir/repo"
  wt="$case_dir/worktree"
  mkdir -p "$case_dir"
  git init -q "$repo"
  git -C "$repo" commit -q --allow-empty -m baseline
  git -C "$repo" worktree add -q --detach "$wt" HEAD
  git -C "$wt" commit -q --allow-empty -m detached-work

  errexit_off
  out=$(fm_treehouse_return_guard '' "$wt" 2>&1)
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] || fail "unnamed committed work returned under an unusable task id"
  assert_contains "$out" 'REFUSED: cannot rescue committed work' \
    "unusable task id did not refuse unnamed committed work"
  pass "an unusable task id still refuses to return unnamed committed work"
}

# A PATH that cannot resolve `treehouse`, so a case can exercise the
# no-Treehouse host fallback on a machine that does have Treehouse installed.
# Directories are dropped whole, so any tool sharing a directory with Treehouse
# (Homebrew ships git beside it) is re-provided from its pre-filter location in
# a case-local bin dir; the result is verified to still run git and to no longer
# find treehouse, so a case can never fail for a PATH reason it does not name.
make_no_treehouse_path() {  # <case-dir>
  local case_dir=$1 toolbin dir tool resolved out='' built saved_ifs=$IFS
  toolbin="$case_dir/toolbin"
  mkdir -p "$toolbin" || return 1
  for tool in git bash env sh; do
    resolved=$(command -v "$tool" 2>/dev/null) || continue
    case "$resolved" in
      /*) ln -sf "$resolved" "$toolbin/$tool" || return 1 ;;
    esac
  done
  IFS=:
  for dir in $PATH; do
    IFS=$saved_ifs
    if [ -n "$dir" ] && [ ! -x "$dir/treehouse" ]; then
      out="${out:+$out:}$dir"
    fi
    IFS=:
  done
  IFS=$saved_ifs
  built="$case_dir/fakebin:$toolbin${out:+:$out}"
  ( PATH=$built; command -v treehouse >/dev/null 2>&1 ) && return 1
  ( PATH=$built; command -v git >/dev/null 2>&1 ) || return 1
  printf '%s\n' "$built"
}

# A forced-secondmate teardown whose non-Orca child worktree cannot be returned
# to a pool because the host has no Treehouse: that path deletes the worktree
# outright, so it is a destructive removal the committed-work guard must cover.
make_no_treehouse_child_case() {  # <name>
  local name=$1 case_dir home subhome childproj childwt
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  subhome="$case_dir/subhome"
  # Outside the secondmate home: teardown removes the home itself, so a rescue
  # ref only proves durability in a repository that outlives it.
  childproj="$case_dir/projects/alpha"
  childwt="$case_dir/child-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$case_dir/fakebin"
  fm_fake_exit0 "$case_dir/fakebin" tmux no-mistakes gh gh-axi

  fm_git_worktree "$childproj" "$childwt" fm/child-branch
  git -C "$childwt" checkout -q --detach
  git -C "$childwt" commit -q --allow-empty -m unnamed-child-work
  mkdir -p "$childwt/.claude"
  printf '{}\n' > "$childwt/.claude/settings.local.json"

  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_write_secondmate_meta "$home/state/domain.meta" "$subhome"
  printf '%s\n' \
    "- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/child.meta" \
    'window=firstmate:fm-child' \
    'endpoint_task_id=child' \
    "worktree=$childwt" \
    "project=$childproj" \
    'harness=echo' \
    'kind=ship' \
    'mode=no-mistakes' \
    'yolo=off'
  printf '%s\n' "$case_dir"
}

run_no_treehouse_teardown() {  # <case-dir> <path>
  local case_dir=$1 sandbox_path=$2
  FM_HOME="$case_dir/home" \
  PATH="$sandbox_path" \
    "$TEARDOWN" domain --force 2>&1
}

test_child_worktree_without_treehouse_rescues_committed_work() {
  local case_dir childproj childwt head out rescue_refs sandbox_path
  case_dir=$(make_no_treehouse_child_case no-treehouse-child-rescue)
  childproj="$case_dir/projects/alpha"
  childwt="$case_dir/child-worktree"
  head=$(git -C "$childwt" rev-parse HEAD)
  sandbox_path=$(make_no_treehouse_path "$case_dir") \
    || fail "could not build a git-capable PATH that cannot resolve treehouse"

  errexit_off
  out=$(run_no_treehouse_teardown "$case_dir" "$sandbox_path")
  errexit_restore
  [ ! -d "$childwt" ] \
    || fail "the no-Treehouse fallback never deleted the child worktree: $out"
  rescue_refs=$(git -C "$childproj" for-each-ref --contains="$head" --format='%(refname)' \
    refs/firstmate/rescue/child)
  [ -n "$rescue_refs" ] \
    || fail "child worktree deletion without Treehouse dropped an unreferenced commit: $out"
  assert_contains "$out" 'RESCUED: committed work' \
    "child worktree deletion without Treehouse did not report its rescue"
  pass "deleting a child worktree without Treehouse rescues its unreferenced commit first"
}

test_child_worktree_without_treehouse_refuses_unrescuable_work() {
  local case_dir childproj childwt head out rc sandbox_path
  case_dir=$(make_no_treehouse_child_case no-treehouse-child-refusal)
  childproj="$case_dir/projects/alpha"
  childwt="$case_dir/child-worktree"
  head=$(git -C "$childwt" rev-parse HEAD)
  # A file at refs/firstmate/rescue/<child-id> blocks the <id>/<timestamp> ref
  # below it, so this detached commit can be neither certified nor rescued. It
  # points at the baseline, so it never makes HEAD durable by itself.
  mkdir -p "$childproj/.git/refs/firstmate/rescue"
  git -C "$childproj" rev-parse refs/heads/fm/child-branch \
    > "$childproj/.git/refs/firstmate/rescue/child"
  sandbox_path=$(make_no_treehouse_path "$case_dir") \
    || fail "could not build a git-capable PATH that cannot resolve treehouse"

  errexit_off
  out=$(run_no_treehouse_teardown "$case_dir" "$sandbox_path")
  rc=$?
  errexit_restore
  [ "$rc" -ne 0 ] || fail "forced teardown ignored an unrescuable child commit: $out"
  [ -d "$childwt" ] \
    || fail "the no-Treehouse fallback deleted a child worktree holding unreferenced commits: $out"
  [ "$(git -C "$childwt" rev-parse HEAD)" = "$head" ] \
    || fail "preserved child worktree no longer holds its unreferenced commit"
  assert_present "$childwt/.claude/settings.local.json" \
    "guard refusal stripped the preserved child worktree's harness hook file"
  assert_present "$case_dir/subhome/state/child.meta" \
    "guard refusal removed the child task record"
  assert_contains "$out" 'REFUSED: cannot create rescue ref' \
    "guard refusal did not report why the committed work could not be rescued"
  pass "a child worktree deletion without Treehouse refuses unrescuable committed work"
}

test_orca_branch_work_is_kept_without_rescue_litter() {
  local case_dir proj wt head out rescue_refs
  case_dir=$(make_guard_case orca-attached)
  fake_orca_bin "$case_dir/fakebin"
  proj="$case_dir/project"
  wt="$case_dir/orca-worktree"
  fm_git_worktree "$proj" "$wt" fm/orca-branch
  # Committed on the task branch and never merged locally: the branch is the one
  # durable local ref naming this work.
  git -C "$wt" commit -q --allow-empty -m branch-orca-work
  head=$(git -C "$wt" rev-parse HEAD)
  write_orca_meta "$case_dir" orca-attached "$wt" "$proj"

  out=$(run_orca_teardown "$case_dir" orca-attached "$wt" 2>&1) \
    || fail "Orca teardown over branch work failed: $out"
  assert_present "$case_dir/orca-worktree-removed" "Orca teardown never removed its worktree"
  rescue_refs=$(git -C "$proj" for-each-ref --contains="$head" --format='%(refname)' \
    refs/firstmate/rescue)
  [ -z "$rescue_refs" ] \
    || fail "Orca teardown minted a rescue ref for already-durable branch work: $rescue_refs"
  [ "$(git -C "$proj" rev-parse --verify --quiet refs/heads/fm/orca-branch)" = "$head" ] \
    || fail "Orca teardown dropped the only durable ref naming its committed work: $out"
  pass "Orca teardown keeps branch-named work durable with no rescue litter"
}

test_orca_drops_a_task_branch_whose_work_is_already_contained() {
  local case_dir proj wt out
  case_dir=$(make_guard_case orca-contained)
  fake_orca_bin "$case_dir/fakebin"
  proj="$case_dir/project"
  wt="$case_dir/orca-worktree"
  # No commits of its own, so the project's own branch already contains this
  # HEAD and the task branch names nothing that would otherwise be lost.
  fm_git_worktree "$proj" "$wt" fm/orca-branch
  write_orca_meta "$case_dir" orca-contained "$wt" "$proj"

  out=$(run_orca_teardown "$case_dir" orca-contained "$wt" 2>&1) \
    || fail "Orca teardown over contained branch work failed: $out"
  assert_present "$case_dir/orca-worktree-removed" "Orca teardown never removed its worktree"
  git -C "$proj" rev-parse --verify --quiet refs/heads/fm/orca-branch >/dev/null \
    && fail "Orca teardown kept a redundant task branch: $out"
  pass "Orca teardown still drops a task branch whose commits another ref already holds"
}

test_broken_ref_store_still_rescues_detached_commit
test_unborn_head_passes_through_without_refusing
test_unreadable_branch_ref_is_not_mistaken_for_an_unborn_head
test_deleted_branch_ref_is_not_mistaken_for_an_unborn_head
test_pooled_guard_refusal_keeps_hooks_and_reserved_status
test_disabled_reflog_cannot_prove_an_unborn_head
test_pooled_teardown_drops_a_redundant_task_branch
test_pooled_teardown_keeps_a_task_branch_that_is_the_only_durable_ref
test_non_repository_path_passes_through_without_borrowing_an_enclosing_repo
test_ambient_git_dir_cannot_turn_a_non_repository_path_into_a_worktree
test_guard_refusal_preserves_child_worktree_commits
test_unrescuable_commit_reports_the_concrete_git_reason
test_durable_branch_returns_even_with_an_unusable_task_id
test_unusable_task_id_refuses_unrescuable_committed_work
test_orca_detached_commit_is_rescued_before_worktree_removal
test_orca_guard_refusal_preserves_the_worktree
test_orca_branch_work_is_kept_without_rescue_litter
test_orca_drops_a_task_branch_whose_work_is_already_contained
test_child_orca_detached_commit_is_rescued_before_removal
test_child_orca_guard_refusal_preserves_the_worktree
test_child_orca_id_path_mismatch_refuses_removal
test_child_orca_unresolvable_id_refuses_instead_of_removing
test_child_orca_stale_record_still_guards_the_removed_worktree
test_secondmate_home_return_reports_a_guard_refusal_as_one
test_child_worktree_without_treehouse_rescues_committed_work
test_child_worktree_without_treehouse_refuses_unrescuable_work

if [ -z "$TREEHOUSE" ]; then
  printf '%s\n' 'skip: treehouse not found'
  exit 0
fi

test_detached_head_commit_is_rescued_before_real_return
test_attached_branch_returns_without_rescue_ref
test_unreadable_reachability_refuses_before_treehouse_return
