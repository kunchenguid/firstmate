#!/usr/bin/env bash
# tests/fm-treehouse-pool-lib.test.sh - proves fm_treehouse_configure_pool_root
# (bin/fm-treehouse-pool-lib.sh) actually gives two clones of one origin their
# own treehouse worktree pools without dirtying either home, using the real
# treehouse binary end to end (harness-dependent check: the pool-collision
# behavior this fixes is treehouse's own, so a mocked path computation would
# only confirm the assumption already written into the mock). Skips when
# treehouse is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-treehouse-pool-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-lib) || fail "could not create temp root"
# Keep the derived pool roots inside the fixture instead of the developer's
# machine state directory. The fixture root is not a git repository, so a
# pool root here proves the pool can live outside every repository.
export XDG_STATE_HOME="$TMP_ROOT/state"

# A realistic firstmate home: a real git repository that ignores its project
# clones, exactly as a seeded secondmate home does, so a pool root that dirties
# the home surfaces in its own `git status`.
make_home() {
  local home=$1
  fm_git_init_commit "$home"
  printf 'projects/\n' > "$home/.gitignore"
  git -C "$home" add .gitignore
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm gitignore
}

# One throwaway origin, cloned twice - standing in for a project two separate
# firstmate homes have each cloned.
fm_git_init_commit "$TMP_ROOT/widget-origin"
fm_git_add_origin "$TMP_ROOT/widget-origin" "$TMP_ROOT/widget-origin.git"
make_home "$TMP_ROOT/home-a"
make_home "$TMP_ROOT/home-b"
git clone --quiet "$TMP_ROOT/widget-origin.git" "$TMP_ROOT/home-a/projects/widget" || fail "could not clone home A's widget"
git clone --quiet "$TMP_ROOT/widget-origin.git" "$TMP_ROOT/home-b/projects/widget" || fail "could not clone home B's widget"

WT_A=; WT_B=
cleanup_leases() {
  [ -z "$WT_A" ] || treehouse return --force "$WT_A" >/dev/null 2>&1
  [ -z "$WT_B" ] || treehouse return --force "$WT_B" >/dev/null 2>&1
  fm_test_cleanup
}
trap cleanup_leases EXIT

fm_treehouse_configure_pool_root "$TMP_ROOT/home-a/projects/widget" "$TMP_ROOT/home-a" \
  || fail "fm_treehouse_configure_pool_root refused for home A"
fm_treehouse_configure_pool_root "$TMP_ROOT/home-b/projects/widget" "$TMP_ROOT/home-b" \
  || fail "fm_treehouse_configure_pool_root refused for home B"
pass "fm_treehouse_configure_pool_root accepts two fresh clones of one origin"

[ -z "$(git -C "$TMP_ROOT/home-a/projects/widget" status --porcelain)" ] \
  || fail "home A's clone reads as dirty after configuring its pool root"
[ -z "$(git -C "$TMP_ROOT/home-b/projects/widget" status --porcelain)" ] \
  || fail "home B's clone reads as dirty after configuring its pool root"
pass "the generated treehouse.toml is excluded locally, so both clones stay clean"

# A project that tracks its own treehouse.toml keeps its own pool
# configuration; the seed must warn instead of aborting, and the file must be
# left untouched.
fm_git_init_commit "$TMP_ROOT/owned-origin"
printf 'root = "/srv/owned"\n' > "$TMP_ROOT/owned-origin/treehouse.toml"
git -C "$TMP_ROOT/owned-origin" add treehouse.toml
git -C "$TMP_ROOT/owned-origin" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm owned
fm_git_add_origin "$TMP_ROOT/owned-origin" "$TMP_ROOT/owned-origin.git"
git clone --quiet "$TMP_ROOT/owned-origin.git" "$TMP_ROOT/home-a/projects/owned" || fail "could not clone home A's owned project"
warning=$(fm_treehouse_configure_pool_root "$TMP_ROOT/home-a/projects/owned" "$TMP_ROOT/home-a" 2>&1) \
  || fail "fm_treehouse_configure_pool_root aborted the seed on a project-owned treehouse.toml"
[ "$(cat "$TMP_ROOT/home-a/projects/owned/treehouse.toml")" = 'root = "/srv/owned"' ] \
  || fail "fm_treehouse_configure_pool_root overwrote a project-owned treehouse.toml"
case "$warning" in
  *owned*"refused until reconciled"*) : ;;
  *) fail "fm_treehouse_configure_pool_root did not name the project whose pool config it left alone: $warning" ;;
esac
pass "a project-owned treehouse.toml is left untouched with a named warning, not a seed abort"

WT_A=$(cd "$TMP_ROOT/home-a/projects/widget" && treehouse get --lease --lease-holder home-a) \
  || fail "treehouse get --lease failed for home A"
WT_B=$(cd "$TMP_ROOT/home-b/projects/widget" && treehouse get --lease --lease-holder home-b) \
  || fail "treehouse get --lease failed for home B"
[ -n "$WT_A" ] && [ -n "$WT_B" ] || fail "treehouse get --lease did not report a worktree path"

case "$WT_A" in
  "$TMP_ROOT/home-a"/*) fail "home A's worktree '$WT_A' stayed inside home A's own worktree" ;;
esac
case "$WT_B" in
  "$TMP_ROOT/home-b"/*) fail "home B's worktree '$WT_B' stayed inside home B's own worktree" ;;
esac
[ "$WT_A" != "$WT_B" ] || fail "both homes acquired the same pooled worktree '$WT_A'"
pass "each clone's real treehouse acquire lands in its own pool, outside its home"

GITDIR_A=$(cat "$WT_A/.git")
GITDIR_B=$(cat "$WT_B/.git")
case "$GITDIR_A" in
  *"$TMP_ROOT/home-a/projects/widget/.git/worktrees/"*) : ;;
  *) fail "home A's pooled worktree links back to the wrong clone: $GITDIR_A" ;;
esac
case "$GITDIR_B" in
  *"$TMP_ROOT/home-b/projects/widget/.git/worktrees/"*) : ;;
  *) fail "home B's pooled worktree links back to the wrong clone: $GITDIR_B" ;;
esac
pass "each pooled worktree is linked to its own clone, not the other home's"

# The regression this fixes: treehouse keeps a pool out of git by rewriting the
# .gitignore of the repository enclosing {root}/.treehouse, so a root inside a
# home leaves that home permanently dirty and disables its fast-forward updates.
[ -z "$(git -C "$TMP_ROOT/home-a" status --porcelain)" ] \
  || fail "home A reads as dirty after an acquire"
[ -z "$(git -C "$TMP_ROOT/home-b" status --porcelain)" ] \
  || fail "home B reads as dirty after an acquire"
pass "neither home's own repository is dirtied by a project's pool acquire"

treehouse return --force "$WT_A" >/dev/null 2>&1 || fail "could not return home A's leased worktree"
treehouse return --force "$WT_B" >/dev/null 2>&1 || fail "could not return home B's leased worktree"
WT_A=; WT_B=
