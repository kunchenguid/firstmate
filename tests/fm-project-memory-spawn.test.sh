#!/usr/bin/env bash
# Behavior tests for the spawn-time half of project memory (bin/fm-spawn.sh).
#
# Two things have to happen before a worker reads its brief: the project's
# capability digest is rendered into the launch brief, and the project's local
# material is in the task copy where git cannot see it. Both are asserted
# through a real spawn rather than by reading the scripts that implement them.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-memory-spawn)

write_catalog() {  # <dir> <heading>
  mkdir -p "$1/.agents"
  cat >"$1/.agents/recipes.md" <<EOF
# Agent recipes

## $2
- when: a lead reports the assistant misbehaved and you have the lead id
- ask: \`replay --lead <id>\`
- gives: the reproduced turn
- notes: a sharp edge the digest leaves behind
<!--r:$(date -u +%Y-%m-%d)-->
EOF
}

# A spawn world: firstmate home, a project with a real linked worktree standing
# in for the task copy, and the fake tmux/treehouse the spawn suites use.
make_world() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' >"$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id" "Exercise project memory at spawn time."
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

read_world() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN <<EOF
$1
EOF
}

run_spawn() {  # <id>
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$1" "$PROJ_DIR" --mode no-mistakes --yolo off
}

test_spawn_renders_the_project_capability_digest_into_the_launch_brief() {
  local id=capdigest-a1 out rc brief
  read_world "$(make_world capdigest "$id")"
  write_catalog "$PROJ_DIR" "Find the production bug behind one conversation"
  out=$(run_spawn "$id") && rc=0 || rc=$?
  expect_code 0 "$rc" "spawn failed: $out"
  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_present "$brief" "no launch brief was rendered"
  assert_grep "# Project capabilities" "$brief" "the launch brief carries no capability digest"
  assert_grep "Find the production bug behind one conversation" "$brief" "the digest dropped the capability name"
  assert_grep "- ask: \`replay --lead <id>\`" "$brief" "the digest dropped how the capability is asked for"
  assert_no_grep "a sharp edge the digest leaves behind" "$brief" "the digest inlined the whole catalog"
  pass "fm-spawn.sh: the project's capability digest reaches the launch brief"
}

test_spawn_reads_the_catalog_from_a_source_canonical_home() {
  local id=capsource-a1 out rc brief source
  read_world "$(make_world capsource "$id")"
  source="$TMP_ROOT/capsource/canonical"
  fm_git_init_commit "$source"
  write_catalog "$source" "A capability recorded only in the canonical checkout"
  write_catalog "$PROJ_DIR" "A stale capability the clone still carries"
  FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    "$ROOT/bin/fm-project-memory.sh" source set "$(basename "$PROJ_DIR")" "$source" --canonical source >/dev/null ||
    fail "source set failed"
  out=$(run_spawn "$id") && rc=0 || rc=$?
  expect_code 0 "$rc" "spawn failed: $out"
  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_grep "A capability recorded only in the canonical checkout" "$brief" \
    "the digest did not come from the project's canonical home"
  assert_no_grep "A stale capability the clone still carries" "$brief" \
    "the digest came from the clone despite a canonical source checkout"
  pass "fm-spawn.sh: the capability digest comes from the project's canonical home"
}

test_spawn_stages_local_material_where_git_cannot_see_it() {
  local id=material-a1 out rc project
  read_world "$(make_world material "$id")"
  project=$(basename "$PROJ_DIR")
  mkdir -p "$TMP_ROOT/material/src"
  printf 'the fuller operational context\n' >"$TMP_ROOT/material/src/CLAUDE.md"
  FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$ROOT/bin/fm-project-local.sh" add "$project" "$TMP_ROOT/material/src/CLAUDE.md" >/dev/null ||
    fail "adding local material failed"
  out=$(run_spawn "$id") && rc=0 || rc=$?
  expect_code 0 "$rc" "spawn failed: $out"
  assert_present "$WT_DIR/.fm-local/CLAUDE.md" "local material did not reach the task copy"
  assert_grep "the fuller operational context" "$WT_DIR/.fm-local/CLAUDE.md" "staged material is not readable"
  out=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  [ -z "$out" ] || fail "git can see the material staged into the task copy: $out"
  pass "fm-spawn.sh: local material reaches the task copy and stays invisible to git"
}

test_a_project_with_neither_costs_nothing() {
  local id=plain-a1 out rc brief
  read_world "$(make_world plain "$id")"
  out=$(run_spawn "$id") && rc=0 || rc=$?
  expect_code 0 "$rc" "spawn failed for a project with no catalog and no material: $out"
  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_no_grep "# Project capabilities" "$brief" "an empty catalog still added a digest section"
  assert_absent "$WT_DIR/.fm-local" "an empty store still created a staged directory"
  pass "fm-spawn.sh: a project with no catalog and no material spawns unchanged"
}

test_spawn_renders_the_project_capability_digest_into_the_launch_brief
test_spawn_reads_the_catalog_from_a_source_canonical_home
test_spawn_stages_local_material_where_git_cannot_see_it
test_a_project_with_neither_costs_nothing
