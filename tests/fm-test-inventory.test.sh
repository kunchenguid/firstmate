#!/usr/bin/env bash
# Behavior tests for literal-source test-inventory receipts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INVENTORY="$ROOT/bin/fm-test-inventory.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-inventory)

make_project() {
  local name=$1 project
  project=$TMP_ROOT/$name
  mkdir -p "$project/.firstmate" "$project/tests"
  cat > "$project/.firstmate/test-inventory.json" <<'EOF'
{
  "schema_version": 1,
  "status": "test-bearing",
  "baseline": {"version": 1, "declarations": 2, "test_files": 1},
  "maximum_unreviewed_deletion": 0
}
EOF
  cat > "$project/tests/test_literal.py" <<'EOF'
def test_one():
    pass

class TestLiteral:
    def test_two(self):
        pass
EOF
  printf '%s\n' "$project"
}

test_inventory_paths_never_execute_candidate_code() {
  local project base candidate
  project=$(make_project literal-only)
  "$INVENTORY" collect "$project" >/dev/null
  git -C "$project" init -q
  git -C "$project" add .firstmate tests
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm baseline
  base=$(git -C "$project" rev-parse HEAD)
  cat > "$project/conftest.py" <<'EOF'
raise RuntimeError("candidate conftest must never run")
EOF
  "$INVENTORY" collect "$project" >/dev/null || fail "literal-source collection should not execute conftest.py"
  "$INVENTORY" check "$project" >/dev/null || fail "literal-source check should not execute conftest.py"
  git -C "$project" add .firstmate/test-inventory-receipt.json conftest.py
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm candidate
  candidate=$(git -C "$project" rev-parse HEAD)
  "$INVENTORY" merge-check "$project" "$candidate" "$base" >/dev/null \
    || fail "literal-source merge verification should not execute conftest.py"
  grep -q 'literal_declarations_sha256' "$project/.firstmate/test-inventory-receipt.json" \
    || fail "receipt did not bind literal declarations"
  pass "inventory and merge verification ignore candidate conftest.py runtime behavior"
}

test_dynamic_runtime_tests_do_not_satisfy_literal_inventory() {
  local project out rc
  project=$(make_project dynamic-only)
  rm "$project/tests/test_literal.py"
  cat > "$project/tests/test_dynamic.py" <<'EOF'
globals()["test_generated"] = lambda: None
EOF
  set +e
  out=$("$INVENTORY" collect "$project" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "dynamic runtime tests must not count as literal declarations"
  printf '%s\n' "$out" | grep -q 'no literal Python test declarations' \
    || fail "dynamic-only refusal did not explain the literal-source boundary"
  pass "inventory excludes dynamically generated runtime tests"
}

test_merge_check_rejects_symlinked_test_source() {
  local project external base candidate out rc
  project=$(make_project symlinked-source)
  git -C "$project" init -q
  git -C "$project" add .firstmate tests
  "$INVENTORY" collect "$project" >/dev/null
  git -C "$project" add .firstmate/test-inventory-receipt.json
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm baseline
  base=$(git -C "$project" rev-parse HEAD)
  external="$TMP_ROOT/external-test.py"
  cp "$project/tests/test_literal.py" "$external"
  rm "$project/tests/test_literal.py"
  ln -s "$external" "$project/tests/test_literal.py"
  git -C "$project" add tests/test_literal.py
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm candidate
  candidate=$(git -C "$project" rev-parse HEAD)
  set +e
  out=$("$INVENTORY" merge-check "$project" "$candidate" "$base" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-check must reject a test source symlink"
  printf '%s\n' "$out" | grep -q 'must be a regular file' \
    || fail "symlink refusal did not identify the exact-tree regular-file requirement"
  pass "merge-check refuses test source outside the exact candidate tree"
}

test_git_collection_ignores_untracked_and_nested_repository_tests() {
  local project receipt out
  project=$(make_project 'git index boundary')
  git -C "$project" init -q
  git -C "$project" add .firstmate tests
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm baseline
  mkdir -p "$project/ignored nested repository/tests"
  printf 'ignored nested repository/\n' > "$project/.gitignore"
  cat > "$project/tests/test_untracked.py" <<'EOF'
def test_untracked():
    pass
EOF
  cat > "$project/ignored nested repository/tests/test_nested.py" <<'EOF'
def test_nested():
    pass
EOF
  git -C "$project/ignored nested repository" init -q
  out=$("$INVENTORY" collect "$project") || fail "Git-indexed collection should ignore untracked fixture noise"
  receipt=$project/.firstmate/test-inventory-receipt.json
  grep -q 'source_tree=git-index' <<<"$out" || fail "Git-indexed collection did not identify its source tree"
  grep -q '"source_tree": "git-index"' "$receipt" || fail "receipt did not bind the Git-indexed source tree"
  grep -q '"declarations": 2' "$receipt" || fail "untracked or ignored tests changed the declaration count"
  grep -q '"test_files": 1' "$receipt" || fail "untracked or ignored tests changed the test-file count"
  cat >> "$project/tests/test_literal.py" <<'EOF'

def test_unstaged_tracked_path_change():
    pass
EOF
  "$INVENTORY" check "$project" >/dev/null || fail "Git-indexed check should ignore untracked fixture noise"
  pass "Git collection uses index blobs, excluding untracked tests and ignored nested repositories"
}

test_git_collection_refuses_subdirectories() {
  local project out rc
  project=$(make_project subdirectory-refusal)
  git -C "$project" init -q
  git -C "$project" add .firstmate tests
  set +e
  out=$("$INVENTORY" collect "$project/tests" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "Git collection must refuse a checkout subdirectory"
  printf '%s\n' "$out" | grep -q 'requires the checkout root' \
    || fail "subdirectory refusal did not identify the Git checkout boundary"
  pass "Git collection refuses subdirectory traversal"
}

test_non_git_collection_is_explicit() {
  local project out
  project=$(make_project non-git-source-tree)
  out=$("$INVENTORY" collect "$project") || fail "intentional non-Git collection should remain supported"
  grep -q 'source_tree=filesystem' <<<"$out" || fail "non-Git collection did not identify filesystem mode"
  grep -q '"source_tree": "filesystem"' "$project/.firstmate/test-inventory-receipt.json" \
    || fail "non-Git receipt did not bind filesystem mode"
  "$INVENTORY" check "$project" >/dev/null || fail "non-Git receipt should check in filesystem mode"
  pass "intentional non-Git collection is explicitly typed"
}

test_linked_worktree_with_spaces_checks_without_mutation() {
  local project worktree out
  project=$(make_project linked-worktree-source)
  git -C "$project" init -q
  git -C "$project" add .firstmate tests
  "$INVENTORY" collect "$project" >/dev/null
  git -C "$project" add .firstmate/test-inventory-receipt.json
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm baseline
  worktree="$TMP_ROOT/linked worktree with spaces"
  git -C "$project" worktree add --detach -q "$worktree" HEAD
  out=$("$INVENTORY" check "$worktree") || fail "linked worktree check should succeed"
  grep -q 'source_tree=git-index' <<<"$out" || fail "linked worktree did not use its Git index"
  [ -z "$(git -C "$worktree" status --porcelain)" ] \
    || fail "linked worktree check mutated the checkout"
  pass "linked worktrees and paths with spaces retain the Git tree boundary"
}

test_inventory_paths_never_execute_candidate_code
test_dynamic_runtime_tests_do_not_satisfy_literal_inventory
test_merge_check_rejects_symlinked_test_source
test_git_collection_ignores_untracked_and_nested_repository_tests
test_git_collection_refuses_subdirectories
test_non_git_collection_is_explicit
test_linked_worktree_with_spaces_checks_without_mutation
