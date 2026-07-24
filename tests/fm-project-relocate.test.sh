#!/usr/bin/env bash
# Focused behavior tests for the guarded, rename-only project relocation helper.
#
# Every fixture is a private FM_HOME below a temporary directory.
# The successful case proves the clone changes roots and only then loses its
# primary registry entry, while each refusal proves the source clone and its
# registry entry remain intact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-project-relocate.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-project-relocate.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

new_home() {
  local home
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$home/projects" "$home/data" "$home/state"
  printf '%s\n' "$home"
}

make_landed_clone() {
  local home=$1 name=$2 seed remote remote_abs clone
  seed="$home/seed-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"
  git init -q "$seed"
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  printf 'initial\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -qm initial
  git clone --quiet --bare "$seed" "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  remote_abs=$(cd "$remote" && pwd -P)
  git -C "$seed" remote add origin "file://$remote_abs"
  git -C "$seed" push -q -u origin main
  git clone --quiet "file://$remote_abs" "$clone"
  git -C "$clone" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$clone"
}

write_project_registry() {
  local home=$1 name=$2
  {
    printf -- '- %s [no-mistakes] - relocation fixture (added 2026-07-24)\n' "$name"
    printf '%s\n' '- keep [local-only] - unaffected registry entry (added 2026-07-24)'
  } > "$home/data/projects.md"
}

make_case() {
  local name=${1:-alpha} home clone
  home=$(new_home)
  clone=$(make_landed_clone "$home" "$name")
  write_project_registry "$home" "$name"
  printf '%s\t%s\n' "$home" "$clone"
}

run_relocate() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" "$@"
}

assert_refused_unchanged() {
  local home=$1 destination_root=$2 name=$3 expected=$4 label=$5 out rc
  rc=0
  out=$(run_relocate "$home" "$name" "$destination_root" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$label unexpectedly succeeded: $out"
  assert_contains "$out" "$expected" "$label did not explain its refusal"
  [ -e "$home/projects/$name" ] || [ -L "$home/projects/$name" ] \
    || fail "$label moved or removed the source clone"
  [ ! -e "$destination_root/$name" ] && [ ! -L "$destination_root/$name" ] \
    || fail "$label created the destination project path"
  assert_grep "- $name " "$home/data/projects.md" "$label changed the primary registry"
}

test_success_renames_and_removes_registry_afterward() {
  local pair home clone destination out
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  destination="$TMP_ROOT/destination-success"
  mkdir -p "$destination"

  out=$(run_relocate "$home" alpha "$destination") \
    || fail "clean landed project did not relocate"

  assert_contains "$out" "relocated alpha" "success did not report relocation"
  assert_absent "$clone" "success left the source clone behind"
  assert_present "$destination/alpha" "success did not create the destination clone"
  assert_no_grep "- alpha " "$home/data/projects.md" "success did not remove the relocated registry entry"
  assert_grep "- keep " "$home/data/projects.md" "success changed an unrelated registry entry"
  [ "$(git -C "$destination/alpha" rev-parse --show-toplevel)" = "$destination/alpha" ] \
    || fail "success did not preserve an inspectable Git clone at the destination"
  pass "clean landed project relocates by rename and then updates the primary registry"
}

test_refuses_existing_destination() {
  local pair home destination out rc
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  destination="$TMP_ROOT/destination-existing"
  mkdir -p "$destination/alpha"

  rc=0
  out=$(run_relocate "$home" alpha "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "existing destination unexpectedly succeeded"
  assert_contains "$out" "destination project path already exists" \
    "existing destination did not explain its refusal"
  assert_present "$home/projects/alpha" "existing destination moved or removed the source clone"
  assert_present "$destination/alpha" "existing destination was changed"
  assert_grep "- alpha " "$home/data/projects.md" "existing destination changed the primary registry"
  pass "existing destination refuses without moving the source clone"
}

test_refuses_symlink_source_and_destination_root() {
  local pair home clone real_source destination actual_destination
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  real_source="$home/real-alpha"
  mv "$clone" "$real_source"
  ln -s "$real_source" "$clone"
  destination="$TMP_ROOT/destination-source-symlink"
  mkdir -p "$destination"

  assert_refused_unchanged "$home" "$destination" alpha "source project must not be a symlink" \
    "symlink source"

  pair=$(make_case beta)
  home=${pair%%$'\t'*}
  actual_destination="$TMP_ROOT/destination-real"
  destination="$TMP_ROOT/destination-root-symlink"
  mkdir -p "$actual_destination"
  ln -s "$actual_destination" "$destination"

  assert_refused_unchanged "$home" "$destination" beta "destination root must not be a symlink" \
    "symlink destination root"
  pass "symlink source or destination root refuses before relocation"
}

test_refuses_linked_worktree_and_dirty_worktree() {
  local pair home clone destination linked
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  destination="$TMP_ROOT/destination-linked"
  linked="$TMP_ROOT/linked-alpha"
  mkdir -p "$destination"
  git -C "$clone" worktree add --quiet -b linked-alpha "$linked"

  assert_refused_unchanged "$home" "$destination" alpha "registered worktrees" \
    "linked worktree"

  pair=$(make_case beta)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  destination="$TMP_ROOT/destination-dirty"
  mkdir -p "$destination"
  printf 'untracked\n' > "$clone/dirty.txt"

  assert_refused_unchanged "$home" "$destination" beta "uncommitted or untracked changes" \
    "dirty worktree"
  pass "linked or dirty project clone refuses before relocation"
}

test_refuses_unpushed_and_pushed_unlanded_branches() {
  local pair home clone destination
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  destination="$TMP_ROOT/destination-unpushed"
  mkdir -p "$destination"
  git -C "$clone" commit --quiet --allow-empty -m unpushed

  assert_refused_unchanged "$home" "$destination" alpha "commits absent from every remote" \
    "unpushed commit"

  pair=$(make_case beta)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  destination="$TMP_ROOT/destination-unlanded"
  mkdir -p "$destination"
  git -C "$clone" checkout --quiet -b feature
  git -C "$clone" commit --quiet --allow-empty -m pushed-but-unlanded
  git -C "$clone" push --quiet -u origin feature
  git -C "$clone" checkout --quiet main

  assert_refused_unchanged "$home" "$destination" beta "local branch feature is not landed on origin/main" \
    "pushed unlanded branch"
  pass "unpushed and pushed-but-unlanded commits both refuse relocation"
}

test_refuses_unlanded_tags_and_stashes() {
  local pair home clone destination
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  destination="$TMP_ROOT/destination-tag"
  mkdir -p "$destination"
  git -C "$clone" commit --quiet --allow-empty -m tag-retained
  git -C "$clone" tag local-retained
  git -C "$clone" reset --quiet --hard origin/main

  assert_refused_unchanged "$home" "$destination" alpha "commits absent from every remote" \
    "unlanded local tag"

  pair=$(make_case beta)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  destination="$TMP_ROOT/destination-stash"
  mkdir -p "$destination"
  printf 'stashed\n' > "$clone/stashed.txt"
  git -C "$clone" stash push --quiet --include-untracked -m local-retained

  assert_refused_unchanged "$home" "$destination" beta "commits absent from every remote" \
    "unlanded stash"
  pass "unlanded local tags and stashes both refuse relocation"
}

test_refuses_root_replacement_and_busy_registry() {
  local pair home destination fakebin real_python replacement out rc
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  destination="$TMP_ROOT/destination-root-race"
  fakebin="$TMP_ROOT/fake-python"
  replacement="$TMP_ROOT/replacement-projects"
  real_python=$(command -v python3)
  mkdir -p "$destination" "$fakebin" "$replacement"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'mv "$RELOCATE_RACE_ROOT" "$RELOCATE_RACE_ROOT.original"' \
    'ln -s "$RELOCATE_RACE_REPLACEMENT" "$RELOCATE_RACE_ROOT"' \
    'exec "$RELOCATE_REAL_PYTHON" "$@"' \
    > "$fakebin/python3"
  chmod +x "$fakebin/python3"

  rc=0
  out=$(PATH="$fakebin:$PATH" \
    RELOCATE_RACE_ROOT="$home/projects" \
    RELOCATE_RACE_REPLACEMENT="$replacement" \
    RELOCATE_REAL_PYTHON="$real_python" \
    run_relocate "$home" alpha "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "root replacement unexpectedly succeeded"
  assert_contains "$out" "source or destination root changed before rename" \
    "root replacement did not explain its refusal"
  assert_present "$home/projects.original/alpha" "root replacement moved the source clone"
  assert_absent "$destination/alpha" "root replacement created a destination clone"
  assert_grep "- alpha " "$home/data/projects.md" "root replacement changed the primary registry"

  pair=$(make_case beta)
  home=${pair%%$'\t'*}
  destination="$TMP_ROOT/destination-registry-lock"
  mkdir -p "$destination" "$home/data/.fm-project-relocate.projects.lock"

  assert_refused_unchanged "$home" "$destination" beta "project registry is busy" \
    "busy project registry"
  pass "root replacement and a busy project registry refuse relocation"
}

test_refuses_task_and_secondmate_references() {
  local pair home clone destination source_abs
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  clone=${pair#*$'\t'}
  destination="$TMP_ROOT/destination-task-reference"
  mkdir -p "$destination"
  source_abs=$(cd "$clone" && pwd -P)
  printf 'project=%s\n' "$source_abs" > "$home/state/inflight.meta"

  assert_refused_unchanged "$home" "$destination" alpha "task metadata references this project" \
    "task metadata reference"

  pair=$(make_case beta)
  home=${pair%%$'\t'*}
  destination="$TMP_ROOT/destination-secondmate-reference"
  mkdir -p "$destination"
  printf '%s\n' \
    '- design - design work (home: /tmp/design; scope: design; projects: other, beta; added 2026-07-24)' \
    > "$home/data/secondmates.md"

  assert_refused_unchanged "$home" "$destination" beta "registered secondmate design references project beta" \
    "registered secondmate reference"
  pass "task metadata and registered secondmate references both block relocation"
}

test_refuses_traversal_duplicate_registry_and_gate_agent() {
  local pair home destination out rc
  pair=$(make_case alpha)
  home=${pair%%$'\t'*}
  destination="$TMP_ROOT/destination-traversal"
  mkdir -p "$destination"
  rc=0
  out=$(run_relocate "$home" ../alpha "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "project-name traversal unexpectedly succeeded"
  assert_contains "$out" "project name must be one plain projects/ entry" \
    "project-name traversal did not refuse clearly"
  assert_present "$home/projects/alpha" "project-name traversal changed the source clone"

  {
    printf '%s\n' '- alpha - duplicate one (added 2026-07-24)'
    printf '%s\n' '- alpha - duplicate two (added 2026-07-24)'
  } > "$home/data/projects.md"
  assert_refused_unchanged "$home" "$destination" alpha "project registry has 2 entries" \
    "duplicate project registry"

  write_project_registry "$home" alpha
  rc=0
  out=$(env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT" alpha "$destination" 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "no-mistakes gate agent was not refused with exit 3: $out"
  assert_contains "$out" "NO_MISTAKES_GATE set" "gate-agent refusal did not explain the boundary"
  assert_present "$home/projects/alpha" "gate-agent refusal changed the source clone"
  assert_absent "$destination/alpha" "gate-agent refusal created a destination clone"
  pass "traversal, registry ambiguity, and no-mistakes gate context refuse without relocation"
}

test_success_renames_and_removes_registry_afterward
test_refuses_existing_destination
test_refuses_symlink_source_and_destination_root
test_refuses_linked_worktree_and_dirty_worktree
test_refuses_unpushed_and_pushed_unlanded_branches
test_refuses_unlanded_tags_and_stashes
test_refuses_root_replacement_and_busy_registry
test_refuses_task_and_secondmate_references
test_refuses_traversal_duplicate_registry_and_gate_agent
