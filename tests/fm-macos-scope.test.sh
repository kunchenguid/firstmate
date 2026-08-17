#!/usr/bin/env bash
# Behavioral coverage for the stock macOS Bash scope verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOPE="$ROOT/bin/fm-macos-scope.sh"
LINT="$ROOT/bin/fm-lint.sh"
SCOPE_OUT=
SCOPE_ERR=
SCOPE_RC=0

new_scope_repo() {
  local repo
  repo=$(fm_test_tmproot fm-macos-scope)
  mkdir -p "$repo/bin/backends" "$repo/tests" "$repo/docs" \
    "$repo/.github/workflows"
  cp "$SCOPE" "$repo/bin/fm-macos-scope.sh"
  cp "$LINT" "$repo/bin/fm-lint.sh"
  printf '#!/usr/bin/env bash\nprintf "backend\\n"\n' > "$repo/bin/backends/sample.sh"
  printf '#!/usr/bin/env bash\nprintf "worker\\n"\n' > "$repo/bin/worker.sh"
  printf '#!/usr/bin/env bash\nprintf "snapshot\\n"\n' > "$repo/tests/sample.test.sh"
  printf 'name: ci\n' > "$repo/.github/workflows/ci.yml"
  printf 'name: other\n' > "$repo/.github/workflows/no-mistakes-required.yml"
  printf '# docs\n' > "$repo/docs/guide.md"
  chmod +x "$repo/bin/fm-macos-scope.sh" "$repo/bin/fm-lint.sh" \
    "$repo/bin/backends/sample.sh" "$repo/bin/worker.sh" \
    "$repo/tests/sample.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" commit -qm initial
  printf '%s\n' "$repo"
}

commit_scope_change() {
  local repo=$1 message=$2
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$message"
  git -C "$repo" rev-parse HEAD
}

run_scope() {
  local repo=$1 event=$2 base=$3 head=$4 out_file err_file
  out_file="$repo/scope.out"
  err_file="$repo/scope.err"
  SCOPE_RC=0
  (cd "$repo" && bin/fm-macos-scope.sh "$event" "$base" "$head") \
    > "$out_file" 2> "$err_file" || SCOPE_RC=$?
  SCOPE_OUT=$(cat "$out_file")
  SCOPE_ERR=$(cat "$err_file")
}

assert_scope() {
  local expected=$1 label=$2
  expect_code 0 "$SCOPE_RC" "$label"
  [ "$SCOPE_OUT" = "required=$expected" ] \
    || fail "$label: expected required=$expected, got '$SCOPE_OUT'"
  assert_contains "$SCOPE_ERR" \
    "stock macOS Bash scope: required=$expected" \
    "$label did not log its verdict"
}

test_main_push_always_requires_macos() {
  local repo head
  repo=$(new_scope_repo)
  head=$(git -C "$repo" rev-parse HEAD)
  run_scope "$repo" push '' "$head"
  assert_scope true "main push scope"
  pass "main pushes always require stock macOS Bash"
}

test_empty_pr_shas_fail_closed() {
  local repo base head
  repo=$(new_scope_repo)
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'changed\n' >> "$repo/docs/guide.md"
  head=$(commit_scope_change "$repo" docs)

  run_scope "$repo" pull_request '' "$head"
  assert_scope true "empty base SHA"
  run_scope "$repo" pull_request "$base" ''
  assert_scope true "empty head SHA"
  pass "empty pull request SHAs fail closed"
}

test_unreachable_pr_sha_fails_closed() {
  local repo base head
  repo=$(new_scope_repo)
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'changed\n' >> "$repo/docs/guide.md"
  head=$(commit_scope_change "$repo" docs)

  run_scope "$repo" pull_request "$base" ffffffffffffffffffffffffffffffffffffffff
  assert_scope true "unreachable head SHA"
  pass "an unreachable pull request SHA fails closed"
}

test_docs_only_change_skips_macos() {
  local repo base head
  repo=$(new_scope_repo)
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'changed\n' >> "$repo/docs/guide.md"
  head=$(commit_scope_change "$repo" docs)

  run_scope "$repo" pull_request "$base" "$head"
  assert_scope false "docs-only scope"
  pass "docs-only changes skip stock macOS Bash"
}

test_non_shell_bin_change_skips_macos() {
  local repo base head
  repo=$(new_scope_repo)
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'console.log("changed")\n' > "$repo/bin/dashboard.mjs"
  head=$(commit_scope_change "$repo" non-shell-bin)

  run_scope "$repo" pull_request "$base" "$head"
  assert_scope false "non-shell bin scope"
  pass "non-shell bin changes skip stock macOS Bash"
}

test_ci_workflow_change_requires_macos() {
  local repo base head
  repo=$(new_scope_repo)
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'changed: true\n' >> "$repo/.github/workflows/ci.yml"
  head=$(commit_scope_change "$repo" ci)

  run_scope "$repo" pull_request "$base" "$head"
  assert_scope true "ci workflow scope"
  pass "the CI workflow requires stock macOS Bash"
}

test_other_workflow_change_skips_macos() {
  local repo base head
  repo=$(new_scope_repo)
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'changed: true\n' >> "$repo/.github/workflows/no-mistakes-required.yml"
  head=$(commit_scope_change "$repo" other-workflow)

  run_scope "$repo" pull_request "$base" "$head"
  assert_scope false "other workflow scope"
  pass "unrelated workflow changes skip stock macOS Bash"
}

test_inventory_change_requires_macos() {
  local repo base head
  repo=$(new_scope_repo)
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'printf "changed\\n"\n' >> "$repo/bin/worker.sh"
  head=$(commit_scope_change "$repo" shell)

  run_scope "$repo" pull_request "$base" "$head"
  assert_scope true "shell inventory scope"
  pass "canonical shell changes require stock macOS Bash"
}

test_deleted_inventory_file_requires_macos() {
  local repo base head
  repo=$(new_scope_repo)
  printf '#!/usr/bin/env bash\nprintf "retired\\n"\n' > "$repo/bin/retired.sh"
  chmod +x "$repo/bin/retired.sh"
  commit_scope_change "$repo" add-retired >/dev/null
  base=$(git -C "$repo" rev-parse HEAD)
  rm "$repo/bin/retired.sh"
  head=$(commit_scope_change "$repo" delete-retired)

  run_scope "$repo" pull_request "$base" "$head"
  assert_scope true "deleted shell scope"
  pass "deleted canonical shell files require stock macOS Bash"
}

test_renamed_away_inventory_file_requires_macos() {
  local repo base head
  repo=$(new_scope_repo)
  printf '#!/usr/bin/env bash\nprintf "renamed\\n"\n' > "$repo/bin/renamed.sh"
  chmod +x "$repo/bin/renamed.sh"
  commit_scope_change "$repo" add-renamed >/dev/null
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" mv bin/renamed.sh docs/renamed.sh
  head=$(commit_scope_change "$repo" rename-away)

  run_scope "$repo" pull_request "$base" "$head"
  assert_scope true "renamed-away shell scope"
  pass "renamed-away canonical shell files require stock macOS Bash"
}

[ -x "$SCOPE" ] || fail "missing executable macOS scope interface: $SCOPE"
fm_git_identity
test_main_push_always_requires_macos
test_empty_pr_shas_fail_closed
test_unreachable_pr_sha_fails_closed
test_docs_only_change_skips_macos
test_non_shell_bin_change_skips_macos
test_ci_workflow_change_requires_macos
test_other_workflow_change_skips_macos
test_inventory_change_requires_macos
test_deleted_inventory_file_requires_macos
test_renamed_away_inventory_file_requires_macos
