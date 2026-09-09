#!/usr/bin/env bash
# Behavior tests for bin/fm-project-local.sh.
#
# The point of the store is that material a worker must read never becomes a
# commit, so the assertions drive real git: material is staged into a real
# worktree and then `git add -A` has to leave nothing staged. An instruction in
# a brief cannot be tested; this can.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-local)

git_q() { git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

make_world() {  # <name>
  local name=$1 world="$TMP_ROOT/$1"
  mkdir -p "$world/home/data" "$world/material-src"
  git_q init -q "$world/copy"
  printf '# %s\n' "$name" >"$world/copy/README.md"
  git_q -C "$world/copy" add README.md
  git_q -C "$world/copy" commit -qm initial
  printf '%s\n' "$world"
}

local_cmd() {  # <world> <args...>
  local world=$1
  shift
  FM_HOME="$world/home" "$ROOT/bin/fm-project-local.sh" "$@" 2>&1
}

# Push every mtime in a fixture well into the past, so "nothing changed
# recently" is a fact about the fixture rather than a race with the suite.
age_tree() {  # <dir>
  find "$1" -exec touch -t 202001010000.00 {} + 2>/dev/null || true
}

# The canonical home is shared: the captain works in it while a sync reads it,
# so a file can be caught mid-write. The sync still succeeds - the store is a
# private cache and re-running is free - but it must say so.
test_sync_reports_a_home_that_was_being_worked_while_it_was_read() {
  local world out
  world=$(make_world concurrent)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  printf 'operational context\n' >"$world/canonical/CLAUDE.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'CLAUDE.md\n' >"$world/home/data/project-local/demo/manifest"

  out=$(local_cmd "$world" sync demo) || fail "sync failed while the home was in use: $out"
  assert_contains "$out" "synced:" "the sync did not complete"
  assert_contains "$out" "was being worked in while this copy was taken" \
    "the sync said nothing about reading a folder someone was writing"

  age_tree "$world/canonical"
  out=$(local_cmd "$world" sync demo) || fail "sync failed on a quiet home: $out"
  assert_not_contains "$out" "was being worked in while this copy was taken" \
    "a quiet home still produced a concurrency warning"
  pass "fm-project-local.sh: sync reports a home that was being worked while it was read"
}

# A failed activity check is not an observation. When the check itself cannot
# run, sync says the answer is unknown rather than claiming it saw someone
# working in the folder.
test_sync_says_when_activity_could_not_be_determined() {
  local world out
  world=$(make_world undetermined)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  printf 'operational context\n' >"$world/canonical/CLAUDE.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'CLAUDE.md\n' >"$world/home/data/project-local/demo/manifest"
  age_tree "$world/canonical"

  # The activity check needs a scratch file; a scratch directory that does not
  # exist makes it fail outright without touching the sync's own copying.
  out=$(FM_HOME="$world/home" TMPDIR="$world/no-such-dir" "$ROOT/bin/fm-project-local.sh" sync demo 2>&1) ||
    fail "sync failed when the activity check could not run: $out"
  assert_contains "$out" "synced:" "the sync did not complete"
  assert_contains "$out" "could not determine whether" "a failed activity check was not reported as unknown"
  assert_not_contains "$out" "was being worked in while this copy was taken" \
    "a failed activity check was reported as activity observed"
  pass "fm-project-local.sh: sync says when activity could not be determined"
}

test_staged_material_is_readable_and_cannot_be_committed() {
  local world out staged
  world=$(make_world stage)
  printf 'the fuller operational context\n' >"$world/material-src/CLAUDE.md"
  mkdir -p "$world/material-src/notes"
  printf 'a finding nobody committed\n' >"$world/material-src/notes/audit.md"
  local_cmd "$world" add demo "$world/material-src/CLAUDE.md" >/dev/null || fail "add failed"
  local_cmd "$world" add demo "$world/material-src/notes" --as notes >/dev/null || fail "add of a directory failed"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "stage failed: $out"

  staged="$world/copy/.fm-local"
  assert_present "$staged/CLAUDE.md" "staged material is missing from the task copy"
  assert_present "$staged/notes/audit.md" "staged directory material is missing from the task copy"
  assert_grep "the fuller operational context" "$staged/CLAUDE.md" "staged material is not readable"
  assert_present "$staged/README.md" "the staged material carries no explanation for the worker"

  out=$(git_q -C "$world/copy" status --porcelain --untracked-files=all)
  [ -z "$out" ] || fail "git can see the staged material: $out"
  git_q -C "$world/copy" add -A
  out=$(git_q -C "$world/copy" diff --cached --name-only)
  [ -z "$out" ] || fail "git add -A staged local material for commit: $out"
  pass "fm-project-local.sh: staged material is readable and invisible to git"
}

test_stage_refuses_when_the_project_tracks_the_destination() {
  local world out rc
  world=$(make_world tracked)
  mkdir -p "$world/copy/.fm-local"
  printf 'committed\n' >"$world/copy/.fm-local/real.txt"
  git_q -C "$world/copy" add -f .fm-local/real.txt
  git_q -C "$world/copy" commit -qm "project tracks the path"
  printf 'material\n' >"$world/material-src/note.md"
  local_cmd "$world" add demo "$world/material-src/note.md" >/dev/null || fail "add failed"
  out=$(local_cmd "$world" stage demo "$world/copy") && rc=0 || rc=$?
  expect_code 1 "$rc" "staging over a tracked path was accepted"
  assert_contains "$out" "tracks" "the refusal did not name the tracked path"
  assert_grep "committed" "$world/copy/.fm-local/real.txt" "the refused stage clobbered the project's own file"
  pass "fm-project-local.sh: staging over a tracked path is refused"
}

test_an_empty_store_stages_nothing() {
  local world out
  world=$(make_world empty)
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "staging an empty store failed: $out"
  assert_absent "$world/copy/.fm-local" "an empty store still created a staged directory"
  pass "fm-project-local.sh: an empty store stages nothing and succeeds"
}

test_sync_pulls_the_manifest_from_the_canonical_home_without_writing_to_it() {
  local world out before after
  world=$(make_world sync)
  mkdir -p "$world/home/config/project-sources" "$world/home/projects"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  printf 'operational context\n' >"$world/canonical/CLAUDE.md"
  mkdir -p "$world/canonical/herramientas"
  printf 'tool\n' >"$world/canonical/herramientas/replay.py"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  mkdir -p "$world/home/data/project-local/demo"
  printf '# what the workers need\nCLAUDE.md\nherramientas\n' >"$world/home/data/project-local/demo/manifest"

  before=$(cd "$world/canonical" && find . -print | LC_ALL=C sort)
  out=$(local_cmd "$world" sync demo) || fail "sync failed: $out"
  after=$(cd "$world/canonical" && find . -print | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "sync modified the canonical home"

  out=$(local_cmd "$world" list demo)
  assert_contains "$out" "CLAUDE.md" "sync did not pull the manifest file"
  assert_contains "$out" "herramientas/replay.py" "sync did not pull the manifest directory"
  pass "fm-project-local.sh: sync pulls the manifest and leaves the canonical home alone"
}

test_sync_refuses_an_escaping_manifest_path() {
  local world out rc
  world=$(make_world escape)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf '../outside.md\n' >"$world/home/data/project-local/demo/manifest"
  out=$(local_cmd "$world" sync demo) && rc=0 || rc=$?
  expect_code 1 "$rc" "a manifest path escaping the project was accepted"
  assert_contains "$out" "safe relative path" "the refusal did not name the cause"
  pass "fm-project-local.sh: a manifest path that escapes the project is refused"
}

test_a_symlink_never_enters_the_store() {
  local world out rc
  world=$(make_world symlink)
  printf 'real\n' >"$world/material-src/real.md"
  ln -s "$world/material-src/real.md" "$world/material-src/link.md"
  out=$(local_cmd "$world" add demo "$world/material-src/link.md") && rc=0 || rc=$?
  expect_code 1 "$rc" "a symlink was accepted into the store"
  assert_contains "$out" "symlink" "the refusal did not name the symlink"
  pass "fm-project-local.sh: a symlink is refused rather than stored"
}

# A symlink nested inside an added directory must be refused BEFORE the tree is
# copied: a refusal that left the symlink in the store would make every later
# stage - and with it every spawn of the project - fail until someone cleaned
# the store by hand. herramientas/ with a Python venv inside is the real case.
test_a_nested_symlink_is_refused_before_it_poisons_the_store() {
  local world out rc
  world=$(make_world nested)
  mkdir -p "$world/material-src/tools/venv/bin"
  printf 'tool\n' >"$world/material-src/tools/replay.py"
  printf 'interp\n' >"$world/material-src/tools/venv/bin/python3"
  ln -s python3 "$world/material-src/tools/venv/bin/python"
  out=$(local_cmd "$world" add demo "$world/material-src/tools" --as tools) && rc=0 || rc=$?
  expect_code 1 "$rc" "a directory holding a nested symlink was accepted into the store"
  assert_contains "$out" "symlink" "the refusal did not name the symlink"
  [ -z "$(find "$world/home/data/project-local" -type l 2>/dev/null)" ] ||
    fail "the refused add left a symlink in the store"
  out=$(local_cmd "$world" list demo)
  assert_not_contains "$out" "tools/replay.py" "the refused add still copied the directory into the store"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "a later stage failed after the refused add: $out"
  pass "fm-project-local.sh: a nested symlink is refused before anything enters the store"
}

test_sync_refuses_a_manifest_directory_holding_a_symlink_before_copying() {
  local world out rc
  world=$(make_world nestedsync)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  mkdir -p "$world/canonical/herramientas/venv/bin"
  printf 'tool\n' >"$world/canonical/herramientas/replay.py"
  printf 'interp\n' >"$world/canonical/herramientas/venv/bin/python3"
  ln -s python3 "$world/canonical/herramientas/venv/bin/python"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'herramientas\n' >"$world/home/data/project-local/demo/manifest"
  out=$(local_cmd "$world" sync demo) && rc=0 || rc=$?
  expect_code 1 "$rc" "sync copied a manifest directory holding a nested symlink"
  assert_contains "$out" "symlink" "the refusal did not name the symlink"
  [ -z "$(find "$world/home/data/project-local" -type l 2>/dev/null)" ] ||
    fail "the refused sync left a symlink in the store"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "a later stage failed after the refused sync: $out"
  pass "fm-project-local.sh: sync refuses a manifest directory holding a symlink before copying it"
}

test_staged_material_is_removed_and_refused_when_git_can_still_see_it() {
  local world out rc
  world=$(make_world visible)
  printf 'material\n' >"$world/material-src/note.md"
  local_cmd "$world" add demo "$world/material-src/note.md" >/dev/null || fail "add failed"
  # A project that force-includes the staged path defeats the exclude entry, so
  # the post-stage verification is the only thing standing between the worker
  # and a commit of this material.
  printf '!.fm-local/\n!.fm-local/**\n' >"$world/copy/.gitignore"
  git_q -C "$world/copy" add .gitignore
  git_q -C "$world/copy" commit -qm "force-include the staged path"
  out=$(local_cmd "$world" stage demo "$world/copy") && rc=0 || rc=$?
  expect_code 1 "$rc" "staging succeeded while git could still see the material"
  assert_absent "$world/copy/.fm-local" "the refused stage left committable material behind"
  pass "fm-project-local.sh: material git can still see is removed and the stage refused"
}

test_stage_is_a_no_op_for_a_project_name_no_store_can_address() {
  local world out rc
  world=$(make_world oddname)
  out=$(local_cmd "$world" stage "odd name/with slash" "$world/copy") && rc=0 || rc=$?
  expect_code 0 "$rc" "a project whose name no store can address failed its spawn-time stage"
  assert_absent "$world/copy/.fm-local" "an unaddressable project name still staged something"
  pass "fm-project-local.sh: staging is a no-op for a project name no store can address"
}

test_a_reused_copy_never_keeps_the_previous_tasks_material() {
  local world out
  world=$(make_world reused)
  printf 'first task material\n' >"$world/material-src/first.md"
  local_cmd "$world" add demo "$world/material-src/first.md" >/dev/null || fail "add failed"
  local_cmd "$world" stage demo "$world/copy" >/dev/null || fail "first stage failed"
  assert_present "$world/copy/.fm-local/first.md" "the first stage did not land"

  local_cmd "$world" remove demo first.md >/dev/null || fail "remove failed"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "second stage failed: $out"
  assert_absent "$world/copy/.fm-local" "a reused copy kept the previous task's material"
  pass "fm-project-local.sh: a reused copy never keeps the previous task's material"
}

test_staged_material_is_readable_and_cannot_be_committed
test_stage_refuses_when_the_project_tracks_the_destination
test_an_empty_store_stages_nothing
test_sync_pulls_the_manifest_from_the_canonical_home_without_writing_to_it
test_sync_refuses_an_escaping_manifest_path
test_a_symlink_never_enters_the_store
test_a_nested_symlink_is_refused_before_it_poisons_the_store
test_sync_refuses_a_manifest_directory_holding_a_symlink_before_copying
test_staged_material_is_removed_and_refused_when_git_can_still_see_it
test_a_reused_copy_never_keeps_the_previous_tasks_material
test_stage_is_a_no_op_for_a_project_name_no_store_can_address
test_sync_reports_a_home_that_was_being_worked_while_it_was_read
test_sync_says_when_activity_could_not_be_determined
