#!/usr/bin/env bash
# tests/fm-project-resolve.test.sh - project registry resolver behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

RESOLVE="$ROOT/bin/fm-project-resolve.sh"
MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-resolve-tests)

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data" "$home/projects"
  printf '%s\n' "$home"
}

make_repo() {
  local dir=$1 branch=${2:-main}
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  printf '# repo\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m initial
}

write_json_registry() {
  local home=$1 id=$2 path=$3
  cat > "$home/data/projects.json" <<EOF
{
  "schemaVersion": 1,
  "projects": [
    {
      "projectId": "$id",
      "canonicalPath": "$path",
      "gitCommonDir": "$path/.git",
      "remotes": { "origin": "https://github.com/example/$id.git" },
      "defaultBranch": "dev",
      "baseRef": "refs/remotes/origin/dev",
      "mode": "direct-PR",
      "yolo": true,
      "worktreePolicy": "firstmate-owned"
    }
  ]
}
EOF
}

run_resolve() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RESOLVE" "$@"
}

test_json_registry_resolves_external_project_identity() {
  local home repo repo_real out
  home=$(new_home json-external)
  repo="$TMP_ROOT/json-external/github/flow"
  make_repo "$repo" dev
  repo_real=$(cd "$repo" && pwd -P)
  write_json_registry "$home" flow "$repo_real"

  out=$(run_resolve "$home" --field canonical_path flow)
  [ "$out" = "$repo_real" ] || fail "canonical_path did not come from projects.json"
  out=$(run_resolve "$home" --field project_id "$repo_real")
  [ "$out" = flow ] || fail "absolute canonical path did not map back to project_id"
  out=$(run_resolve "$home" --field base_ref flow)
  [ "$out" = "refs/remotes/origin/dev" ] || fail "base_ref did not come from projects.json"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$MODE" flow)
  [ "$out" = "direct-PR on" ] || fail "fm-project-mode did not read mode/yolo from projects.json"
  pass "projects.json resolves external canonical path, stable id, base ref, and mode"
}

test_markdown_registry_fallback_still_works() {
  local home out expected
  home=$(new_home markdown-fallback)
  mkdir -p "$home/projects/app"
  expected=$(cd "$home/projects/app" && pwd -P)
  printf '%s\n' '- app [local-only +yolo] - legacy app (added 2026-07-07)' > "$home/data/projects.md"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$MODE" app)
  [ "$out" = "local-only on" ] || fail "markdown fallback mode/yolo changed"
  out=$(run_resolve "$home" --field canonical_path app)
  [ "$out" = "$expected" ] || fail "markdown fallback should resolve against FM_HOME/projects"
  pass "legacy projects.md registry remains compatible"
}

test_json_registry_refuses_linked_worktree_as_canonical() {
  local home repo wt repo_real out status
  home=$(new_home linked-worktree)
  repo="$TMP_ROOT/linked-worktree/github/flow"
  wt="$TMP_ROOT/linked-worktree/codex/flow"
  make_repo "$repo" dev
  repo_real=$(cd "$repo" && pwd -P)
  git -C "$repo_real" worktree add -q --detach "$wt" HEAD
  write_json_registry "$home" flow "$wt"

  out=$(run_resolve "$home" --field canonical_path flow 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "resolver accepted a linked worktree as canonical"
  assert_contains "$out" "linked git worktree cannot be a canonical project path" "linked-worktree refusal should explain the safety invariant"
  pass "projects.json refuses linked worktrees as canonical project paths"
}

test_json_registry_refuses_subdirectory_canonical_path() {
  local home repo repo_real subdir out status
  home=$(new_home subdir-canonical)
  repo="$TMP_ROOT/subdir-canonical/github/flow"
  make_repo "$repo" dev
  repo_real=$(cd "$repo" && pwd -P)
  subdir="$repo_real/packages/app"
  mkdir -p "$subdir"
  write_json_registry "$home" flow "$subdir"

  out=$(run_resolve "$home" --field canonical_path flow 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "resolver accepted a canonicalPath below the git root"
  assert_contains "$out" "canonicalPath must be the git work tree root" "subdirectory refusal should explain the root requirement"
  pass "projects.json refuses subdirectories as canonical project paths"
}

test_json_registry_rejects_codex_owned_canonical_path() {
  local home repo codex_home out status
  home=$(new_home codex-root)
  codex_home="$TMP_ROOT/codex-root/codex-home"
  repo="$codex_home/worktrees/abcd/flow"
  make_repo "$repo" dev
  write_json_registry "$home" flow "$repo"

  out=$(CODEX_HOME="$codex_home" run_resolve "$home" --field canonical_path flow 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "resolver accepted a CODEX_HOME worktree as canonical"
  assert_contains "$out" "Codex-owned worktree roots cannot be canonical project paths" "Codex-owned refusal should explain the safety invariant"
  pass "projects.json refuses CODEX_HOME worktree roots as canonical project paths"
}

test_json_registry_malformed_file_fails_closed() {
  local home out status
  home=$(new_home malformed-json)
  mkdir -p "$home/projects/flow"
  printf '{ not json\n' > "$home/data/projects.json"

  out=$(run_resolve "$home" --field canonical_path flow 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed projects.json fell back to legacy project path"
  assert_not_contains "$out" "$home/projects/flow" "malformed projects.json should not resolve a legacy checkout"
  pass "malformed projects.json fails closed instead of falling back"
}

test_json_registry_requires_explicit_policy_fields() {
  local home repo repo_real out status
  home=$(new_home missing-policy)
  repo="$TMP_ROOT/missing-policy/github/flow"
  make_repo "$repo" dev
  repo_real=$(cd "$repo" && pwd -P)
  cat > "$home/data/projects.json" <<EOF
{
  "schemaVersion": 1,
  "projects": [
    {
      "projectId": "flow",
      "canonicalPath": "$repo_real",
      "gitCommonDir": "$repo_real/.git",
      "defaultBranch": "dev",
      "mode": "direct-PR",
      "yolo": false
    }
  ]
}
EOF

  out=$(run_resolve "$home" --field base_ref flow 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "projects.json entry without baseRef resolved"
  assert_contains "$out" "missing required baseRef" "missing baseRef should fail closed"
  out=$(run_resolve "$home" --list 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "projects.json list accepted an entry without baseRef"
  assert_contains "$out" "missing required baseRef" "list should validate missing baseRef for bootstrap"

  cat > "$home/data/projects.json" <<EOF
{
  "schemaVersion": 1,
  "projects": [
    {
      "projectId": "flow",
      "canonicalPath": "$repo_real",
      "gitCommonDir": "$repo_real/.git",
      "defaultBranch": "dev",
      "baseRef": "refs/remotes/origin/dev",
      "mode": "direct-PR"
    }
  ]
}
EOF
  out=$(run_resolve "$home" --field yolo flow 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "projects.json entry without yolo resolved"
  assert_contains "$out" "missing required yolo" "missing yolo should fail closed"
  pass "projects.json requires explicit policy fields"
}

test_json_registry_list_rejects_missing_project_id() {
  local home repo repo_real out status
  home=$(new_home missing-project-id)
  repo="$TMP_ROOT/missing-project-id/github/flow"
  make_repo "$repo" dev
  repo_real=$(cd "$repo" && pwd -P)
  cat > "$home/data/projects.json" <<EOF
{
  "schemaVersion": 1,
  "projects": [
    {
      "canonicalPath": "$repo_real",
      "gitCommonDir": "$repo_real/.git",
      "defaultBranch": "dev",
      "baseRef": "refs/remotes/origin/dev",
      "mode": "direct-PR",
      "yolo": false
    }
  ]
}
EOF

  out=$(run_resolve "$home" --list 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "projects.json list accepted an entry without projectId"
  assert_contains "$out" "missing required projectId" "list should validate projectId for bootstrap"
  pass "projects.json list rejects entries missing projectId"
}

test_json_registry_rejects_invalid_policy_fields() {
  local home repo repo_real out status
  home=$(new_home invalid-policy)
  repo="$TMP_ROOT/invalid-policy/github/flow"
  make_repo "$repo" dev
  repo_real=$(cd "$repo" && pwd -P)
  cat > "$home/data/projects.json" <<EOF
{
  "schemaVersion": 1,
  "projects": [
    {
      "projectId": "flow",
      "canonicalPath": "$repo_real",
      "gitCommonDir": "$repo_real/.git",
      "defaultBranch": "dev",
      "baseRef": "refs/remotes/origin/dev",
      "mode": "fast",
      "yolo": false
    }
  ]
}
EOF
  out=$(run_resolve "$home" --field mode flow 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "projects.json entry with invalid mode resolved"
  assert_contains "$out" "invalid mode" "invalid mode should fail closed"

  cat > "$home/data/projects.json" <<EOF
{
  "schemaVersion": 1,
  "projects": [
    {
      "projectId": "flow",
      "canonicalPath": "$repo_real",
      "gitCommonDir": "$repo_real/.git",
      "defaultBranch": "dev",
      "baseRef": "refs/remotes/origin/dev",
      "mode": "direct-PR",
      "yolo": "maybe"
    }
  ]
}
EOF
  out=$(run_resolve "$home" --field yolo flow 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "projects.json entry with invalid yolo resolved"
  assert_contains "$out" "invalid yolo" "invalid yolo should fail closed"
  pass "projects.json rejects invalid policy fields"
}

test_json_registry_matches_physical_canonical_path() {
  local home real_parent link_parent repo link repo_real out
  home=$(new_home symlink-roundtrip)
  real_parent="$TMP_ROOT/symlink-roundtrip/real"
  link_parent="$TMP_ROOT/symlink-roundtrip/link"
  repo="$real_parent/flow"
  mkdir -p "$real_parent"
  make_repo "$repo" dev
  ln -s "$real_parent" "$link_parent"
  link="$link_parent/flow"
  repo_real=$(cd "$repo" && pwd -P)
  write_json_registry "$home" flow "$link"

  out=$(run_resolve "$home" --field source "$repo_real")
  [ "$out" = json ] || fail "physical canonical path did not resolve to the JSON project entry"
  out=$(run_resolve "$home" --field base_ref "$repo_real")
  [ "$out" = "refs/remotes/origin/dev" ] || fail "physical canonical path lost the registry base ref"
  pass "projects.json matches symlinked canonical paths by physical checkout"
}

test_explicit_path_outside_managed_projects_does_not_borrow_legacy_policy() {
  local home repo repo_real out
  home=$(new_home explicit-path-policy)
  repo="$TMP_ROOT/explicit-path-policy/external/app"
  make_repo "$repo" main
  repo_real=$(cd "$repo" && pwd -P)
  printf '%s\n' '- app [local-only +yolo] - legacy app (added 2026-07-07)' > "$home/data/projects.md"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$MODE" "$repo_real" 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "explicit external path borrowed legacy app mode/yolo: $out"
  out=$(run_resolve "$home" --field project_id "$repo_real" 2>/dev/null)
  [ "$out" = "$repo_real" ] || fail "explicit external path collapsed to basename project id"
  pass "explicit paths outside managed projects do not borrow legacy policy by basename"
}

test_json_registry_list_merges_legacy_projects() {
  local home repo repo_real out app_real
  home=$(new_home list-merge)
  repo="$TMP_ROOT/list-merge/github/flow"
  make_repo "$repo" dev
  repo_real=$(cd "$repo" && pwd -P)
  write_json_registry "$home" flow "$repo_real"
  mkdir -p "$home/projects/app"
  app_real=$(cd "$home/projects/app" && pwd -P)

  out=$(run_resolve "$home" --list)

  assert_contains "$out" $'flow\t'"$repo_real" "list should include JSON-registered external project"
  assert_contains "$out" $'app\t'"$app_real" "list should include legacy projects when JSON sidecar exists"
  pass "project list merges JSON sidecar projects with legacy projects directory"
}

test_json_registry_miss_falls_back_to_legacy_project() {
  local home repo repo_real app_real out
  home=$(new_home json-miss-legacy)
  repo="$TMP_ROOT/json-miss-legacy/github/flow"
  make_repo "$repo" dev
  repo_real=$(cd "$repo" && pwd -P)
  write_json_registry "$home" flow "$repo_real"
  mkdir -p "$home/projects/app"
  app_real=$(cd "$home/projects/app" && pwd -P)
  printf '%s\n' '- app [local-only +yolo] - legacy app (added 2026-07-07)' > "$home/data/projects.md"

  out=$(run_resolve "$home" --field source app)
  [ "$out" = legacy ] || fail "JSON miss did not fall back to legacy source"
  out=$(run_resolve "$home" --field canonical_path app)
  [ "$out" = "$app_real" ] || fail "JSON miss did not resolve legacy canonical path"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$MODE" app)
  [ "$out" = "local-only on" ] || fail "JSON miss did not preserve legacy mode/yolo"
  pass "JSON sidecar misses fall back to legacy projects"
}

test_json_registry_resolves_external_project_identity
test_markdown_registry_fallback_still_works
test_json_registry_refuses_linked_worktree_as_canonical
test_json_registry_refuses_subdirectory_canonical_path
test_json_registry_rejects_codex_owned_canonical_path
test_json_registry_malformed_file_fails_closed
test_json_registry_requires_explicit_policy_fields
test_json_registry_list_rejects_missing_project_id
test_json_registry_rejects_invalid_policy_fields
test_json_registry_matches_physical_canonical_path
test_explicit_path_outside_managed_projects_does_not_borrow_legacy_policy
test_json_registry_list_merges_legacy_projects
test_json_registry_miss_falls_back_to_legacy_project
