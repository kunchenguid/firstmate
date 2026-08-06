#!/usr/bin/env bash
# Behavior tests for bin/fm-worktree-env-sync.sh.
#
# The mapping fixture is local to each temporary test directory and contains
# only generated fake paths. It verifies that an absent mapping is silent, a
# missing configured source warns without stopping the caller, a mapped source
# is copied under both the default and the stock system interpreter, and a
# non-ignored target is refused before any copy occurs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-worktree-env-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-env-sync)

make_case() {
  local name=$1 case_dir project worktree config source project_branch
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  config="$case_dir/config"
  source="$case_dir/source.env"
  fm_git_worktree "$project" "$worktree" "wt-$name"
  printf '.env\n' > "$project/.gitignore"
  git -C "$project" add .gitignore
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ignore environment file'
  project_branch=$(git -C "$project" branch --show-current)
  git -C "$worktree" merge --quiet --ff-only "$project_branch"
  mkdir -p "$config"
  printf '%s\n' "$project|$worktree|$config|$source"
}

read_case() {
  IFS='|' read -r PROJECT WORKTREE CONFIG SOURCE <<EOF
$1
EOF
}

write_mapping() {  # <target>
  printf '%s\t%s\t%s\n' "$PROJECT" "$SOURCE" "$1" > "$CONFIG/worktree-env-sync.tsv"
}

run_sync() {  # [interpreter]
  "${1:-bash}" "$SYNC" "$CONFIG" "$PROJECT" "$WORKTREE" 2>&1
}

assert_no_staging_leftovers() {  # <context>
  local leftover
  leftover=$(git -C "$WORKTREE" status --porcelain 2>/dev/null | grep '\.fm-worktree-env\.' || true)
  [ -z "$leftover" ] || fail "$1 left a commit-visible staging file: $leftover"
}

test_no_mapping_is_silent_noop() {
  local record out status
  record=$(make_case no-mapping)
  read_case "$record"
  out=$(run_sync)
  status=$?
  expect_code 0 "$status" "an absent mapping file should not fail synchronization"
  [ -z "$out" ] || fail "an absent mapping file should be silent, got: $out"
  [ ! -e "$WORKTREE/.env" ] || fail "an absent mapping unexpectedly copied an environment file"
  pass "worktree env sync is a silent no-op without local configuration"
}

test_missing_source_warns_without_copying() {
  local record out status
  record=$(make_case missing-source)
  read_case "$record"
  write_mapping .env
  out=$(run_sync)
  status=$?
  expect_code 0 "$status" "a missing source should not fail synchronization"
  assert_contains "$out" 'source file is missing' "missing source warning was not conspicuous"
  [ ! -e "$WORKTREE/.env" ] || fail "a missing source unexpectedly created an environment file"
  pass "a configured missing source warns and leaves the worktree unchanged"
}

test_copy_places_the_configured_environment_file() {
  local record out status
  record=$(make_case copy)
  read_case "$record"
  printf 'test-only-content\n' > "$SOURCE"
  write_mapping .env
  out=$(run_sync)
  status=$?
  expect_code 0 "$status" "a configured source should synchronize"
  [ -z "$out" ] || fail "a successful synchronization should not expose paths or values: $out"
  cmp -s "$SOURCE" "$WORKTREE/.env" || fail "the worktree environment file did not match the configured source"
  git -C "$WORKTREE" check-ignore -q -- .env || fail "the copied environment file is not git-ignored"
  assert_no_staging_leftovers "a successful synchronization"
  pass "a configured source is copied into the ignored worktree target"
}

# The worktree-root target is the common mapping and exercises the empty
# parent-component path. Stock macOS Bash 3.2 aborts an empty array expansion
# under `set -u`, and CI only parse-checks that interpreter, so run the helper
# through /bin/bash directly to keep that runtime honest.
test_worktree_root_target_copies_under_system_bash() {
  local record out status
  [ -x /bin/bash ] || { pass "worktree env sync system bash coverage skipped without /bin/bash"; return; }
  record=$(make_case system-bash)
  read_case "$record"
  printf 'test-only-content\n' > "$SOURCE"
  write_mapping .env
  out=$(run_sync /bin/bash)
  status=$?
  expect_code 0 "$status" "a worktree-root target should synchronize under system bash"
  [ -z "$out" ] || fail "synchronization under system bash should not warn or expose paths: $out"
  cmp -s "$SOURCE" "$WORKTREE/.env" || fail "system bash did not copy the configured source to the worktree root"
  assert_no_staging_leftovers "a system bash synchronization"
  pass "a worktree-root target is copied under stock system bash"
}

test_nonignored_target_is_refused_before_copying() {
  local record out status
  record=$(make_case gitignore)
  read_case "$record"
  printf 'test-only-content\n' > "$SOURCE"
  write_mapping visible.env
  out=$(run_sync)
  status=$?
  expect_code 0 "$status" "an unsafe target should not fail the caller"
  assert_contains "$out" 'not git-ignored' "non-ignored target refusal was not conspicuous"
  [ ! -e "$WORKTREE/visible.env" ] || fail "a non-ignored target received a copied environment file"
  pass "environment files are copied only to git-ignored worktree targets"
}

test_no_mapping_is_silent_noop
test_missing_source_warns_without_copying
test_copy_places_the_configured_environment_file
test_worktree_root_target_copies_under_system_bash
test_nonignored_target_is_refused_before_copying

echo "# all fm-worktree-env-sync tests passed"
