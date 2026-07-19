#!/usr/bin/env bash
# Behavior tests for bin/fm-upstream-check.sh.
#
# fm-upstream-check.sh is the read-only inspection half of selective upstream
# integration for fork-with-local-customizations installations. The contracts
# under test:
#   - It fetches the upstream remote and lists new commits oldest first with
#     short sha, subject, author, date, and changed files; one block per commit.
#   - It never merges and never touches the working tree.
#   - When the local branch has every upstream commit, it prints exactly
#     "up to date".
#   - Remote resolution: --remote flag, then config/upstream-remote, then the
#     default "upstream". An unknown remote exits non-zero with one diagnostic.
#   - --no-fetch reuses already-fetched refs instead of fetching.
#   - A diverged local branch still lists the upstream-only commits.
#   - A detached HEAD exits non-zero rather than guessing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-upstream-check.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-upstream-check-tests)

# Build a fresh world: a bare upstream repo seeded with one commit, a seed
# clone used to advance upstream, and a local clone whose origin remote is
# renamed to "upstream" to match the fork flow. Echoes the world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w"

  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main

  git clone -q "$w/upstream.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/README.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/upstream.git" "$w/local" 2>/dev/null
  git -C "$w/local" remote rename origin upstream
  git -C "$w/local" remote set-head upstream main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Advance upstream by one commit with the given subject. The seed clone's
# origin points at the bare upstream, so a push lands there.
bump_upstream() {
  local w=$1 subject=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'change %s\n' "$subject" >> "$w/seed/README.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "$subject"
  git -C "$w/seed" push -q origin main
}

run_check() {
  local w=$1
  shift
  (cd "$w/local" && "$CHECK" "$@")
}

# --- T1: no new commits prints exactly "up to date" --------------------------
test_no_new_commits_prints_up_to_date() {
  local w out status
  w=$(new_world t1)
  out=$(run_check "$w"); status=$?
  expect_code 0 "$status" "check on a current branch should exit 0"
  [ "$out" = "up to date" ] || fail "expected exactly 'up to date', got: $out"
  pass "no new commits prints exactly 'up to date'"
}

# --- T2: new upstream commits are listed oldest first with full block --------
test_new_commits_listed_oldest_first() {
  local w out status first_sha
  w=$(new_world t2)
  bump_upstream "$w" "add-feature"
  bump_upstream "$w" "fix-bug"
  first_sha=$(git -C "$w/upstream.git" rev-list --reverse main | sed -n '2p')

  out=$(run_check "$w"); status=$?
  expect_code 0 "$status" "check with new commits should exit 0"

  # Oldest first: add-feature before fix-bug.
  assert_contains "$out" "add-feature" "missing first upstream subject"
  assert_contains "$out" "fix-bug" "missing second upstream subject"
  # The first listed block must be add-feature (oldest), not fix-bug.
  case "$out" in
    *add-feature*fix-bug*) ;;
    *) fail "expected add-feature before fix-bug in output" ;;
  esac

  # Both shas appear, and metadata fields are present.
  assert_contains "$out" "$(git -C "$w/upstream.git" rev-parse --short "$first_sha")" \
    "missing short sha for first upstream commit"
  assert_contains "$out" "author:" "missing author field"
  assert_contains "$out" "date:" "missing date field"
  assert_contains "$out" "files:" "missing files field"
  assert_contains "$out" "README.md" "missing changed-file name"

  # Working tree untouched: still on the original commit.
  [ "$(git -C "$w/local" rev-parse HEAD)" = "$(git -C "$w/upstream.git" rev-parse main~2)" ] \
    || fail "check moved local HEAD; it must be read-only"
  pass "new commits listed oldest first with sha, author, date, files; working tree untouched"
}

# --- T3: unknown remote exits non-zero with a diagnostic ---------------------
test_unknown_remote_exits_nonzero() {
  local w out status
  w=$(new_world t3)
  out=$(run_check "$w" --remote does-not-exist 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "unknown remote should exit non-zero"
  assert_contains "$out" "does-not-exist" "diagnostic should name the unknown remote"
  pass "unknown remote exits non-zero with a diagnostic naming it"
}

# --- T4: --no-fetch reuses already-fetched refs ------------------------------
test_no_fetch_uses_existing_refs() {
  local w out status
  w=$(new_world t4)
  bump_upstream "$w" "no-fetch-feature"
  # Pre-fetch so the upstream ref is current, then run with --no-fetch.
  git -C "$w/local" fetch -q upstream
  out=$(run_check "$w" --no-fetch); status=$?
  expect_code 0 "$status" "no-fetch check should exit 0 when refs are current"
  assert_contains "$out" "no-fetch-feature" "no-fetch should still list new commits from existing refs"
  pass "--no-fetch reuses already-fetched refs"
}

# --- T5: config/upstream-remote overrides the default remote name ------------
test_config_upstream_remote_overrides_default() {
  local w out status
  w=$(new_world t5)
  # Rename the upstream remote to something custom and record it in config.
  git -C "$w/local" remote rename upstream my-upstream
  mkdir -p "$w/local/config"
  printf 'my-upstream\n' > "$w/local/config/upstream-remote"
  bump_upstream "$w" "config-remote-feature"
  out=$(run_check "$w"); status=$?
  expect_code 0 "$status" "check should resolve the configured remote name"
  assert_contains "$out" "config-remote-feature" "missing commit visible only via configured remote"
  pass "config/upstream-remote overrides the default remote name"
}

# --- T6: a diverged local branch still lists upstream-only commits -----------
test_diverged_local_lists_upstream_only() {
  local w out status local_sha
  w=$(new_world t6)
  # Local advances with its own commit (divergence), then upstream advances too.
  printf 'local-only\n' >> "$w/local/README.md"
  git -C "$w/local" add -A
  git -C "$w/local" commit -qm "local-customization"
  local_sha=$(git -C "$w/local" rev-parse HEAD)
  bump_upstream "$w" "upstream-after-divergence"

  out=$(run_check "$w"); status=$?
  expect_code 0 "$status" "check on a diverged branch should exit 0"
  assert_contains "$out" "upstream-after-divergence" \
    "diverged local should still list upstream-only commits"
  # The local-only commit must never appear in the upstream summary.
  assert_not_contains "$out" "local-customization" \
    "local-only commit must not appear in the upstream summary"
  # Working tree untouched: local commit survives.
  [ "$(git -C "$w/local" rev-parse HEAD)" = "$local_sha" ] \
    || fail "check moved HEAD on a diverged branch; it must be read-only"
  pass "diverged local branch lists upstream-only commits and preserves local work"
}

# --- T7: detached HEAD exits non-zero rather than guessing -------------------
test_detached_head_exits_nonzero() {
  local w out status
  w=$(new_world t7)
  git -C "$w/local" checkout -q --detach HEAD
  out=$(run_check "$w" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "detached HEAD should exit non-zero"
  assert_contains "$out" "detached" "diagnostic should explain the detached-HEAD refusal"
  pass "detached HEAD exits non-zero rather than guessing"
}

test_no_new_commits_prints_up_to_date
test_new_commits_listed_oldest_first
test_unknown_remote_exits_nonzero
test_no_fetch_uses_existing_refs
test_config_upstream_remote_overrides_default
test_diverged_local_lists_upstream_only
test_detached_head_exits_nonzero

echo "# all fm-upstream-check tests passed"
