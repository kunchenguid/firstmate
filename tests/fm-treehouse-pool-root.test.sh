#!/usr/bin/env bash
# Pins, against the INSTALLED treehouse binary rather than a stub, the pool
# facts bin/fm-spawn.sh's per-home pool root relies on (that script's header
# owns the contract; bin/fm-wake-lib.sh's fm_treehouse_pool_root owns the
# root). Every fact is asserted as an outcome a wrong pool cannot produce: each
# case reads the git common dir of the worktree it was actually handed, never
# whether a directory is empty, because a fresh pool and a relocated pool look
# identical to a listing.
#
#   1. The pool key inside a root is the clone's directory basename plus the
#      first six hex digits of sha256 over its origin URL, under
#      <root>/.treehouse/, and the default root is $HOME.
#   2. Under one shared root, a second clone of the same origin with the same
#      basename is handed the FIRST clone's worktree: the collision.
#   3. Under each home's own root, each clone is handed a worktree of itself.
#   4. `treehouse return` resolves the pool from the slot path, so a slot under
#      a non-default root returns without --root, which is what
#      bin/fm-teardown.sh relies on.
#
# Skips when treehouse is not installed; CI installs the pinned version
# (bin/fm-install-treehouse.sh). HOME is a scratch directory throughout so the
# default root is never the developer's own pool.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-root)
export HOME="$TMP_ROOT/user-home"
mkdir -p "$HOME"
unset TREEHOUSE_ROOT

physical() { (cd -P -- "$1" && pwd -P); }
common_dir_of() { physical "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"; }
sha256_prefix() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-6
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-6
  fi
}
pool_root_of() {  # <home>
  ( export FM_HOME="$1"; . "$ROOT/bin/fm-wake-lib.sh"; fm_treehouse_pool_root )
}
lease() {  # <clone> <holder> [treehouse get flags...]
  local clone=$1 holder=$2
  shift 2
  ( cd "$clone" && treehouse get --lease --no-fetch --lease-holder "$holder" "$@" 2>"$TMP_ROOT/lease.err" ) \
    || fail "treehouse get --lease failed for $clone"$'\n'"$(cat "$TMP_ROOT/lease.err")"
}
return_slot() {  # <clone> <slot> [treehouse return flags...]
  local clone=$1 slot=$2
  shift 2
  ( cd "$clone" && treehouse return --force "$@" "$slot" >/dev/null 2>"$TMP_ROOT/return.err" ) \
    || fail "treehouse return failed for $slot"$'\n'"$(cat "$TMP_ROOT/return.err")"
}
slot_state() {  # <clone> <root> <slot> -> "<status> <lease_holder>"
  ( cd "$1" && treehouse status --root "$2" --json ) | python3 -c '
import json, sys
want = sys.argv[1]
for w in json.load(sys.stdin):
    if w["path"] == want:
        print(w["status"], w.get("lease_holder", ""))
' "$3"
}

SEED="$TMP_ROOT/seed"
ORIGIN="$TMP_ROOT/origin.git"
HOME_A="$TMP_ROOT/home-a"
HOME_B="$TMP_ROOT/home-b"
CLONE_A="$HOME_A/projects/proj"
CLONE_B="$HOME_B/projects/proj"
fm_git_init_commit "$SEED"
git clone --quiet --bare "$SEED" "$ORIGIN"
git clone --quiet "file://$ORIGIN" "$CLONE_A"
git clone --quiet "file://$ORIGIN" "$CLONE_B"
ORIGIN_URL=$(git -C "$CLONE_A" remote get-url origin)
[ "$ORIGIN_URL" = "$(git -C "$CLONE_B" remote get-url origin)" ] || fail "fixture: the two clones do not share an origin URL"
POOL_KEY="proj-$(sha256_prefix "$ORIGIN_URL")"
COMMON_A=$(common_dir_of "$CLONE_A")
COMMON_B=$(common_dir_of "$CLONE_B")
[ "$COMMON_A" != "$COMMON_B" ] || fail "fixture: the two clones share a git dir"

test_pool_key_is_basename_plus_origin_hash_under_home() {
  local slot pool
  slot=$(lease "$CLONE_A" fact-key)
  pool=$(dirname "$(dirname "$slot")")
  assert_equals "$HOME/.treehouse/$POOL_KEY" "$pool" \
    "the default pool is not <\$HOME>/.treehouse/<basename>-<sha256(origin)[:6]>"
  assert_equals "$COMMON_A" "$(common_dir_of "$slot")" \
    "the first clone's own worktree does not belong to it"
  return_slot "$CLONE_A" "$slot"
  pass "the pool key is the clone basename plus the first six sha256 hex digits of its origin URL, rooted at HOME"
}

test_shared_root_hands_the_second_clone_the_first_clones_worktree() {
  local slot
  slot=$(lease "$CLONE_B" fact-collision)
  assert_equals "$HOME/.treehouse/$POOL_KEY" "$(dirname "$(dirname "$slot")")" \
    "the second clone did not resolve to the same shared pool"
  assert_equals "$COMMON_A" "$(common_dir_of "$slot")" \
    "the second clone was not handed the first clone's worktree, so the collision this fix exists for no longer reproduces; re-establish the pool key before trusting the fix"
  assert_not_equals "$COMMON_B" "$(common_dir_of "$slot")" \
    "the second clone was handed its own worktree under the shared root"
  return_slot "$CLONE_B" "$slot"
  pass "under a shared root the second clone of the same origin is handed the first clone's worktree"
}

test_per_home_root_hands_each_clone_its_own_worktree() {
  local root_a root_b slot_a slot_b
  root_a=$(pool_root_of "$HOME_A")
  root_b=$(pool_root_of "$HOME_B")
  assert_equals "$(physical "$HOME_A")" "$root_a" "fm_treehouse_pool_root did not return the physical home"
  assert_not_equals "$root_a" "$root_b" "the two homes resolved to one pool root"
  slot_a=$(lease "$CLONE_A" fact-own-a --root "$root_a")
  slot_b=$(lease "$CLONE_B" fact-own-b --root "$root_b")
  assert_equals "$root_a/.treehouse/$POOL_KEY" "$(dirname "$(dirname "$slot_a")")" \
    "home A's pool is not under its own root"
  assert_equals "$root_b/.treehouse/$POOL_KEY" "$(dirname "$(dirname "$slot_b")")" \
    "home B's pool is not under its own root"
  assert_equals "$COMMON_A" "$(common_dir_of "$slot_a")" "home A was not handed a worktree of its own clone"
  assert_equals "$COMMON_B" "$(common_dir_of "$slot_b")" "home B was not handed a worktree of its own clone"
  return_slot "$CLONE_A" "$slot_a"
  SLOT_B_LEASED=$(lease "$CLONE_B" fact-return --root "$root_b")
  pass "under each home's own root every clone is handed a worktree of itself"
}

# Relies on the slot test_per_home_root_hands_each_clone_its_own_worktree left
# leased under home B's root.
test_return_needs_no_root() {
  local root_b state
  root_b=$(pool_root_of "$HOME_B")
  state=$(slot_state "$CLONE_B" "$root_b" "$SLOT_B_LEASED")
  assert_equals "leased fact-return" "$state" "fixture: the slot under home B's root is not leased"
  return_slot "$CLONE_B" "$SLOT_B_LEASED"
  state=$(slot_state "$CLONE_B" "$root_b" "$SLOT_B_LEASED")
  assert_equals "available " "$state" "returning without --root did not release the slot under a non-default root"
  pass "treehouse return locates the pool from the slot path, without --root"
}

SLOT_B_LEASED=
test_pool_key_is_basename_plus_origin_hash_under_home
test_shared_root_hands_the_second_clone_the_first_clones_worktree
test_per_home_root_hands_each_clone_its_own_worktree
test_return_needs_no_root

echo "# all fm-treehouse-pool-root tests passed"
