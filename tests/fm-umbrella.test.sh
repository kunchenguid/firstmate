#!/usr/bin/env bash
# Tests for bin/fm-umbrella.sh: the captain-driven cross-repo design lab.
#
# These drive the real script against throwaway git clones and prove that
# create/teardown/list build isolated worktrees, keep umbrella metadata out of
# the task/watcher scan (umbrellas/ not state/), roll back cleanly on failure, keep
# DESIGN.md across teardown, and refuse unsafe input.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UMB="$ROOT/bin/fm-umbrella.sh"
TMP_ROOT=$(fm_test_tmproot fm-umbrella)

# make_home <name> <repo...> : build an isolated FM_HOME with the named repos as
# git clones under projects/<repo> (each with a bare origin). Echoes the home.
make_home() {
  local name=$1; shift
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/projects" "$home/state" "$home/umbrellas"
  home=$(cd "$home" && pwd -P)
  local r
  for r in "$@"; do
    fm_git_init_commit "$home/projects/$r"
    fm_git_add_origin "$home/projects/$r" "$home/projects/$r.origin.git"
  done
  printf '%s\n' "$home"
}

run_umb() {  # <home> <args...> -> sets OUT, RC
  local home=$1; shift
  OUT=$(FM_HOME="$home" "$UMB" "$@" 2>&1)
  RC=$?
}

test_create_builds_isolated_worktrees() {
  local home; home=$(make_home create backend frontend)
  run_umb "$home" create feat-x --repos backend,frontend
  expect_code 0 "$RC" "create feat-x"
  assert_contains "$OUT" "created umbrella feat-x" "create did not confirm"

  assert_present "$home/umbrellas/feat-x/repos/backend" "backend worktree missing"
  assert_present "$home/umbrellas/feat-x/repos/frontend" "frontend worktree missing"
  assert_present "$home/umbrellas/feat-x/DESIGN.md" "DESIGN.md missing"
  assert_present "$home/umbrellas/feat-x/AGENTS.md" "cross-repo AGENTS.md missing"
  assert_present "$home/umbrellas/feat-x/umbrella.meta" "umbrella.meta missing"

  # Each worktree is a real, isolated git worktree distinct from its clone.
  local top
  top=$(git -C "$home/umbrellas/feat-x/repos/backend" rev-parse --show-toplevel)
  [ "$top" = "$home/umbrellas/feat-x/repos/backend" ] \
    || fail "backend worktree root is not itself: $top"
  [ "$top" != "$home/projects/backend" ] || fail "backend worktree tangled the clone"

  # Metadata stays OUT of state/ so no task/watcher scan ever sees it.
  assert_absent "$home/state/feat-x.meta" "umbrella leaked a state/<id>.meta"
  assert_grep "kind=umbrella" "$home/umbrellas/feat-x/umbrella.meta" "meta missing kind"
  assert_grep "repos=backend,frontend" "$home/umbrellas/feat-x/umbrella.meta" "meta missing repos"

  pass "create builds isolated worktrees with metadata under umbrellas/"
}

test_worktree_bases_on_fresh_default() {
  local home; home=$(make_home fresh backend)
  # Advance origin after the clone so a fresh base is observable.
  local up="$TMP_ROOT/fresh/upstream"
  git clone --quiet "$home/projects/backend.origin.git" "$up"
  printf 'more\n' >> "$up/README.md"
  git -C "$up" -c user.name=t -c user.email=t@t.invalid commit -qam advance
  git -C "$up" push --quiet origin HEAD >/dev/null 2>&1
  local newtip; newtip=$(git -C "$up" rev-parse HEAD)

  run_umb "$home" create f --repos backend
  expect_code 0 "$RC" "create with advanced origin"
  local wt_head; wt_head=$(git -C "$home/umbrellas/f/repos/backend" rev-parse HEAD)
  [ "$wt_head" = "$newtip" ] \
    || fail "worktree did not base on the fetched origin tip ($wt_head vs $newtip)"
  pass "worktree bases on the fetched default-branch tip"
}

test_teardown_keeps_design_removes_worktrees() {
  local home; home=$(make_home tear backend frontend)
  run_umb "$home" create f --repos backend,frontend
  expect_code 0 "$RC" "create for teardown"

  run_umb "$home" teardown f
  expect_code 0 "$RC" "teardown f"
  assert_contains "$OUT" "tore down umbrella f" "teardown did not confirm"
  assert_absent "$home/umbrellas/f/repos" "repos/ survived teardown"
  assert_absent "$home/umbrellas/f/umbrella.meta" "meta survived teardown"
  assert_present "$home/umbrellas/f/DESIGN.md" "DESIGN.md was not kept"
  # The clone's worktree list no longer references the lab.
  assert_no_grep "umbrellas/f/repos/backend" <(git -C "$home/projects/backend" worktree list) \
    "clone still lists the removed worktree"
  pass "teardown removes worktrees but keeps DESIGN.md"
}

test_teardown_discards_dirty_scratch_visibly() {
  local home; home=$(make_home dirty backend)
  run_umb "$home" create f --repos backend
  expect_code 0 "$RC" "create for dirty teardown"
  printf 'scratch\n' > "$home/umbrellas/f/repos/backend/scratch.txt"

  run_umb "$home" teardown f
  expect_code 0 "$RC" "teardown with dirty scratch"
  assert_contains "$OUT" "discarding scratch changes in backend" \
    "teardown discarded dirty scratch silently"
  assert_absent "$home/umbrellas/f/repos" "dirty worktree not removed"
  pass "teardown discards dirty scratch but prints what it discards"
}

test_empty_design_gate() {
  local home; home=$(make_home gate backend)
  run_umb "$home" create f --repos backend
  expect_code 0 "$RC" "create for gate"
  : > "$home/umbrellas/f/DESIGN.md"   # empty it

  run_umb "$home" teardown f
  expect_code 1 "$RC" "teardown should refuse an empty DESIGN.md"
  assert_contains "$OUT" "DESIGN.md is missing or empty" "gate message wrong"
  assert_present "$home/umbrellas/f/repos/backend" "refused teardown still removed the worktree"

  run_umb "$home" teardown f --force
  expect_code 0 "$RC" "--force should bypass the gate"
  assert_absent "$home/umbrellas/f/repos" "--force teardown left worktrees"
  pass "empty DESIGN.md gates teardown unless --force"
}

test_rollback_on_bad_repo() {
  local home; home=$(make_home rb backend)
  run_umb "$home" create f --repos backend,nope
  expect_code 1 "$RC" "create should fail on unknown repo"
  assert_contains "$OUT" "not a git clone" "did not name the missing repo"
  assert_absent "$home/umbrellas/f" "failed create left the umbrella dir behind"
  # The good repo's worktree list must be clean (rollback removed it).
  assert_no_grep "umbrellas/f/repos/backend" <(git -C "$home/projects/backend" worktree list) \
    "rollback left a dangling worktree"
  pass "a bad repo rolls back every created worktree and the dir"
}

test_refuses_duplicate_id() {
  local home; home=$(make_home dup backend)
  run_umb "$home" create f --repos backend
  expect_code 0 "$RC" "first create"
  run_umb "$home" create f --repos backend
  expect_code 1 "$RC" "duplicate id should refuse"
  assert_contains "$OUT" "id already in use" "duplicate message wrong"
  pass "a duplicate umbrella id is refused"
}

test_rejects_unsafe_input() {
  local home; home=$(make_home unsafe backend)
  run_umb "$home" create ../escape --repos backend
  expect_code 2 "$RC" "path-traversal id should be rejected"
  assert_contains "$OUT" "invalid umbrella id" "unsafe id message wrong"

  run_umb "$home" create ok --repos "../../etc"
  expect_code 2 "$RC" "path-traversal repo name should be rejected"
  assert_contains "$OUT" "invalid repo name" "unsafe repo message wrong"
  pass "path-unsafe ids and repo names are rejected"
}

test_list() {
  local home; home=$(make_home list backend frontend)
  run_umb "$home" list
  expect_code 0 "$RC" "list on empty home"
  assert_contains "$OUT" "no umbrellas" "empty list wrong"
  run_umb "$home" create f --repos backend,frontend
  run_umb "$home" list
  expect_code 0 "$RC" "list with one umbrella"
  assert_contains "$OUT" "f  repos=backend,frontend" "list did not show the umbrella"
  pass "list reports umbrellas and their repos"
}

# scaffold_epic <home> <umbrella-id> <epic-dir> : make a bare epic dir under the
# umbrella's plans/ (epic.md + stories/), the shape epic-scaffold produces.
scaffold_epic() {
  local home=$1 id=$2 epic=$3
  local dir="$home/umbrellas/$id/plans/$epic"
  mkdir -p "$dir/stories"
  printf -- '---\nepic: %s\n---\n# epic\n' "$epic" > "$dir/epic.md"
}

test_link_design_symlinks_canonical_no_copy() {
  # The epic dir must reference the ONE umbrella-root DESIGN.md by symlink, and an
  # edit to the canonical must show through the link (proving it is not a copy).
  local home; home=$(make_home linkdesign backend)
  run_umb "$home" create u --repos backend
  expect_code 0 "$RC" "create u"
  scaffold_epic "$home" u ep
  run_umb "$home" link-design u ep
  expect_code 0 "$RC" "link-design"
  local link="$home/umbrellas/u/plans/ep/DESIGN.md"
  local canon="$home/umbrellas/u/DESIGN.md"
  [ -L "$link" ] || fail "epic-dir DESIGN.md is not a symlink"
  # realpath dedup: link and canonical are the SAME file.
  [ "$link" -ef "$canon" ] || fail "epic-dir DESIGN.md does not dedup to the canonical"
  printf '\nEDIT-MARKER-42\n' >> "$canon"
  assert_grep "EDIT-MARKER-42" "$link" "edit to canonical did not show through the link (it is a copy, not a reference)"
  pass "link-design references the one canonical DESIGN.md by symlink, never a copy"
}

test_link_design_idempotent() {
  local home; home=$(make_home linkidem backend)
  run_umb "$home" create u --repos backend
  scaffold_epic "$home" u ep
  run_umb "$home" link-design u ep
  expect_code 0 "$RC" "first link-design"
  run_umb "$home" link-design u ep
  expect_code 0 "$RC" "second link-design is a clean no-op"
  [ -L "$home/umbrellas/u/plans/ep/DESIGN.md" ] || fail "re-run did not leave a symlink"
  pass "link-design is idempotent"
}

test_link_design_refuses_real_copy() {
  # A real (non-symlink) DESIGN.md in the epic dir is exactly the drift R4 is
  # about: refuse rather than silently discard possibly-unique captain content.
  local home; home=$(make_home linkcopy backend)
  run_umb "$home" create u --repos backend
  scaffold_epic "$home" u ep
  printf 'a stale hand-copied design\n' > "$home/umbrellas/u/plans/ep/DESIGN.md"
  run_umb "$home" link-design u ep
  expect_code 1 "$RC" "link-design should refuse a real design copy"
  assert_contains "$OUT" "real file, not a symlink" "wrong refusal message"
  # The copy is left untouched for the captain to reconcile.
  assert_grep "a stale hand-copied design" "$home/umbrellas/u/plans/ep/DESIGN.md" "refused run must not touch the copy"
  pass "link-design refuses a drifting real copy and keeps captain content"
}

test_link_design_links_decisions_when_present() {
  local home; home=$(make_home linkdecis backend)
  run_umb "$home" create u --repos backend
  printf '# decisions\n' > "$home/umbrellas/u/decisions.md"
  scaffold_epic "$home" u ep
  run_umb "$home" link-design u ep
  expect_code 0 "$RC" "link-design with decisions.md"
  [ "$home/umbrellas/u/plans/ep/decisions.md" -ef "$home/umbrellas/u/decisions.md" ] \
    || fail "decisions.md was not linked to the canonical"
  pass "link-design also symlinks decisions.md when the umbrella carries one"
}

test_link_design_missing_epic_dir() {
  local home; home=$(make_home linkmissing backend)
  run_umb "$home" create u --repos backend
  run_umb "$home" link-design u nope
  expect_code 1 "$RC" "link-design should fail when the epic dir is absent"
  assert_contains "$OUT" "no epic dir" "wrong missing-epic message"
  pass "link-design fails clearly when the epic dir is absent"
}

test_create_builds_isolated_worktrees
test_worktree_bases_on_fresh_default
test_teardown_keeps_design_removes_worktrees
test_teardown_discards_dirty_scratch_visibly
test_empty_design_gate
test_rollback_on_bad_repo
test_refuses_duplicate_id
test_rejects_unsafe_input
test_list
test_link_design_symlinks_canonical_no_copy
test_link_design_idempotent
test_link_design_refuses_real_copy
test_link_design_links_decisions_when_present
test_link_design_missing_epic_dir

echo "# all fm-umbrella tests passed"
