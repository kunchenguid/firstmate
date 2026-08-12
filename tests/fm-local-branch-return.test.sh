#!/usr/bin/env bash
# End-to-end coverage for guarded local-only secondmate project seeding, branch
# return, and the existing captain-controlled local landing gate.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-branch-return)

make_world() { # <name>
  local name=$1 home sub project
  home="$TMP_ROOT/$name/main"
  sub="$TMP_ROOT/$name/secondmate"
  project="$home/projects/alpha"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$project"
  # The assertions below name the default branch explicitly, so pin it instead
  # of inheriting the machine's init.defaultBranch (CI runners still say master).
  git -C "$project" branch -M main
  printf '%s\n' '- alpha [local-only] - sensitive local project (added 2026-08-10)' > "$home/data/projects.md"
  mark_firstmate_home "$sub"
  FM_SECONDMATE_SCOPE='sensitive local operations' \
    scaffold_secondmate_charter "$home" ops 'sensitive local operations charter' alpha \
    || fail "could not scaffold local-only secondmate charter"
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" ops "$sub" alpha >/dev/null \
    || fail "could not seed local-only secondmate project"
  printf '%s\t%s\t%s\n' "$home" "$sub" "$project"
}

make_task() { # <subhome> <task-id>
  local sub=$1 task=$2 project wt
  project="$sub/projects/alpha"
  wt="$TMP_ROOT/worktrees/$(basename "$(dirname "$sub")")-$task"
  mkdir -p "$(dirname "$wt")" "$sub/state"
  git -C "$project" worktree add -q -b "fm/$task" "$wt"
  printf 'task %s\n' "$task" > "$wt/result.txt"
  git -C "$wt" add result.txt
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "task $task"
  cat > "$sub/state/$task.meta" <<EOF
window=test:fm-$task
endpoint_task_id=$task
worktree=$wt
project=$project
harness=pi
kind=ship
mode=local-only
yolo=off
EOF
  printf '%s\n' "$wt"
}

route_record() { # <main-home>
  printf '%s/data/local-project-routes/ops/alpha.route\n' "$1"
}

return_branch() { # <main-home> <task-id>
  FM_HOME="$1" "$ROOT/bin/fm-local-branch-return.sh" ops "$2"
}

assert_parent_branch_absent() { # <parent-project> <branch>
  git -C "$1" show-ref --verify --quiet "refs/heads/$2" \
    && fail "unexpected parent branch $2 in $1"
}

assert_parent_branch_matches() { # <parent-project> <branch> <source-worktree>
  local parent=$1 branch=$2 source=$3
  [ "$(git -C "$parent" rev-parse "refs/heads/$branch")" = "$(git -C "$source" rev-parse HEAD)" ] \
    || fail "parent branch $branch does not match the returned source head"
}

test_success_replay_and_guarded_landing() {
  local row home sub project wt base head out
  row=$(make_world success)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" return-ok)
  base=$(git -C "$project" rev-parse main)
  head=$(git -C "$wt" rev-parse HEAD)
  [ "$(git -C "$sub/projects/alpha" remote get-url --push origin)" = "$sub/projects/alpha" ] \
    || fail "local-only project copy retained push authority into the main project"
  if git -C "$wt" push -q origin HEAD:main >/dev/null 2>&1; then
    fail "secondmate task could land its own result through origin"
  fi
  [ "$(git -C "$project" rev-parse main)" = "$base" ] \
    || fail "refused secondmate push changed the main project"

  out=$(return_branch "$home" return-ok) || fail "clean local branch return failed"
  assert_contains "$out" 'returned fm/return-ok' "branch return did not report success"
  [ "$(git -C "$project" rev-parse main)" = "$base" ] \
    || fail "branch return merged or rewrote the parent default branch"
  assert_parent_branch_matches "$project" fm/return-ok "$wt"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] \
    || fail "branch return rewrote the source worktree"
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "branch return dirtied the source worktree"

  out=$(return_branch "$home" return-ok) || fail "idempotent branch return replay failed"
  assert_contains "$out" 'already returned fm/return-ok' "replay did not report idempotence"
  [ "$(git -C "$project" rev-parse main)" = "$base" ] \
    || fail "branch return replay merged the parent default branch"

  FM_HOME="$home" "$ROOT/bin/fm-merge-local.sh" --secondmate ops return-ok >/dev/null \
    || fail "captain-controlled guarded local landing rejected a valid returned branch"
  [ "$(git -C "$project" rev-parse main)" = "$head" ] \
    || fail "guarded local landing did not fast-forward the parent default branch"
  pass "local-only secondmate branch returns without landing, replays idempotently, then lands only through the main gate"
}

test_collision_preserves_both_branches() {
  local row home sub project wt source_head destination_head err
  row=$(make_world collision)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" collide)
  source_head=$(git -C "$wt" rev-parse HEAD)
  git -C "$project" checkout -qb fm/collide
  printf 'parent owner\n' > "$project/owner.txt"
  git -C "$project" add owner.txt
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm owner
  destination_head=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q main
  err="$TMP_ROOT/collision.err"

  if return_branch "$home" collide > /dev/null 2>"$err"; then
    fail "branch return overwrote a colliding destination branch"
  fi
  assert_grep 'owned by different work' "$err" "collision refusal did not identify the ownership conflict"
  [ "$(git -C "$project" rev-parse fm/collide)" = "$destination_head" ] \
    || fail "collision refusal changed the destination branch"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$source_head" ] \
    || fail "collision refusal changed the source branch"
  pass "branch collision refuses without changing either repository"
}

test_dirty_source_refuses() {
  local row home sub project wt err
  row=$(make_world dirty)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" dirty-task)
  printf 'dirty\n' >> "$wt/result.txt"
  err="$TMP_ROOT/dirty.err"
  if return_branch "$home" dirty-task > /dev/null 2>"$err"; then
    fail "branch return accepted a dirty source worktree"
  fi
  assert_grep 'source worktree is dirty' "$err" "dirty refusal did not explain the source state"
  assert_parent_branch_absent "$project" fm/dirty-task
  assert_grep 'dirty' "$wt/result.txt" "dirty refusal did not preserve source work"
  pass "dirty source work is refused and preserved"
}

test_wrong_or_ambiguous_source_refuses() {
  local row home sub project wt wrong err
  row=$(make_world wrong-source)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" wrong-source-task)
  wrong="$TMP_ROOT/wrong-source/other"
  fm_git_init_commit "$wrong"
  git -C "$sub/projects/alpha" remote set-url origin "$wrong"
  err="$TMP_ROOT/wrong-source.err"
  if return_branch "$home" wrong-source-task > /dev/null 2>"$err"; then
    fail "branch return accepted the wrong local source binding"
  fi
  assert_grep 'origin does not match' "$err" "wrong-source refusal did not identify route drift"
  assert_parent_branch_absent "$project" fm/wrong-source-task

  git -C "$sub/projects/alpha" remote set-url origin "$project"
  git -C "$sub/projects/alpha" remote add backup "$project"
  if return_branch "$home" wrong-source-task > /dev/null 2>"$err"; then
    fail "branch return accepted an ambiguous extra remote"
  fi
  assert_grep 'exactly one local origin' "$err" "ambiguous-repository refusal was not explicit"
  assert_parent_branch_absent "$project" fm/wrong-source-task
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "wrong-source refusals changed the source worktree"
  pass "wrong and ambiguous repository bindings are refused"
}

test_unsafe_path_and_capability_refuse() {
  local row home sub project wt real_wt link err route saved
  row=$(make_world unsafe)
  IFS=$'\t' read -r home sub project <<< "$row"
  real_wt=$(make_task "$sub" unsafe-task)
  link="$TMP_ROOT/unsafe/worktree-link"
  ln -s "$real_wt" "$link"
  perl -0pi -e 's{^worktree=.*$}{worktree='"$link"'}m' "$sub/state/unsafe-task.meta"
  err="$TMP_ROOT/unsafe.err"
  if return_branch "$home" unsafe-task > /dev/null 2>"$err"; then
    fail "branch return accepted a symlinked source worktree path"
  fi
  assert_grep 'unsafe or symlinked worktree path' "$err" "unsafe-path refusal was not explicit"
  assert_parent_branch_absent "$project" fm/unsafe-task

  perl -0pi -e 's{^worktree=.*$}{worktree='"$real_wt"'}m' "$sub/state/unsafe-task.meta"
  route=$(route_record "$home")
  saved="$route.saved"
  mv "$route" "$saved"
  ln -s "$saved" "$route"
  if return_branch "$home" unsafe-task > /dev/null 2>"$err"; then
    fail "branch return accepted a symlinked capability"
  fi
  assert_grep 'capability is unavailable or unsafe' "$err" "unsafe-capability refusal was not explicit"
  assert_parent_branch_absent "$project" fm/unsafe-task
  pass "symlinked and unsafe route paths are refused without changing the branch"
}

test_divergence_refuses() {
  local row home sub project wt err
  row=$(make_world divergence)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" diverged-task)
  printf 'advanced parent\n' > "$project/parent.txt"
  git -C "$project" add parent.txt
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'advance parent'
  err="$TMP_ROOT/divergence.err"
  if return_branch "$home" diverged-task > /dev/null 2>"$err"; then
    fail "branch return accepted a branch that is not a fast-forward of current main"
  fi
  assert_grep 'not a fast-forward of the current destination' "$err" "divergence refusal was not explicit"
  assert_parent_branch_absent "$project" fm/diverged-task
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "divergence refusal changed source work"
  pass "unexpected ancestry is refused and source work is preserved"
}

test_absent_capability_and_ownership_conflict_refuse() {
  local row home sub project wt route err fakebin
  row=$(make_world absent)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" absent-task)
  route=$(route_record "$home")
  rm -f "$route"
  err="$TMP_ROOT/absent.err"
  # Harness resolution checks for a real `pi` executable before the local-only
  # route guard runs; stub it so the test proves the guard, not the machine's
  # installed harnesses (CI runners have no pi).
  fakebin=$(fm_fakebin "$TMP_ROOT/absent-fakebin")
  fm_fake_exit0 "$fakebin" pi
  FM_HOME="$sub" "$ROOT/bin/fm-brief.sh" no-capability alpha --mode local-only >/dev/null \
    || fail "could not scaffold absent-capability spawn fixture"
  if PATH="$fakebin:$PATH" FM_HOME="$sub" FM_BACKEND=tmux "$ROOT/bin/fm-spawn.sh" no-capability "$sub/projects/alpha" \
      --mode local-only --yolo off --harness pi > /dev/null 2>"$err"; then
    fail "secondmate spawn accepted local-only work without the guarded capability"
  fi
  assert_grep 'local-only secondmate route is absent or invalid' "$err" \
    "spawn did not enforce the absent local-project capability"
  assert_absent "$sub/state/no-capability.meta" "refused local-only spawn still published task metadata"
  FM_HOME="$sub" "$ROOT/bin/fm-brief.sh" no-capability-scout alpha --scout >/dev/null \
    || fail "could not scaffold absent-capability scout spawn fixture"
  if PATH="$fakebin:$PATH" FM_HOME="$sub" FM_BACKEND=tmux "$ROOT/bin/fm-spawn.sh" no-capability-scout "$sub/projects/alpha" \
      --scout --harness pi > /dev/null 2>"$err"; then
    fail "secondmate scout spawn accepted a local-only project without the guarded capability"
  fi
  assert_grep 'local-only secondmate route is absent or invalid' "$err" \
    "scout spawn did not enforce the absent local-project capability"
  assert_absent "$sub/state/no-capability-scout.meta" "refused local-only scout spawn still published task metadata"
  if return_branch "$home" absent-task > /dev/null 2>"$err"; then
    fail "branch return proceeded without the guarded capability"
  fi
  assert_grep 'capability is unavailable or unsafe' "$err" "absent capability refusal was not explicit"
  assert_parent_branch_absent "$project" fm/absent-task

  # Re-seeding restores the same validated route without disturbing source work.
  FM_HOME="$home" "$ROOT/bin/fm-home-seed.sh" ops "$sub" alpha >/dev/null \
    || fail "idempotent seed did not restore the capability"
  printf 'kind=ship\nproject=%s\n' "$project" > "$home/state/absent-task.meta"
  if return_branch "$home" absent-task > /dev/null 2>"$err"; then
    fail "branch return accepted a task id already owned in the main home"
  fi
  assert_grep 'task identity is already owned' "$err" "ownership-conflict refusal was not explicit"
  assert_parent_branch_absent "$project" fm/absent-task
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "ownership refusals changed source work"
  pass "absent capability and conflicting task ownership both refuse"
}

test_destination_drift_and_missing_object_refuse() {
  local row home sub project wt moved err oid object
  row=$(make_world drift)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" drift-task)
  moved="$TMP_ROOT/drift/original-project"
  mv "$project" "$moved"
  fm_git_init_commit "$project"
  err="$TMP_ROOT/drift.err"
  if return_branch "$home" drift-task > /dev/null 2>"$err"; then
    fail "branch return accepted a replacement repository at the destination path"
  fi
  grep -F 'destination repository identity drifted' "$err" >/dev/null \
    || fail "destination drift refusal was not explicit: $(cat "$err")"
  assert_parent_branch_absent "$project" fm/drift-task

  row=$(make_world missing-object)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" missing-task)
  oid=$(git -C "$wt" rev-parse HEAD)
  object=$(git -C "$sub/projects/alpha" rev-parse --git-path "objects/${oid:0:2}/${oid:2}")
  case "$object" in /*) ;; *) object="$sub/projects/alpha/$object" ;; esac
  rm -f "$object"
  err="$TMP_ROOT/missing-object.err"
  if return_branch "$home" missing-task > /dev/null 2>"$err"; then
    fail "branch return accepted a source branch with a missing commit object"
  fi
  assert_grep 'source branch commit is missing' "$err" "missing-object refusal was not explicit"
  assert_parent_branch_absent "$project" fm/missing-task
  pass "destination identity drift and missing source objects refuse"
}

test_external_remote_guarantees() {
  local row home sub project wt err external_home external_sub external_project
  row=$(make_world external-return)
  IFS=$'\t' read -r home sub project <<< "$row"
  wt=$(make_task "$sub" external-task)
  git -C "$sub/projects/alpha" remote add leak https://example.invalid/sensitive.git
  err="$TMP_ROOT/external-return.err"
  if return_branch "$home" external-task > /dev/null 2>"$err"; then
    fail "branch return accepted a project copy with an external remote"
  fi
  assert_grep 'non-local remote' "$err" "external-remote refusal was not explicit"
  assert_parent_branch_absent "$project" fm/external-task
  [ -z "$(git -C "$wt" status --porcelain)" ] || fail "external-remote refusal changed source work"

  external_home="$TMP_ROOT/external-seed/main"
  external_sub="$TMP_ROOT/external-seed/secondmate"
  external_project="$external_home/projects/alpha"
  mkdir -p "$external_home/projects" "$external_home/data" "$external_home/state"
  fm_git_init_commit "$external_project"
  git -C "$external_project" remote add origin https://example.invalid/sensitive.git
  printf '%s\n' '- alpha [local-only] - sensitive local project (added 2026-08-10)' > "$external_home/data/projects.md"
  mark_firstmate_home "$external_sub"
  FM_SECONDMATE_SCOPE='sensitive local operations' \
    scaffold_secondmate_charter "$external_home" ops 'sensitive local operations charter' alpha
  if FM_HOME="$external_home" "$ROOT/bin/fm-home-seed.sh" ops "$external_sub" alpha > /dev/null 2>"$err"; then
    fail "local-only seed accepted an external project remote"
  fi
  assert_grep 'non-local remote' "$err" "seed did not explain its no-external-remote refusal"
  assert_absent "$external_sub/projects/alpha" "refused external seed still created a project copy"
  pass "local-only seeding and return both guarantee that every configured remote is local filesystem only"
}

test_success_replay_and_guarded_landing
test_collision_preserves_both_branches
test_dirty_source_refuses
test_wrong_or_ambiguous_source_refuses
test_unsafe_path_and_capability_refuse
test_divergence_refuses
test_absent_capability_and_ownership_conflict_refuse
test_destination_drift_and_missing_object_refuse
test_external_remote_guarantees
