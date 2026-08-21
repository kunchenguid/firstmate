#!/usr/bin/env bash
# Behavior tests for the fork-PR-origin guard (fmops-fork-pr-origin-guard).
#
# bin/fm-gh-base.sh pins a clone's `gh pr create` base to its own origin by
# setting `remote.origin.gh-resolved=base`, so a FORK clone's crew never proposes
# an internal change to the upstream parent. This suite pins:
#   - the helper sets the config on a clone that has an origin remote;
#   - it is idempotent (a second run leaves the same single value);
#   - it no-ops (exit 0, no config) on a clone with no origin remote;
#   - it fails loudly on a non-git path;
#   - fm-fleet-sync.sh's backfill applies it to an already-registered clone;
#   - fm-fleet-sync.sh does NOT apply it to a local-only clone (no regression).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-gh-base-tests)
HOME_N=0

new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

# build_clone <home> <name>: a fresh bare origin with one commit on main and a
# clone of it under projects/<name> (so it has an `origin` remote). Echoes clone.
build_clone() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"
  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  printf 'v0\n' > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -qm C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

gh_resolved() { git -C "$1" config --get remote.origin.gh-resolved 2>/dev/null || true; }

# register: write a data/projects.md entry so fm-fleet-sync resolves the mode.
register() {
  local home=$1 name=$2 annotation=$3
  mkdir -p "$home/data"
  printf -- '- %s [%s] - test (added 2026-08-21)\n' "$name" "$annotation" >> "$home/data/projects.md"
}

run_sync() {
  local home=$1; shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

# --- tests ------------------------------------------------------------------

test_helper_sets_config() {
  local home clone
  home=$(new_home); clone=$(build_clone "$home" alpha)
  [ -z "$(gh_resolved "$clone")" ] || fail "precondition: gh-resolved already set"
  "$ROOT/bin/fm-gh-base.sh" "$clone"
  [ "$(gh_resolved "$clone")" = base ] || fail "helper did not set gh-resolved=base"
  pass "helper sets remote.origin.gh-resolved=base on a clone with origin"
}

test_helper_idempotent() {
  local home clone
  home=$(new_home); clone=$(build_clone "$home" beta)
  "$ROOT/bin/fm-gh-base.sh" "$clone"
  "$ROOT/bin/fm-gh-base.sh" "$clone"
  [ "$(git -C "$clone" config --get-all remote.origin.gh-resolved | wc -l | tr -d ' ')" = 1 ] \
    || fail "second run did not leave a single gh-resolved value"
  [ "$(gh_resolved "$clone")" = base ] || fail "idempotent run lost the value"
  pass "helper is idempotent"
}

test_helper_noop_without_origin() {
  local home repo
  home=$(new_home); repo="$home/no-origin"
  git init -q "$repo"
  printf x > "$repo/f"; git -C "$repo" add f; git -C "$repo" commit -qm c0
  "$ROOT/bin/fm-gh-base.sh" "$repo" || fail "helper should exit 0 with no origin"
  [ -z "$(gh_resolved "$repo")" ] || fail "helper set config despite no origin remote"
  pass "helper no-ops (no config) on a clone without an origin remote"
}

test_helper_fails_on_non_git() {
  local home
  home=$(new_home)
  if "$ROOT/bin/fm-gh-base.sh" "$home/nope" 2>/dev/null; then
    fail "helper should fail on a non-git path"
  fi
  pass "helper fails loudly on a non-git path"
}

test_fleet_sync_backfills() {
  local home clone
  home=$(new_home); clone=$(build_clone "$home" gamma)
  register "$home" gamma no-mistakes
  [ -z "$(gh_resolved "$clone")" ] || fail "precondition: gh-resolved already set"
  run_sync "$home" >/dev/null
  [ "$(gh_resolved "$clone")" = base ] || fail "fleet-sync backfill did not set gh-resolved=base"
  pass "fleet-sync backfills the origin guard on an existing clone"
}

test_fleet_sync_skips_local_only() {
  local home clone
  home=$(new_home); clone=$(build_clone "$home" delta)
  register "$home" delta local-only
  run_sync "$home" >/dev/null
  [ -z "$(gh_resolved "$clone")" ] || fail "fleet-sync touched a local-only clone (regression)"
  pass "fleet-sync leaves local-only clones untouched"
}

test_helper_sets_config
test_helper_idempotent
test_helper_noop_without_origin
test_helper_fails_on_non_git
test_fleet_sync_backfills
test_fleet_sync_skips_local_only
