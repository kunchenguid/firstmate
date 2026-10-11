#!/usr/bin/env bash
# Integration tests for fm-spawn's placement of a project's untracked local
# material into the task worktree.
#
# tests/fm-local-material.test.sh pins the placement contract against temporary
# directories. This file pins the part only the spawn can answer: that the real
# spawn path actually calls into it, that the worker's own launch brief carries
# the rules for the credentials it just received, and that a manifest naming a
# file nobody put there stops the spawn instead of launching a worker into a
# worktree that cannot run the app.
#
# Placement itself still cannot be proven end to end here - that needs a real
# worker in a real pool slot - so these cases drive the real fm-spawn against a
# fake terminal and a real pooled worktree, and assert on what lands on disk.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-local-material)

MANIFEST='{
  "project": {
    "environments": {
      "default": ".env.staging",
      "production": ".env",
      "production_note": "video and social surfaces work nowhere else"
    },
    "entries": [
      { "path": ".env",         "mode": "link" },
      { "path": ".env.staging", "mode": "link" },
      { "path": "e2e/.auth",    "mode": "copy" }
    ]
  }
}'

# A home with a pooled worktree of a real project, plus the untracked material
# the manifest will name. The material lives in the project clone, which is the
# default source, so these cases exercise the path a fleet gets with no "source"
# override.
make_case() { # <name> <task-id> -> "case|home|project|pool|fakebin"
  local name=$1 id=$2 case_dir home project pool fakebin head
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  # A real project gitignores its local material, and the placement refuses
  # anything it does not, so the fixture carries the same committed .gitignore
  # every worktree cut from it will have.
  printf '.env\n.env.staging\n/e2e/.auth/\n' > "$project/.gitignore"
  git -C "$project" add README.md .gitignore
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  head=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$head"

  # The untracked local material the manifest names. None of it is tracked, so
  # none of it reaches the pooled worktree through the checkout.
  mkdir -p "$project/e2e/.auth"
  printf 'TOKEN=production\n' > "$project/.env"
  printf 'TOKEN=staging\n' > "$project/.env.staging"
  printf '{"cookies":[]}\n' > "$project/e2e/.auth/admin.json"
  touch -t 202501020304 "$project/e2e/.auth/admin.json"

  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$project" "$pool" "$fakebin"
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() { # <task-id> [extra fm-spawn args...]
  local id=$1; shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

# The whole point: a pooled worktree that had none of this now has all of it,
# in the configured mode, before the worker starts.
test_spawn_places_the_configured_material_in_the_task_worktree() {
  local rec id out status src_stamp dest_stamp
  id='local-material-placed'
  rec=$(make_case placed "$id")
  read_case_record "$rec"
  printf '%s\n' "$MANIFEST" > "$HOME_DIR/config/project-local-material.json"

  assert_absent "$POOL_DIR/.env" \
    "the fixture must start from the real gap: a pooled worktree with no material"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a spawn with configured local material must succeed"$'\n'"$out"

  [ -L "$POOL_DIR/.env" ] || fail "the production environment file must be placed as a link"$'\n'"$out"
  [ -L "$POOL_DIR/.env.staging" ] || fail "the staging environment file must be placed as a link"$'\n'"$out"
  [ "$(readlink "$POOL_DIR/.env.staging")" = "$PROJECT_DIR/.env.staging" ] ||
    fail "a placed link must resolve to the project's own file, so a rotated value propagates"

  [ -d "$POOL_DIR/e2e/.auth" ] || fail "the stored session directory must be copied in"$'\n'"$out"
  [ ! -L "$POOL_DIR/e2e/.auth" ] || fail "the stored session must be a copy, never a shared link"
  src_stamp=$(date -r "$PROJECT_DIR/e2e/.auth/admin.json" +%Y%m%d%H%M)
  dest_stamp=$(date -r "$POOL_DIR/e2e/.auth/admin.json" +%Y%m%d%H%M)
  [ "$src_stamp" = "$dest_stamp" ] ||
    fail "the copy must keep its original timestamp, or a consumer that re-mints by mtime reads an expired session as current"

  assert_contains "$out" "local-material: placed 3 entries" \
    "the spawn must report what it placed"
  # Material that made the worktree read as changed would block this task's own
  # teardown later and invite a worker to commit a credential.
  [ -z "$(git -C "$POOL_DIR" status --porcelain)" ] ||
    fail "an equipped worktree must still read as clean"$'\n'"$(git -C "$POOL_DIR" status --porcelain)"
  pass "fm-spawn: a fresh worktree receives the project's configured local material"
}

# Credentials that arrive without the rules for handling them are what produced
# a write against production, so the rules must be in the brief the worker
# actually reads.
test_the_launch_brief_carries_the_operating_rules() {
  local rec id out status brief
  id='local-material-brief'
  rec=$(make_case brief "$id")
  read_case_record "$rec"
  printf '%s\n' "$MANIFEST" > "$HOME_DIR/config/project-local-material.json"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "the spawn must succeed"$'\n'"$out"

  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_present "$brief" "the spawn must publish a launch brief"
  assert_grep "# Local material in this worktree" "$brief" \
    "the launch brief must carry the local-material section"
  assert_grep "defaults to STAGING" "$brief" \
    "the launch brief must tell the worker a dev server defaults to staging"
  assert_grep "ALWAYS run in staging" "$brief" \
    "the launch brief must pin e2e and screenshots to staging"
  assert_grep "inputs to tools, never reading material" "$brief" \
    "the launch brief must state that these files are consumed, not read"
  assert_grep "video and social surfaces work nowhere else" "$brief" \
    "the launch brief must carry the configured reason production is ever used"

  # The section must not displace the contracts already in the brief.
  assert_grep "# Current worker role contract" "$brief" \
    "the worker role contract must survive alongside the new section"
  assert_grep "# Task" "$brief" "the task itself must survive alongside the new section"
  pass "fm-spawn: the launch brief carries the operating rules for the material placed"
}

# A worktree that looks ready and cannot test is the state the incidents started
# from, so this must cost one spawn rather than a validation round.
test_a_missing_source_refuses_the_spawn() {
  local rec id out status
  id='local-material-missing'
  rec=$(make_case missing "$id")
  read_case_record "$rec"
  printf '%s\n' "$MANIFEST" > "$HOME_DIR/config/project-local-material.json"
  rm "$PROJECT_DIR/.env.staging"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 1 "$status" "a manifest naming a file nobody placed must refuse the spawn"$'\n'"$out"
  assert_contains "$out" ".env.staging" "the refusal must name the missing file"
  assert_contains "$out" "local material" "the refusal must say what it was doing"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused spawn must not publish a task record"
  pass "fm-spawn: a missing local-material source refuses the spawn by name"
}

# The feature must be invisible to a fleet that has not configured it.
test_an_unconfigured_project_spawns_unchanged() {
  local rec id out status brief
  id='local-material-absent'
  rec=$(make_case absent "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a spawn with no manifest at all must succeed"$'\n'"$out"
  assert_not_contains "$out" "local-material:" \
    "an unconfigured project must produce no placement output"

  brief="$HOME_DIR/data/$id/launch-brief.md"
  assert_no_grep "# Local material in this worktree" "$brief" \
    "a worker that received no material must not be given rules about material"
  assert_grep "# Current worker role contract" "$brief" \
    "the ordinary launch brief must be unchanged"
  pass "fm-spawn: a project with no configured material spawns exactly as before"
}

test_spawn_places_the_configured_material_in_the_task_worktree
test_the_launch_brief_carries_the_operating_rules
test_a_missing_source_refuses_the_spawn
test_an_unconfigured_project_spawns_unchanged
