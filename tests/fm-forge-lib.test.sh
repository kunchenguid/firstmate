#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-forge-lib.sh
. "$ROOT/bin/fm-forge-lib.sh"

test_task_body_path_is_task_scoped() {
  local path
  path=$(fm_forge_body_file 'my-task-42')
  [ "$path" = '/tmp/fm-my-task-42/pr-description.md' ] \
    || fail "unexpected forge body path: $path"
  pass "forge body path is task-scoped"
}

test_shared_collision_paths_are_detected() {
  fm_forge_body_file_is_shared_collision /tmp/pr-body.md \
    || fail '/tmp/pr-body.md should be a shared collision'
  fm_forge_body_file_is_shared_collision /tmp/issue-body \
    || fail '/tmp/issue-body should be a shared collision'
  fm_forge_body_file_is_shared_collision /tmp/fm-lane/pr-description.md \
    && fail 'task-scoped path should not be a collision'
  fm_forge_body_file_is_shared_collision /tmp/pr-body-v12-ux-home.md \
    && fail 'lane-unique pr-body filename should not be a collision'
  pass "shared collision detection"
}

test_task_body_path_is_task_scoped
test_shared_collision_paths_are_detected

echo "all fm-forge-lib tests passed"
