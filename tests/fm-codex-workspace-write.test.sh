#!/usr/bin/env bash
# Codex workspace-write grant: the nine task-exact writable roots.
#
# These tests pin the grant composition through the library's public
# interface, with no Codex present: the exact root set for a linked worktree,
# refusal of a plain checkout, refusal of escaping task ids, and preparing
# the grant paths without clobbering task state. Enforcement itself (the
# vendor still honors exactly these roots) belongs to the opt-in live guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-codex-workspace-write-lib.sh
. "$ROOT/bin/fm-codex-workspace-write-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-workspace-write)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_no_exact_root() {  # <roots> <path> <msg>: fail when path is a full line of roots
  case "
$1
" in
    *"
$2
"*) fail "$3 (unexpected root: '$2')" ;;
  esac
}

make_case() {  # <name> <id> -> worktree|data|status|inbox
  local name=$1 id=$2 dir project
  dir="$TMP_ROOT/$name"
  project="$dir/project"
  mkdir -p "$dir/home/state" "$dir/home/data"
  fm_git_worktree "$project" "$dir/worktree" "fixture-$name"
  printf '%s|%s|%s|%s\n' "$dir/worktree" "$dir/home/data/$id" \
    "$dir/home/state/$id.status" "$dir/home/state/$id.inbox"
}

test_linked_worktree_roots_are_exact_and_narrow() {
  local rec wt data status inbox common git_dir roots count id
  id=codex-grant-z1
  rec=$(make_case linked "$id")
  IFS='|' read -r wt data status inbox <<EOF
$rec
EOF
  fm_codex_workspace_write_prepare "$wt" "$data" "$status" "$inbox" "$id" \
    || fail "prepare should succeed for a linked worktree"
  roots=$(fm_codex_workspace_write_roots "$wt" "$data" "$status" "$inbox" "$id") \
    || fail "roots should resolve for a linked worktree"
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)
  git_dir=$(git -C "$wt" rev-parse --absolute-git-dir)
  count=$(printf '%s\n' "$roots" | wc -l | tr -d ' ')
  [ "$count" -eq 9 ] || fail "grant must resolve to nine roots, got $count: $roots"
  assert_contains "$roots" "$common/objects" "grant omitted the object store"
  assert_contains "$roots" "$git_dir" "grant omitted the worktree admin directory"
  assert_contains "$roots" "$data" "grant omitted the task report directory"
  assert_contains "$roots" "$status" "grant omitted the task status file"
  assert_contains "$roots" "$inbox" "grant omitted the task inbox directory"
  assert_contains "$roots" "$common/refs/heads/fm/$id" "grant omitted the task branch ref"
  assert_contains "$roots" "$common/refs/heads/fm/$id.lock" "grant omitted the task ref lock"
  assert_contains "$roots" "$common/logs/refs/heads/fm/$id" "grant omitted the task reflog"
  assert_contains "$roots" "$common/logs/refs/heads/fm/$id.lock" "grant omitted the task reflog lock"
  assert_no_exact_root "$roots" "$common" "grant included the whole common Git directory"
  assert_no_exact_root "$roots" "$common/refs/heads/fm" "grant included the fm ref namespace"
  assert_no_exact_root "$roots" "$common/refs" "grant included the refs tree"
  assert_no_exact_root "$roots" "$(dirname "$status")" "grant included the task state directory"
  assert_no_exact_root "$roots" "$(dirname "$data")" "grant included the home data directory"
  assert_no_exact_root "$roots" "$common/refs/heads/fm/other-task" "grant included a sibling branch ref"
  while IFS= read -r root; do
    case "$root" in /*) ;; *) fail "grant root is not absolute: $root" ;; esac
  done <<< "$roots"
  pass "linked-worktree grant resolves to the nine task-exact roots"
}

test_plain_checkout_refuses() {
  local project="$TMP_ROOT/plain/project" data status inbox
  data="$TMP_ROOT/plain/home/data/plain-z2"
  status="$TMP_ROOT/plain/home/state/plain-z2.status"
  inbox="$TMP_ROOT/plain/home/state/plain-z2.inbox"
  mkdir -p "$(dirname "$data")" "$(dirname "$status")"
  fm_git_init_commit "$project"
  if fm_codex_workspace_write_roots "$project" "$data" "$status" "$inbox" plain-z2 >/dev/null; then
    fail "plain checkout must refuse rather than grant its common Git directory"
  fi
  if fm_codex_workspace_write_prepare "$project" "$data" "$status" "$inbox" plain-z2 >/dev/null 2>&1; then
    fail "prepare must refuse a plain checkout before creating anything"
  fi
  [ ! -e "$data" ] && [ ! -e "$status" ] && [ ! -e "$inbox" ] \
    || fail "refused prepare created home-side paths"
  pass "plain checkout refuses instead of widening to its common Git directory"
}

test_escaping_task_ids_refuse() {
  local rec wt data status inbox id
  rec=$(make_case ids codex-grant-z3)
  IFS='|' read -r wt data status inbox <<EOF
$rec
EOF
  for id in '' '.' '..' '-lead' '.lead' '../esc' 'a/b' 'a b' 'fm/x'; do
    if fm_codex_workspace_write_roots "$wt" "$data" "$status" "$inbox" "$id" >/dev/null 2>&1; then
      fail "grant resolved for escaping task id '$id'"
    fi
  done
  pass "escaping task ids refuse"
}

test_prepare_creates_without_clobbering() {
  local rec wt data status inbox id
  id=codex-grant-z4
  rec=$(make_case prep "$id")
  IFS='|' read -r wt data status inbox <<EOF
$rec
EOF
  printf 'working: existing\n' > "$status"
  fm_codex_workspace_write_prepare "$wt" "$data" "$status" "$inbox" "$id" \
    || fail "prepare should succeed for a linked worktree"
  [ "$(cat "$status")" = "working: existing" ] \
    || fail "prepare truncated the existing status file"
  [ -d "$data" ] || fail "prepare did not create the task report directory"
  [ -d "$inbox/handled" ] || fail "prepare did not create the inbox handled directory"
  [ -d "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)/refs/heads/fm" ] \
    || fail "prepare did not create the branch ref parents"
  [ -d "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)/logs/refs/heads/fm" ] \
    || fail "prepare did not create the reflog parents"
  fm_codex_workspace_write_prepare "$wt" "$data" "$status" "$inbox" "$id" \
    || fail "prepare should be idempotent"
  [ "$(cat "$status")" = "working: existing" ] \
    || fail "re-prepare truncated the existing status file"
  pass "prepare creates grant paths without clobbering task state"
}

test_symlinked_grant_path_refuses() {
  local rec wt data status inbox id target
  id=codex-grant-z5
  rec=$(make_case symlink "$id")
  IFS='|' read -r wt data status inbox <<EOF
$rec
EOF
  mkdir -p "$TMP_ROOT/symlink/real"
  target="$TMP_ROOT/symlink/home/state/$id.status"
  mkdir -p "$(dirname "$target")"
  printf 'x\n' > "$TMP_ROOT/symlink/real/status"
  ln -s "$TMP_ROOT/symlink/real/status" "$target"
  if fm_codex_workspace_write_prepare "$wt" "$data" "$target" "$inbox" "$id" >/dev/null 2>&1; then
    fail "prepare followed a symlinked status file"
  fi
  pass "symlinked grant path refuses"
}

test_linked_worktree_roots_are_exact_and_narrow
test_plain_checkout_refuses
test_escaping_task_ids_refuse
test_prepare_creates_without_clobbering
test_symlinked_grant_path_refuses

echo "# all fm-codex-workspace-write tests passed"
