#!/usr/bin/env bash
# Default-on live guard for per-home Treehouse pool isolation.
#
# Which pool a worktree comes from is a vendor fact: Treehouse keys a pool by the
# repository's resolved origin, so two firstmate homes holding separate clones of
# one origin shared a single pool and competed for its numbered slots. A slot
# still read free while its checkout was a linked worktree of the OTHER home's
# clone, and spawning into it was refused, which is the shape that blocked real
# work. No fixture can prove that mapping or that separating the roots removes
# it, so this guard measures it against the installed provider.
#
# It drives the real `treehouse` binary only: two clones of one origin acquire
# CONCURRENTLY, and every assertion reads the git records - the slot's own gitdir
# and each clone's worktree list - rather than any rendered Treehouse string. It
# deliberately measures the shared-root case first, so a release that stopped
# colliding on its own fails this loudly instead of letting the isolated case
# pass vacuously.
#
# It also pins the compatibility half the migration rests on: a return resolves
# its pool from the path it is handed, so every worktree leased under the
# previously shared root stays returnable after its home moves to its own root
# and nothing has to be migrated.
#
# Every repository, pool and root it creates lives under its own scratch root, so
# the suite's own cleanup removes the whole fixture and this guard arms no EXIT
# trap of its own. It submits no prompt, so the shared live gate runs it by
# default wherever treehouse exists.
# Run it after every Treehouse upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Treehouse worktree pools" entry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

fm_live_gate default-on FM_TREEHOUSE_POOL_LIVE_E2E treehouse git

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-isolation)
TREEHOUSE_VERSION=$(treehouse --version 2>&1 | head -n 1)

# The pool directory a worktree sits in: <pool>/<slot>/<repo>.
pool_of() {  # <worktree>
  local wt
  wt=$(cd "$1" && pwd -P) || return 1
  printf '%s\n' "$(dirname "$(dirname "$wt")")"
}

# The clone a slot's checkout is actually linked to, read from git, never from a
# Treehouse banner: this is the exact evidence a collision shows in the field.
owning_clone_of() {  # <worktree>
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  ( cd "$common/.." && pwd -P )
}

build_fleet() {  # <name>
  local name=$1 base
  base="$TMP_ROOT/$name"
  mkdir -p "$base/treehouse-base"
  fm_git_init_commit "$base/origin"
  git clone --quiet "$base/origin" "$base/home-a/projects/proj"
  git clone --quiet "$base/origin" "$base/home-b/projects/proj"
  printf '%s\n' "$base"
}

test_shared_root_still_collides() {
  local base clone_a clone_b wt_a wt_b
  base=$(build_fleet shared)
  clone_a="$base/home-a/projects/proj"
  clone_b="$base/home-b/projects/proj"

  # One root for both homes: exactly what every home had before per-home roots.
  wt_a=$(cd "$clone_a" && treehouse --root "$base/treehouse-base" get --lease --lease-holder a 2>/dev/null) \
    || fail "the first clone could not acquire from the shared root"
  wt_b=$(cd "$clone_b" && treehouse --root "$base/treehouse-base" get --lease --lease-holder b 2>/dev/null) \
    || fail "the second clone could not acquire from the shared root"

  [ "$(pool_of "$wt_a")" = "$(pool_of "$wt_b")" ] || fail \
    "two clones of one origin no longer share a pool under one root on $TREEHOUSE_VERSION; the isolated case below would pass for the wrong reason - re-derive this guard against the new behavior"
  pass "two clones of one origin still share a single pool under a single root ($TREEHOUSE_VERSION)"
}

test_shared_root_hands_out_a_foreign_slot() {
  local base clone_a clone_b wt_a wt_b owner
  base=$(build_fleet foreign)
  clone_a="$base/home-a/projects/proj"
  clone_b="$base/home-b/projects/proj"

  wt_a=$(cd "$clone_a" && treehouse --root "$base/treehouse-base" get --lease --lease-holder a 2>/dev/null) \
    || fail "the first clone could not acquire from the shared root"
  ( cd "$clone_a" && treehouse return --force "$wt_a" ) >/dev/null 2>&1 \
    || fail "the first clone could not return its worktree"

  # The slot now reads free. Under one shared root the second clone is handed
  # that same slot, whose checkout is still linked to the FIRST clone - the state
  # a spawn refuses and a human has to clear from the other home.
  wt_b=$(cd "$clone_b" && treehouse --root "$base/treehouse-base" get --lease --lease-holder b 2>/dev/null) \
    || fail "the second clone could not acquire from the shared root"

  owner=$(owning_clone_of "$wt_b") || fail "could not read which clone owns the acquired worktree"
  [ "$owner" = "$(cd "$clone_a" && pwd -P)" ] || fail \
    "a returned slot under a shared root is no longer handed to the other clone on $TREEHOUSE_VERSION; re-derive this guard against the new behavior"
  git -C "$clone_b" worktree list | grep -F "$wt_b" >/dev/null && fail \
    "the acquiring clone unexpectedly lists the foreign slot as its own worktree"
  pass "under a shared root a free slot is still a worktree of the other clone ($TREEHOUSE_VERSION)"
}

test_per_home_roots_acquire_concurrently_without_contention() {
  local base clone_a clone_b root_a root_b out_a out_b wt_a wt_b rc_a rc_b
  base=$(build_fleet isolated)
  clone_a="$base/home-a/projects/proj"
  clone_b="$base/home-b/projects/proj"
  out_a="$base/a.out"
  out_b="$base/b.out"

  root_a=$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$base/home-a") \
    || fail "could not derive the first home's worktree root"
  root_b=$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$base/home-b") \
    || fail "could not derive the second home's worktree root"
  [ "$root_a" != "$root_b" ] || fail "the two homes derived one worktree root"

  # Concurrent, because contention is what this has to disprove: a serialized
  # pair would not exercise two homes allocating at the same moment.
  ( cd "$clone_a" && treehouse --root "$root_a" get --lease --lease-holder a ) > "$out_a" 2>/dev/null &
  local pid_a=$!
  ( cd "$clone_b" && treehouse --root "$root_b" get --lease --lease-holder b ) > "$out_b" 2>/dev/null &
  local pid_b=$!
  rc_a=0; wait "$pid_a" || rc_a=$?
  rc_b=0; wait "$pid_b" || rc_b=$?
  [ "$rc_a" -eq 0 ] || fail "the first home failed to acquire while the second was acquiring (exit $rc_a)"
  [ "$rc_b" -eq 0 ] || fail "the second home failed to acquire while the first was acquiring (exit $rc_b)"

  wt_a=$(cat "$out_a"); wt_b=$(cat "$out_b")
  [ -d "$wt_a" ] || fail "the first home reported no usable worktree: '$wt_a'"
  [ -d "$wt_b" ] || fail "the second home reported no usable worktree: '$wt_b'"

  [ "$(pool_of "$wt_a")" != "$(pool_of "$wt_b")" ] \
    || fail "the two homes still allocated from one pool: $(pool_of "$wt_a")"
  [ "$(owning_clone_of "$wt_a")" = "$(cd "$clone_a" && pwd -P)" ] \
    || fail "the first home's worktree is linked to another clone"
  [ "$(owning_clone_of "$wt_b")" = "$(cd "$clone_b" && pwd -P)" ] \
    || fail "the second home's worktree is linked to another clone"
  git -C "$clone_a" worktree list | grep -F "$wt_a" >/dev/null \
    || fail "the first home's own clone does not list its worktree"
  git -C "$clone_b" worktree list | grep -F "$wt_b" >/dev/null \
    || fail "the second home's own clone does not list its worktree"
  git -C "$clone_a" worktree list | grep -F "$wt_b" >/dev/null \
    && fail "the first home's clone owns the second home's worktree"
  git -C "$clone_b" worktree list | grep -F "$wt_a" >/dev/null \
    && fail "the second home's clone owns the first home's worktree"
  pass "two homes cloning one origin acquire concurrently from their own roots with no contention"
}

test_a_worktree_from_another_root_still_returns() {
  local base clone legacy root reacquired
  base=$(build_fleet legacy)
  clone="$base/home-a/projects/proj"

  # A worktree leased under the previously shared root, as every live home has
  # right now.
  legacy=$(cd "$clone" && treehouse --root "$base/treehouse-base" get --lease --lease-holder legacy 2>/dev/null) \
    || fail "could not lease a worktree under the legacy shared root"

  # The home has since moved to its own root. The return still has to find that
  # worktree, or cleanup could not release work that is already in flight.
  root=$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$base/home-a") \
    || fail "could not derive the home's worktree root"
  ( cd "$clone" && treehouse --root "$root" return --force "$legacy" ) >/dev/null 2>&1 \
    || fail "a worktree leased under the legacy shared root could not be returned once the home moved roots"

  # A return puts the worktree back in its pool rather than deleting it, so the
  # proof that the lease was really released is that the legacy pool hands the
  # same slot out again.
  reacquired=$(cd "$clone" && treehouse --root "$base/treehouse-base" get --lease --lease-holder recheck 2>/dev/null) \
    || fail "the legacy pool would not hand out the returned worktree again"
  [ "$reacquired" = "$legacy" ] \
    || fail "the returned worktree was not released back into its own pool: got $reacquired, expected $legacy"
  pass "a worktree leased under a different root still returns to its own pool, so nothing in flight has to be migrated"
}

test_interactive_get_honors_the_root_it_is_given() {
  local base clone root entered
  base=$(build_fleet interactive)
  clone="$base/home-a/projects/proj"
  root=$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$base/home-a") \
    || fail "could not derive the home's worktree root"

  # bin/fm-spawn.sh does not lease: it sends the INTERACTIVE form into the
  # worker's shell, which opens a subshell in the worktree. That is the shape the
  # per-home root has to hold for, and a leased acquire would not prove it.
  entered=$(cd "$clone" && printf 'pwd -P\nexit\n' | treehouse --root "$root" get 2>/dev/null | tail -n 1)
  case "$entered" in
    "$root"/*) : ;;
    *) fail "the interactive acquire entered '$entered', not a worktree below this home's root '$root'" ;;
  esac
  pass "the interactive acquire the worker's shell runs enters a worktree below the root it is given"
}

test_shared_root_still_collides
test_shared_root_hands_out_a_foreign_slot
test_interactive_get_honors_the_root_it_is_given
test_per_home_roots_acquire_concurrently_without_contention
test_a_worktree_from_another_root_still_returns
