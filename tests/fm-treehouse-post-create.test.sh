#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=

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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-post-create-tests.XXXXXX")

create_project() {
  local home=$1 project=$2 clone
  clone="$home/projects/$project"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  git init -q "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name Test
  printf '%s\n' initial >"$clone/file.txt"
  git -C "$clone" add file.txt
  git -C "$clone" commit -q -m initial
  printf '%s\n' "$clone"
}

create_worktree() {
  local clone=$1 path=$2
  git -C "$clone" worktree add -q --detach "$path" HEAD
}

write_setup() {
  local data=$1 project=$2 marker=$3
  cat >"$data/$project-setup.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$(pwd)" >"$marker"
SH
  chmod +x "$data/$project-setup.sh"
}

test_hook_runs_for_matching_project_worktree() {
  local home clone worktree marker expected
  home="$TMP_ROOT/matching/home"
  clone=$(create_project "$home" app)
  worktree="$TMP_ROOT/matching/app"
  create_worktree "$clone" "$worktree"
  marker="$TMP_ROOT/matching/ran"
  write_setup "$home/data" app "$marker"

  (cd "$worktree" && FM_HOME="$home" "$ROOT/bin/fm-treehouse-post-create.sh") \
    || fail "hook failed for matching worktree"
  expected=$(cd "$worktree" && pwd)
  [ "$(cat "$marker" 2>/dev/null)" = "$expected" ] \
    || fail "hook did not run setup in matching worktree"
  [ -f "$home/state/treehouse-setup-app.log" ] \
    || fail "hook did not write matching setup log"
  pass "hook runs setup for matching project worktree"
}

test_hook_skips_same_basename_different_repo() {
  local home clone unrelated worktree marker
  home="$TMP_ROOT/collision/home"
  clone=$(create_project "$home" app)
  unrelated="$TMP_ROOT/collision/unrelated-source"
  git init -q "$unrelated"
  git -C "$unrelated" config user.email test@example.com
  git -C "$unrelated" config user.name Test
  printf '%s\n' unrelated >"$unrelated/file.txt"
  git -C "$unrelated" add file.txt
  git -C "$unrelated" commit -q -m initial
  worktree="$TMP_ROOT/collision/app"
  create_worktree "$unrelated" "$worktree"
  marker="$TMP_ROOT/collision/ran"
  write_setup "$home/data" app "$marker"
  [ -d "$clone" ] || fail "test project clone missing"

  (cd "$worktree" && FM_HOME="$home" "$ROOT/bin/fm-treehouse-post-create.sh") \
    || fail "hook failed while skipping colliding worktree"
  [ ! -e "$marker" ] || fail "hook ran setup for colliding basename"
  pass "hook skips same-basename worktree from a different repo"
}

test_hook_uses_data_override() {
  local home data clone worktree marker expected
  home="$TMP_ROOT/data-override/home"
  data="$TMP_ROOT/data-override/data"
  clone=$(create_project "$home" app)
  mkdir -p "$data"
  worktree="$TMP_ROOT/data-override/app"
  create_worktree "$clone" "$worktree"
  marker="$TMP_ROOT/data-override/ran"
  write_setup "$data" app "$marker"

  (cd "$worktree" && FM_HOME="$home" FM_DATA_OVERRIDE="$data" "$ROOT/bin/fm-treehouse-post-create.sh") \
    || fail "hook failed with data override"
  expected=$(cd "$worktree" && pwd)
  [ "$(cat "$marker" 2>/dev/null)" = "$expected" ] \
    || fail "hook did not run setup from data override"
  pass "hook uses FM_DATA_OVERRIDE"
}

test_hook_runs_for_matching_project_worktree
test_hook_skips_same_basename_different_repo
test_hook_uses_data_override
