#!/usr/bin/env bash
# Tests for bin/fm-fleet-sync.sh's symlink-project handling.
#
# A projects/<name> symlink must be resolved before any git operation so the
# canonical checkout is refreshed with the same clean fast-forward-only and
# gone-branch pruning safety as an ordinary clone. The git wrapper below rejects
# a symlink path passed to `git -C`, making these tests fail if fleet sync merely
# relies on git's implicit symlink traversal.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT/bin/fm-fleet-sync.sh"
REAL_GIT=$(command -v git)
TMP_ROOT=

export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.com
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.com

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-sync-tests.XXXXXX")

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# Build a bare origin, a canonical target clone, and a projects/linked symlink.
# A PATH-prepended git wrapper records every -C directory and refuses symlinks,
# proving the script resolved the project before applying git safety checks.
new_world() {
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  fakebin="$w/fakebin"
  mkdir -p "$w/home/projects" "$w/home/state" "$w/home/data" "$fakebin"
  touch "$w/home/state/.last-watcher-beat"
  printf '%s\n' '- linked [no-mistakes] - linked test project (added 2026-07-20)' \
    > "$w/home/data/projects.md"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'one\n' > "$w/seed/tracked.txt"
  git -C "$w/seed" add tracked.txt
  git -C "$w/seed" commit -qm baseline
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/canonical target"
  git -C "$w/canonical target" remote set-head origin main >/dev/null 2>&1 || true
  ln -s "$w/canonical target" "$w/home/projects/linked"

  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ]; then
  dir=${2:-}
  printf '%s\n' "$dir" >> "$FM_TEST_GIT_C_LOG"
  if [ -L "$dir" ]; then
    printf 'test git wrapper refuses symlink -C path: %s\n' "$dir" >&2
    exit 97
  fi
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"

  printf '%s\n' "$w"
}

bump_origin() {
  local w=$1 label=${2:-remote}
  printf '%s\n' "$label" >> "$w/seed/tracked.txt"
  git -C "$w/seed" add tracked.txt
  git -C "$w/seed" commit -qm "$label"
  git -C "$w/seed" push -q origin main
}

run_sync() {
  local w=$1
  shift
  : > "$w/git-c.log"
  PATH="$w/fakebin:$PATH" \
  FM_TEST_REAL_GIT="$REAL_GIT" \
  FM_TEST_GIT_C_LOG="$w/git-c.log" \
  FM_HOME="$w/home" \
    "$SYNC" "$@" 2>/dev/null
}

assert_canonical_git_target() {
  local w=$1 link target
  link="$w/home/projects/linked"
  target=$(cd "$w/canonical target" && pwd -P)
  [ -s "$w/git-c.log" ] || fail "fleet sync did not invoke git"
  if grep -Fx "$link" "$w/git-c.log" >/dev/null; then
    fail "fleet sync passed the symlink entry to git -C"
  fi
  grep -Fx "$target" "$w/git-c.log" >/dev/null \
    || fail "fleet sync did not operate on canonical target $target"
}

test_symlink_target_fast_forwards_during_fleet_iteration() {
  local w out
  w=$(new_world fast-forward)
  bump_origin "$w" remote-ahead

  out=$(run_sync "$w") || fail "fleet iteration failed: $out"

  assert_contains "$out" "linked: synced " "symlink label was not preserved"
  [ "$(git -C "$w/canonical target" rev-parse HEAD)" = "$(git -C "$w/canonical target" rev-parse origin/main)" ] \
    || fail "canonical target did not fast-forward to origin/main"
  [ -L "$w/home/projects/linked" ] || fail "project symlink was replaced"
  assert_canonical_git_target "$w"
  pass "fleet iteration resolves and fast-forwards a symlink target"
}

test_dirty_symlink_target_is_skipped() {
  local w out before
  w=$(new_world dirty)
  bump_origin "$w" remote-ahead
  before=$(git -C "$w/canonical target" rev-parse HEAD)
  printf 'local edit\n' >> "$w/canonical target/tracked.txt"

  out=$(run_sync "$w" "$w/home/projects/linked") || fail "explicit dirty sync failed: $out"

  assert_contains "$out" "linked: skipped: dirty working tree" "dirty target skip was not reported"
  [ "$(git -C "$w/canonical target" rev-parse HEAD)" = "$before" ] \
    || fail "dirty target HEAD changed"
  grep -F 'local edit' "$w/canonical target/tracked.txt" >/dev/null \
    || fail "dirty target edit was discarded"
  assert_canonical_git_target "$w"
  pass "explicit sync safely skips a dirty symlink target"
}

test_diverged_symlink_target_is_skipped() {
  local w out local_tip
  w=$(new_world diverged)
  printf 'local commit\n' >> "$w/canonical target/tracked.txt"
  git -C "$w/canonical target" add tracked.txt
  git -C "$w/canonical target" commit -qm local-ahead
  local_tip=$(git -C "$w/canonical target" rev-parse HEAD)
  bump_origin "$w" remote-ahead

  out=$(run_sync "$w" "$w/home/projects/linked") || fail "explicit diverged sync failed: $out"

  assert_contains "$out" "linked: skipped: local main has diverged from origin/main" \
    "diverged target skip was not reported"
  [ "$(git -C "$w/canonical target" rev-parse HEAD)" = "$local_tip" ] \
    || fail "diverged target HEAD changed"
  assert_canonical_git_target "$w"
  pass "explicit sync safely skips a diverged symlink target"
}

test_off_default_symlink_target_is_skipped() {
  local w out before
  w=$(new_world off-default)
  bump_origin "$w" remote-ahead
  git -C "$w/canonical target" checkout -qb topic
  before=$(git -C "$w/canonical target" rev-parse HEAD)

  out=$(run_sync "$w" "$w/home/projects/linked") || fail "explicit off-default sync failed: $out"

  assert_contains "$out" "linked: skipped: on topic, expected main" \
    "off-default target skip was not reported"
  [ "$(git -C "$w/canonical target" rev-parse HEAD)" = "$before" ] \
    || fail "off-default target HEAD changed"
  [ "$(git -C "$w/canonical target" symbolic-ref --short HEAD)" = topic ] \
    || fail "off-default target changed branches"
  assert_canonical_git_target "$w"
  pass "explicit sync safely skips an off-default symlink target"
}

test_offline_symlink_target_fails_require_current() {
  local w out before rc
  w=$(new_world offline)
  before=$(git -C "$w/canonical target" rev-parse HEAD)
  mv "$w/origin.git" "$w/origin.offline"

  if out=$(run_sync "$w" --require-current "$w/home/projects/linked"); then
    rc=0
  else
    rc=$?
  fi

  [ "$rc" -eq 1 ] || fail "offline --require-current sync returned $rc instead of 1"
  assert_contains "$out" "linked: skipped: fetch failed" "offline target skip was not reported"
  [ "$(git -C "$w/canonical target" rev-parse HEAD)" = "$before" ] \
    || fail "offline target HEAD changed"
  assert_canonical_git_target "$w"
  pass "offline symlink target is reported and fails --require-current"
}

test_symlink_target_pruning_respects_live_worktrees() {
  local w out
  w=$(new_world pruning)
  git -C "$w/seed" branch live main
  git -C "$w/seed" branch stale main
  git -C "$w/seed" push -q origin live stale
  git -C "$w/canonical target" fetch -q origin
  git -C "$w/canonical target" branch --track live origin/live >/dev/null
  git -C "$w/canonical target" branch --track stale origin/stale >/dev/null
  git -C "$w/canonical target" worktree add -q "$w/live-wt" live
  git -C "$w/seed" push -q origin --delete live stale

  out=$(run_sync "$w") || fail "symlink pruning sync failed: $out"

  git -C "$w/canonical target" show-ref --verify --quiet refs/heads/live \
    || fail "fleet sync pruned a branch still used by the target's worktree"
  if git -C "$w/canonical target" show-ref --verify --quiet refs/heads/stale; then
    fail "fleet sync did not prune an unused gone branch"
  fi
  assert_contains "$out" "linked: pruned stale" "unused gone branch prune was not reported"
  case "$out" in
    *"linked: pruned live"*) fail "live worktree branch was reported pruned" ;;
  esac
  assert_canonical_git_target "$w"
  pass "symlink target pruning preserves branches used by live worktrees"
}

test_symlink_target_fast_forwards_during_fleet_iteration
test_dirty_symlink_target_is_skipped
test_diverged_symlink_target_is_skipped
test_off_default_symlink_target_is_skipped
test_offline_symlink_target_fails_require_current
test_symlink_target_pruning_respects_live_worktrees
printf '%s\n' 'all fleet sync tests passed'
