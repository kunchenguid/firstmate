#!/usr/bin/env bash
# Tests for bin/fm-sync-upstream.sh: fetch firstmate's upstream remote,
# fast-forward the local default branch to it, and push the result to
# origin (the captain's own fork).
#
# The guarantees under test:
#   - --check is read-only: it never merges or pushes, only reports
#     ahead/behind counts against upstream.
#   - A clean fast-forward (no local commits ahead) advances the default
#     branch and pushes it to origin.
#   - A diverged local branch (commits ahead of upstream) is refused, never
#     auto-merged - matching prime directive #3 (unlanded work survives).
#   - A dirty working tree is refused, matching fm-update.sh's own guard.
#   - The result is idempotent: a second run with nothing new reports
#     already-current.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-sync-upstream.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-sync-upstream-tests)

# Build a world with three bare remotes: upstream (the original project),
# origin (the captain's own fork, starts level with upstream), and a local
# clone of origin with upstream also configured as a remote. Echoes the
# world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/upstream.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q upstream 2>/dev/null || git -C "$w/seed" push -q origin main

  git clone -q "$w/upstream.git" "$w/origin.git" --bare 2>/dev/null

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote add upstream "$w/upstream.git"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Advance upstream by one commit.
bump_upstream() {
  local w=$1
  git -C "$w/seed" pull -q upstream main >/dev/null 2>&1 || git -C "$w/seed" pull -q origin main >/dev/null 2>&1
  printf 'v2\n' >> "$w/seed/AGENTS.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm bump
  git -C "$w/seed" push -q "$w/upstream.git" main 2>/dev/null || git -C "$w/seed" push -q upstream main
}

run_check() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$SYNC" --check 2>/dev/null
}

run_apply() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$SYNC" 2>/dev/null
}

# --- T1: --check is read-only, reports would-update -------------------------
test_check_is_readonly() {
  local w out before
  w=$(new_world t1)
  bump_upstream "$w"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_check "$w")

  assert_contains "$out" "status: would-update" "check reports an available update"
  assert_contains "$out" "behind: 1" "check reports correct behind count"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "check moved local HEAD"
  [ "$(git -C "$w/main" symbolic-ref --short HEAD)" = "main" ] || fail "check changed branch"
  pass "T1 --check is read-only and reports the pending update"
}

# --- T2: clean fast-forward advances and pushes to origin -------------------
test_clean_fast_forward_pushes_to_origin() {
  local w out
  w=$(new_world t2)
  bump_upstream "$w"

  out=$(run_apply "$w")

  assert_contains "$out" "status: updated" "apply reports updated"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse upstream/main)" ] \
    || fail "local HEAD not fast-forwarded to upstream/main"
  # Fetch a fresh clone of origin.git to confirm the push actually landed there.
  git clone -q "$w/origin.git" "$w/verify" 2>/dev/null
  [ "$(git -C "$w/verify" rev-parse main)" = "$(git -C "$w/main" rev-parse HEAD)" ] \
    || fail "origin was not advanced by the push"
  # Single-parent fast-forward, never a merge commit.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "advance is not a single-parent fast-forward"
  pass "T2 clean fast-forward advances local and pushes to origin"
}

# --- T3: diverged local branch is refused, never auto-merged ----------------
test_diverged_is_refused() {
  local w out before
  w=$(new_world t3)
  printf 'local-only work\n' >> "$w/main/AGENTS.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm local-work
  before=$(git -C "$w/main" rev-parse HEAD)
  bump_upstream "$w"

  out=$(run_check "$w")
  assert_contains "$out" "status: diverged" "check reports diverged, not would-update"
  assert_contains "$out" "resolve manually" "diverged case explains no automatic merge"

  out=$(run_apply "$w")
  assert_contains "$out" "status: skipped" "apply refuses a diverged branch"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "diverged local HEAD was moved (unlanded work at risk)"
  pass "T3 diverged local branch is refused in both --check and apply modes"
}

# --- T4: dirty working tree is refused --------------------------------------
test_dirty_working_tree_is_refused() {
  local w out before
  w=$(new_world t4)
  bump_upstream "$w"
  printf 'uncommitted\n' >> "$w/main/AGENTS.md"
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_apply "$w")

  assert_contains "$out" "status: skipped" "dirty working tree is refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "dirty-tree HEAD moved"
  grep -q 'uncommitted' "$w/main/AGENTS.md" || fail "uncommitted edit was discarded"
  pass "T4 dirty working tree is refused, local edit preserved"
}

# --- T5: idempotent; second run reports already-current ---------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t5)
  bump_upstream "$w"
  run_apply "$w" >/dev/null   # first run advances and pushes

  out=$(run_check "$w")
  assert_contains "$out" "status: already-current" "second check reports already-current"

  out=$(run_apply "$w")
  assert_contains "$out" "status: already-current" "second apply reports already-current"
  pass "T5 idempotent: a second run is a no-op in both modes"
}

test_check_is_readonly
test_clean_fast_forward_pushes_to_origin
test_diverged_is_refused
test_dirty_working_tree_is_refused
test_idempotent_already_current

echo "# all fm-sync-upstream tests passed"
