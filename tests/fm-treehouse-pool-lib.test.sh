#!/usr/bin/env bash
# tests/fm-treehouse-pool-lib.test.sh - proves fm_treehouse_configure_pool_root
# (bin/fm-treehouse-pool-lib.sh) actually gives two clones of one origin their
# own treehouse worktree pools, using the real treehouse binary end to end
# (harness-dependent check: the pool-collision behavior this fixes is
# treehouse's own, so a mocked path computation would only confirm the
# assumption already written into the mock). Skips when treehouse is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-treehouse-pool-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-lib) || fail "could not create temp root"

# One throwaway origin, cloned twice - standing in for a project two separate
# firstmate homes have each cloned.
fm_git_init_commit "$TMP_ROOT/widget-origin"
fm_git_add_origin "$TMP_ROOT/widget-origin" "$TMP_ROOT/widget-origin.git"
git clone --quiet "$TMP_ROOT/widget-origin.git" "$TMP_ROOT/home-a/widget" || fail "could not clone home A's widget"
git clone --quiet "$TMP_ROOT/widget-origin.git" "$TMP_ROOT/home-b/widget" || fail "could not clone home B's widget"

WT_A=; WT_B=
cleanup_leases() {
  [ -z "$WT_A" ] || treehouse return --force "$WT_A" >/dev/null 2>&1
  [ -z "$WT_B" ] || treehouse return --force "$WT_B" >/dev/null 2>&1
  fm_test_cleanup
}
trap cleanup_leases EXIT

fm_treehouse_configure_pool_root "$TMP_ROOT/home-a/widget" "$TMP_ROOT/home-a" \
  || fail "fm_treehouse_configure_pool_root refused for home A"
fm_treehouse_configure_pool_root "$TMP_ROOT/home-b/widget" "$TMP_ROOT/home-b" \
  || fail "fm_treehouse_configure_pool_root refused for home B"
pass "fm_treehouse_configure_pool_root accepts two fresh clones of one origin"

[ -z "$(git -C "$TMP_ROOT/home-a/widget" status --porcelain)" ] \
  || fail "home A's clone reads as dirty after configuring its pool root"
[ -z "$(git -C "$TMP_ROOT/home-b/widget" status --porcelain)" ] \
  || fail "home B's clone reads as dirty after configuring its pool root"
pass "the generated treehouse.toml is excluded locally, so both clones stay clean"

WT_A=$(cd "$TMP_ROOT/home-a/widget" && treehouse get --lease --lease-holder home-a) \
  || fail "treehouse get --lease failed for home A"
WT_B=$(cd "$TMP_ROOT/home-b/widget" && treehouse get --lease --lease-holder home-b) \
  || fail "treehouse get --lease failed for home B"
[ -n "$WT_A" ] && [ -n "$WT_B" ] || fail "treehouse get --lease did not report a worktree path"

case "$WT_A" in
  "$TMP_ROOT/home-a"/*) : ;;
  *) fail "home A's worktree '$WT_A' did not land under home A's own pool root" ;;
esac
case "$WT_B" in
  "$TMP_ROOT/home-b"/*) : ;;
  *) fail "home B's worktree '$WT_B' did not land under home B's own pool root" ;;
esac
pass "each clone's real treehouse acquire lands in its own home's pool"

GITDIR_A=$(cat "$WT_A/.git")
GITDIR_B=$(cat "$WT_B/.git")
case "$GITDIR_A" in
  *"$TMP_ROOT/home-a/widget/.git/worktrees/"*) : ;;
  *) fail "home A's pooled worktree links back to the wrong clone: $GITDIR_A" ;;
esac
case "$GITDIR_B" in
  *"$TMP_ROOT/home-b/widget/.git/worktrees/"*) : ;;
  *) fail "home B's pooled worktree links back to the wrong clone: $GITDIR_B" ;;
esac
pass "each pooled worktree is linked to its own clone, not the other home's"

treehouse return --force "$WT_A" >/dev/null 2>&1 || fail "could not return home A's leased worktree"
treehouse return --force "$WT_B" >/dev/null 2>&1 || fail "could not return home B's leased worktree"
WT_A=; WT_B=
