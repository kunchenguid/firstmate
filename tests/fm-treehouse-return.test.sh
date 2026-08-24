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
  'worktree show') printf '{"ok":true,"result":{"worktree":{"id":"wt-1","path":"%s"}}}\n' "${FM_ORCA_WT_PATH:?}" ;;
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
  [ "$rc" -ne 0 ] || fail "Orca teardown ignored an unrescuable commit: $out"
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

run_child_orca_teardown() {  # <case-dir> <child-worktree>
  local case_dir=$1 childwt=$2
  FM_HOME="$case_dir/home" \
  FM_TREEHOUSE_RETURN_MARKER="$case_dir/treehouse-return-called" \
  FM_ORCA_WT_PATH="$childwt" \
  FM_ORCA_RM_MARKER="$case_dir/child-orca-worktree-removed" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" domain --force 2>&1
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

test_broken_ref_store_still_rescues_detached_commit
test_non_repository_path_passes_through_without_borrowing_an_enclosing_repo
test_ambient_git_dir_cannot_turn_a_non_repository_path_into_a_worktree
test_guard_refusal_preserves_child_worktree_commits
test_unrescuable_commit_reports_the_concrete_git_reason
test_durable_branch_returns_even_with_an_unusable_task_id
test_unusable_task_id_refuses_unrescuable_committed_work
test_orca_detached_commit_is_rescued_before_worktree_removal
test_orca_guard_refusal_preserves_the_worktree
test_child_orca_detached_commit_is_rescued_before_removal
test_child_orca_guard_refusal_preserves_the_worktree

if [ -z "$TREEHOUSE" ]; then
  printf '%s\n' 'skip: treehouse not found'
  exit 0
fi

test_detached_head_commit_is_rescued_before_real_return
test_attached_branch_returns_without_rescue_ref
test_unreadable_reachability_refuses_before_treehouse_return
