#!/usr/bin/env bash
# Tests for per-project captain preferences (data/captain-projects/<project>.md):
# bin/fm-project-prefs.sh's show/path/list contract and name rule, the readers
# that surface it (bin/fm-brief.sh for ship and scout scaffolds and
# bin/fm-review-diff.sh, a ship or scout spawn's dispatch notice, and
# bin/fm-merge-local.sh), and the guarantee that the startup memory budget never
# counts it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

PREFS="$ROOT/bin/fm-project-prefs.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-prefs)
HOME_DIR="$TMP_ROOT/home"
PREFS_DIR="$HOME_DIR/data/captain-projects"
mkdir -p "$PREFS_DIR" "$HOME_DIR/state" "$HOME_DIR/config"

printf '%s\n' '- Rule one for the alpha project.' '- Rule two: never skip design approval.' > "$PREFS_DIR/alpha.md"
printf '%s\n' '- Spaced project rule.' > "$PREFS_DIR/spaced name.md"

run_prefs() {
  FM_HOME="$HOME_DIR" "$PREFS" "$@"
}

test_show_prints_header_and_content() {
  local out rc
  out=$(run_prefs show alpha 2>&1); rc=$?
  expect_code 0 "$rc" "show alpha should exit 0"
  assert_contains "$out" "Per-project captain preferences for alpha" "show must name the project in a header"
  assert_contains "$out" "$PREFS_DIR/alpha.md" "show must name the file path in its header"
  assert_contains "$out" "Rule two: never skip design approval." "show must print the file content"
  assert_contains "$out" "End per-project captain preferences for alpha" "show must close the block"
  out=$(run_prefs show "spaced name" 2>&1); rc=$?
  expect_code 0 "$rc" "a registry name containing spaces should resolve"
  assert_contains "$out" "Spaced project rule." "a spaced project name must print its file"
  pass "fm-project-prefs.sh: show prints a headed block for the named project"
}

test_absent_project_is_silent() {
  local out rc
  out=$(run_prefs show no-such-project 2>&1); rc=$?
  expect_code 0 "$rc" "show for a project with no file should exit 0"
  [ -z "$out" ] || fail "show for a project with no file must print nothing (got: $out)"
  out=$(run_prefs path no-such-project 2>&1); rc=$?
  expect_code 1 "$rc" "path for a project with no file should exit 1"
  [ -z "$out" ] || fail "path for a project with no file must print nothing (got: $out)"
  out=$(FM_HOME="$TMP_ROOT/empty-home" "$PREFS" show alpha 2>&1); rc=$?
  expect_code 0 "$rc" "a home with no captain-projects directory should exit 0"
  [ -z "$out" ] || fail "a home with no captain-projects directory must print nothing"
  pass "fm-project-prefs.sh: a project without a file is silent for show and exit 1 for path"
}

test_path_and_list() {
  local out
  out=$(run_prefs path alpha 2>&1) || fail "path alpha should exit 0"
  assert_equals "$PREFS_DIR/alpha.md" "$out" "path must print the file path"
  out=$(run_prefs list 2>&1) || fail "list should exit 0"
  assert_equals "alpha
spaced name" "$out" "list must print every project with a file, sorted"
  out=$(FM_HOME="$TMP_ROOT/empty-home" "$PREFS" list 2>&1) || fail "list on an empty home should exit 0"
  [ -z "$out" ] || fail "list on a home with no files must print nothing"
  pass "fm-project-prefs.sh: path and list report the files that exist"
}

test_invalid_names_and_unsafe_files() {
  local out rc name
  for name in "../alpha" "a/b" ".hidden" "-flag" ""; do
    out=$(run_prefs show "$name" 2>&1); rc=$?
    expect_code 2 "$rc" "show '$name' should be a usage-class refusal"
    assert_contains "$out" "invalid project name" "show '$name' must explain the refusal"
  done
  printf 'secret\n' > "$TMP_ROOT/outside.md"
  ln -s "$TMP_ROOT/outside.md" "$PREFS_DIR/linked.md"
  out=$(run_prefs show linked 2>&1); rc=$?
  expect_code 3 "$rc" "a symlinked project file should be refused"
  assert_contains "$out" "must be a readable regular file" "a symlinked file refusal must name the requirement"
  assert_not_contains "$out" "secret" "a refused symlink must never be read"
  mkdir "$PREFS_DIR/dirfile.md"
  out=$(run_prefs path dirfile 2>&1); rc=$?
  expect_code 3 "$rc" "a directory in place of the file should be refused"
  rmdir "$PREFS_DIR/dirfile.md"
  rm -f "$PREFS_DIR/linked.md"
  run_prefs bogus >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown subcommand should be a usage error"
  pass "fm-project-prefs.sh: invalid names and non-regular files are refused loudly"
}

test_show_task_resolves_project_from_meta() {
  local out rc
  fm_write_meta "$HOME_DIR/state/task-p1.meta" "window=fm-task-p1" "project=$TMP_ROOT/projects/alpha"
  out=$(run_prefs show --task task-p1 2>&1); rc=$?
  expect_code 0 "$rc" "show --task should exit 0"
  assert_contains "$out" "Rule one for the alpha project." "show --task must print the task project's file"
  out=$(run_prefs show --task missing-task 2>&1); rc=$?
  expect_code 1 "$rc" "show --task for an unknown task should fail"
  assert_contains "$out" "no meta for task" "show --task must say the task record is missing"
  pass "fm-project-prefs.sh: show --task resolves the project from the task record"
}

test_brief_prints_project_prefs() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-alpha-s1 alpha --mode no-mistakes 2>&1); rc=$?
  expect_code 0 "$rc" "a ship scaffold for a project with preferences should exit 0"
  assert_contains "$out" "scaffolded: $HOME_DIR/data/brief-alpha-s1/brief.md" "the scaffold line must still print"
  assert_contains "$out" "Rule two: never skip design approval." "a ship scaffold must print the project's preferences"
  assert_not_contains "$(cat "$HOME_DIR/data/brief-alpha-s1/brief.md")" "never skip design approval" \
    "the scaffold must print the preferences for firstmate, not write them into the brief itself"

  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-alpha-s2 alpha --scout 2>&1); rc=$?
  expect_code 0 "$rc" "a scout scaffold for a project with preferences should exit 0"
  assert_contains "$out" "Rule one for the alpha project." "a scout scaffold must print the project's preferences"

  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-beta-s3 beta --mode no-mistakes 2>&1); rc=$?
  expect_code 0 "$rc" "a scaffold for a project without preferences should exit 0"
  assert_not_contains "$out" "Per-project captain preferences" "a project without a file must print no preference block"

  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-alpha-s4 projects/alpha --mode direct-PR 2>&1); rc=$?
  expect_code 0 "$rc" "a repo argument carrying a directory prefix should still resolve its project"
  assert_contains "$out" "Rule two: never skip design approval." "the project name is the repo argument's final component"
  pass "fm-brief.sh: ship and scout scaffolds print the project's preferences, others stay silent"
}

test_brief_refuses_unreadable_prefs_before_writing() {
  local out rc
  printf 'x\n' > "$TMP_ROOT/target.md"
  ln -s "$TMP_ROOT/target.md" "$PREFS_DIR/gamma.md"
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" brief-gamma-s5 gamma --mode no-mistakes 2>&1); rc=$?
  expect_code 1 "$rc" "an unreadable preferences file must stop the scaffold"
  assert_contains "$out" "could not read the per-project captain preferences for gamma" "the refusal must name the project"
  assert_absent "$HOME_DIR/data/brief-gamma-s5/brief.md" "a refused scaffold must not leave a brief behind"
  rm -f "$PREFS_DIR/gamma.md"
  pass "fm-brief.sh: an unreadable preferences file stops the scaffold before a brief exists"
}

test_review_diff_prints_project_prefs() {
  local case_dir out rc
  case_dir="$TMP_ROOT/review"
  mkdir -p "$case_dir/state" "$case_dir/data/captain-projects"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/reviewed"
  git -C "$case_dir/reviewed" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/reviewed" worktree add -q -b fm/task-r1 "$case_dir/wt" main
  printf 'change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" commit -qam "task change"
  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-r1.meta" \
    "window=fm-task-r1" "worktree=$case_dir/wt" "project=$case_dir/reviewed"

  out=$(FM_HOME="$case_dir" "$ROOT/bin/fm-review-diff.sh" task-r1 --stat 2>&1); rc=$?
  expect_code 0 "$rc" "a review of a project without preferences should exit 0"
  assert_not_contains "$out" "Per-project captain preferences" "a project without a file must print no preference block in review"

  printf '%s\n' '- Reviewed-project rule: check the checklist.' > "$case_dir/data/captain-projects/reviewed.md"
  out=$(FM_HOME="$case_dir" "$ROOT/bin/fm-review-diff.sh" task-r1 --stat 2>&1); rc=$?
  expect_code 0 "$rc" "a review of a project with preferences should exit 0"
  assert_contains "$out" "Reviewed-project rule: check the checklist." "a review must print the project's preferences"
  assert_contains "$out" "diff base:" "the review diff must still follow the preferences"
  pass "fm-review-diff.sh: a review prints the project's preferences before the diff"
}

test_memory_budget_ignores_project_prefs() {
  local before after bytes tokens status
  printf '%s\n' '- A captain preference.' > "$HOME_DIR/data/captain.md"
  printf '30\n' > "$HOME_DIR/config/startup-memory-budget"
  bytes=$(wc -c < "$HOME_DIR/data/captain.md" | tr -d ' ')
  tokens=$(( (bytes + 2) / 3 ))
  before=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-startup-memory-budget.sh" report 2>&1); status=$?
  expect_code 0 "$status" "the budget report should succeed on the fixture"$'\n'"$before"
  assert_contains "$before" "file=data/captain.md bytes=$bytes estimated_tokens=$tokens status=present" \
    "the report must size captain.md from its own bytes"
  assert_contains "$before" "total_estimated_tokens=$tokens" "the report total must be captain.md's estimate alone"
  head -c 20000 /dev/zero | tr '\0' 'x' > "$PREFS_DIR/huge.md"
  after=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-startup-memory-budget.sh" report 2>&1); status=$?
  rm -f "$PREFS_DIR/huge.md"
  expect_code 0 "$status" "the budget report should still succeed with a per-project file present"$'\n'"$after"
  assert_equals "$before" "$after" "a per-project file must not change the startup memory budget report"
  assert_contains "$after" "budget_status=within-budget" "a 20000-byte per-project file must not push startup memory over budget"
  pass "fm-startup-memory-budget.sh: per-project files are never counted"
}

test_spawn_names_project_prefs_at_dispatch() {
  local case_dir home project pool fakebin id out status
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  project="$case_dir/prefproj"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf -- '- prefproj [direct-PR] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
  touch "$home/state/.last-watcher-beat"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -qm initial
  git -C "$project" worktree add --quiet --detach "$pool" "$(git -C "$project" rev-parse HEAD)"

  id=prefs-spawn-a1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" prefproj --mode direct-PR >/dev/null 2>&1 \
    || fail "could not scaffold the spawn fixture brief"
  sed -i.bak -e 's/{TASK}/Fixture ask./' -e 's/{FIRSTMATE_SPEC}/Fixture spec./' "$home/data/$id/brief.md"
  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --mode direct-PR --yolo off 2>&1); status=$?
  expect_code 0 "$status" "a spawn without project preferences should launch"$'\n'"$out"
  assert_not_contains "$out" "per-project captain preferences" "a project without a file must get no dispatch notice"

  id=prefs-spawn-a2
  mkdir -p "$home/data/captain-projects"
  printf '%s\n' '- Fixture project rule.' > "$home/data/captain-projects/prefproj.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" prefproj --mode direct-PR >/dev/null 2>&1 \
    || fail "could not scaffold the second spawn fixture brief"
  sed -i.bak -e 's/{TASK}/Fixture ask./' -e 's/{FIRSTMATE_SPEC}/Fixture spec./' "$home/data/$id/brief.md"
  git -C "$project" worktree remove --force "$pool" >/dev/null 2>&1 || true
  git -C "$project" worktree add --quiet --detach "$pool" "$(git -C "$project" rev-parse HEAD)"
  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --mode direct-PR --yolo off 2>&1); status=$?
  expect_code 0 "$status" "a spawn with project preferences should launch"$'\n'"$out"
  assert_contains "$out" "prefproj has per-project captain preferences in $home/data/captain-projects/prefproj.md" \
    "a ship dispatch must name the project's preferences file"
  pass "fm-spawn.sh: a ship dispatch names the project's preferences file, and only when one exists"

  id=prefs-spawn-a3
  rm -f "$home/data/captain-projects/prefproj.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" prefproj --mode direct-PR >/dev/null 2>&1 \
    || fail "could not scaffold the unreadable-preferences spawn fixture brief"
  sed -i.bak -e 's/{TASK}/Fixture ask./' -e 's/{FIRSTMATE_SPEC}/Fixture spec./' "$home/data/$id/brief.md"
  printf 'x\n' > "$case_dir/target.md"
  ln -s "$case_dir/target.md" "$home/data/captain-projects/prefproj.md"
  git -C "$project" worktree remove --force "$pool" >/dev/null 2>&1 || true
  git -C "$project" worktree add --quiet --detach "$pool" "$(git -C "$project" rev-parse HEAD)"
  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --mode direct-PR --yolo off 2>&1); status=$?
  expect_code 0 "$status" "an unreadable preferences file must warn without blocking the dispatch"$'\n'"$out"
  assert_contains "$out" "could not read the per-project captain preferences for prefproj" \
    "an unreadable preferences file must be reported at dispatch, not treated as none"
  assert_not_contains "$out" "has per-project captain preferences" "an unreadable file must not read as a clean notice"
  rm -f "$home/data/captain-projects/prefproj.md"
  pass "fm-spawn.sh: an unreadable preferences file warns at dispatch instead of passing silently"
}

test_spawn_names_project_prefs_for_scout() {
  local case_dir home project pool fakebin id out status
  case_dir="$TMP_ROOT/spawn-scout"
  home="$case_dir/home"
  project="$case_dir/scoutproj"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/captain-projects" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf -- '- scoutproj [direct-PR] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
  printf '%s\n' '- Scout fixture rule.' > "$home/data/captain-projects/scoutproj.md"
  touch "$home/state/.last-watcher-beat"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -qm initial
  git -C "$project" worktree add --quiet --detach "$pool" "$(git -C "$project" rev-parse HEAD)"

  id=prefs-scout-b1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" scoutproj --scout >/dev/null 2>&1 \
    || fail "could not scaffold the scout spawn fixture brief"
  sed -i.bak -e 's/{TASK}/Fixture ask./' -e 's/{FIRSTMATE_SPEC}/Fixture spec./' "$home/data/$id/brief.md"
  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --scout 2>&1); status=$?
  expect_code 0 "$status" "a scout spawn with project preferences should launch"$'\n'"$out"
  assert_contains "$out" "scoutproj has per-project captain preferences in $home/data/captain-projects/scoutproj.md" \
    "a scout dispatch must name the project's preferences file"
  pass "fm-spawn.sh: a scout dispatch names the project's preferences file"
}

make_local_merge_fixture() { # <case-dir> <id> -> prints the project path
  local case_dir=$1 id=$2 proj="$1/proj" main
  mkdir -p "$case_dir/home/state" "$case_dir/home/data"
  git init -q "$proj"
  git -C "$proj" config user.email test@example.com
  git -C "$proj" config user.name test
  printf 'base\n' > "$proj/base"
  git -C "$proj" add base
  git -C "$proj" commit -qm base
  main=$(git -C "$proj" branch --show-current)
  git -C "$proj" checkout -qb "fm/$id"
  printf 'change\n' > "$proj/change"
  git -C "$proj" add change
  git -C "$proj" commit -qm change
  git -C "$proj" checkout -q "$main"
  printf 'project=%s\nmode=local-only\nbranch=fm/%s\nlocal_done_head=%s\n' "$proj" "$id" "$(git -C "$proj" rev-parse "fm/$id")" > "$case_dir/home/state/$id.meta"
  printf '%s\n' "$proj"
}

test_merge_local_prints_project_prefs() {
  local case_dir id proj stdout stderr rc
  case_dir="$TMP_ROOT/merge-local-prefs"
  id=prefs-merge-m1
  proj=$(make_local_merge_fixture "$case_dir" "$id")
  mkdir -p "$case_dir/home/data/captain-projects"
  printf '%s\n' '- Merge-time rule: confirm the release note.' > "$case_dir/home/data/captain-projects/proj.md"
  FM_HOME="$case_dir/home" "$ROOT/bin/fm-merge-local.sh" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  stdout=$(cat "$case_dir/stdout"); stderr=$(cat "$case_dir/stderr")
  expect_code 0 "$rc" "a local merge for a project with preferences should succeed"$'\n'"$stderr"
  assert_contains "$stderr" "Merge-time rule: confirm the release note." "a local merge must print the project's preferences to stderr"
  assert_not_contains "$stdout" "Merge-time rule" "the preferences must stay off stdout"
  assert_contains "$stdout" "merged fm/$id into local" "the merge report on stdout must be unchanged"
  assert_equals "$(git -C "$proj" rev-parse "fm/$id")" "$(git -C "$proj" rev-parse HEAD)" "the default branch must fast-forward to the ship branch"

  id=prefs-merge-m2
  case_dir="$TMP_ROOT/merge-local-noprefs"
  make_local_merge_fixture "$case_dir" "$id" >/dev/null
  FM_HOME="$case_dir/home" "$ROOT/bin/fm-merge-local.sh" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  expect_code 0 "$rc" "a local merge for a project without preferences should succeed"
  assert_not_contains "$(cat "$case_dir/stderr")" "Per-project captain preferences" "a project without a file must print no preference block at merge"
  pass "fm-merge-local.sh: a merge prints the project's preferences to stderr and leaves stdout alone"
}

test_merge_local_warns_but_still_merges_when_prefs_unreadable() {
  local case_dir id proj stderr rc
  case_dir="$TMP_ROOT/merge-local-unreadable"
  id=prefs-merge-m3
  proj=$(make_local_merge_fixture "$case_dir" "$id")
  mkdir -p "$case_dir/home/data/captain-projects"
  printf 'x\n' > "$case_dir/target.md"
  ln -s "$case_dir/target.md" "$case_dir/home/data/captain-projects/proj.md"
  FM_HOME="$case_dir/home" "$ROOT/bin/fm-merge-local.sh" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
  stderr=$(cat "$case_dir/stderr")
  expect_code 0 "$rc" "an unreadable preferences file must never block a merge"$'\n'"$stderr"
  assert_contains "$stderr" "could not read the per-project captain preferences for task $id" "an unreadable file must warn at merge time"
  assert_equals "$(git -C "$proj" rev-parse "fm/$id")" "$(git -C "$proj" rev-parse HEAD)" "the merge must still land despite the unreadable file"
  pass "fm-merge-local.sh: an unreadable preferences file only warns and the merge still lands"
}


test_show_prints_header_and_content
test_absent_project_is_silent
test_path_and_list
test_invalid_names_and_unsafe_files
test_show_task_resolves_project_from_meta
test_brief_prints_project_prefs
test_brief_refuses_unreadable_prefs_before_writing
test_review_diff_prints_project_prefs
test_memory_budget_ignores_project_prefs
test_spawn_names_project_prefs_at_dispatch
test_spawn_names_project_prefs_for_scout
test_merge_local_prints_project_prefs
test_merge_local_warns_but_still_merges_when_prefs_unreadable

echo "# fm-project-prefs.test.sh: all assertions passed"
