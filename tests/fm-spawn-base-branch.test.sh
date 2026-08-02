#!/usr/bin/env bash
# End-to-end regression test for the branch a spawned worker actually stands on
# (bin/fm-spawn.sh's place_worker_on_base, resolved by bin/fm-base-branch.sh).
#
# The incident: a task worktree is cut from the local clone, the clone's cached
# refs/remotes/origin/HEAD still named the branch that was default when it was
# cloned, and workers were handed that stale branch for days. An audit concluded a
# live subsystem "is not shipped" because its files were simply absent from the
# branch it was reading.
#
# Each fixture below reproduces that exact shape: a clone whose cached default is
# main, a remote whose default is now develop, and a develop-only file standing in
# for the missing subsystem. The worker must be able to see that file without
# fetching anything itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-base-branch)
fm_git_identity

git_c() {
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "${@:2}"
}

commit_file() {  # <repo> <file> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git_c "$1" commit -qm "$3"
}

# A fake tmux that always reports the task worktree as the pane's cwd (the
# settled state the real spawn polls for), plus a no-op treehouse: this suite is
# about which commit that worktree ends up on, not about acquiring it.
make_fakebin() {  # <dir> <worktree>
  local dir=$1 wt=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' '$wt'; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <task-id> [registry-line]
# Builds the stale-clone fixture, a detached pool-style worktree of that clone
# sitting on the stale branch, a firstmate home, and the fake terminal.
make_case() {
  local name=$1 id=$2 registry=${3:-} case_dir work bare proj wt home fakebin
  case_dir="$TMP_ROOT/$name"
  work="$case_dir/upstream.work"
  bare="$case_dir/upstream.git"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  home="$case_dir/home"
  mkdir -p "$case_dir" "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$registry" > "$home/data/projects.md"
  touch "$home/state/.last-watcher-beat"

  fm_git_init_commit "$work"
  git -C "$work" branch -qM main
  git clone -q --bare "$work" "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone -q "$bare" "$proj"

  # The upstream moves on: develop becomes the default and carries the subsystem.
  git -C "$work" checkout -q -b develop
  commit_file "$work" RemoteConfig.txt "remote config sources"
  git -C "$work" push -q "$bare" develop
  git -C "$bare" symbolic-ref HEAD refs/heads/develop

  # A pool-style worktree: detached, on whatever the clone last had - the stale
  # branch. Nothing about it knows develop exists.
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_fakebin "$case_dir/fake" "$wt")

  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$bare" "$proj" "$wt" "$home" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR BARE PROJ WT HOME_DIR FAKEBIN <<EOF
$1
EOF
}

add_branch() {  # <branch>
  git -C "$CASE_DIR/upstream.work" checkout -q -b "$1"
  commit_file "$CASE_DIR/upstream.work" "$1.txt" "$1 branch content"
  git -C "$CASE_DIR/upstream.work" push -q "$BARE" "$1"
}

run_spawn() {  # <task-id> [extra-args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ" "$@" 2>&1
}

remote_tip() {  # <branch>
  git -C "$BARE" rev-parse "refs/heads/$1"
}

# The core regression. Nothing is declared anywhere: the worker must still land on
# the remote's current default and see the develop-only sources immediately.
test_worker_lands_on_the_remote_default() {
  local rec id out status
  id=base-remote-default-a1
  rec=$(make_case remote-default "$id" '- project [no-mistakes] - fixture (added 2026-08-02)')
  read_case "$rec"

  assert_absent "$WT/RemoteConfig.txt" \
    "fixture worktree should start without the develop-only sources"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(remote_tip develop)" ] \
    || fail "worker was not placed on the remote's current default branch tip"
  assert_present "$WT/RemoteConfig.txt" \
    "worker cannot see the develop-only sources without fetching them itself"
  assert_grep "base_branch=develop" "$HOME_DIR/state/$id.meta" \
    "spawn record does not show the base branch used"
  assert_grep "base_branch_source=remote-default" "$HOME_DIR/state/$id.meta" \
    "spawn record does not show where the base branch came from"
  assert_contains "$out" "base=develop(remote-default)" \
    "spawn line did not report the base branch"
  pass "a worker starts on the remote's current default branch, not the clone's stale cached one"
}

# A scout gets the same treatment: its findings are worthless if it reads the
# wrong branch, which is exactly how this defect was discovered.
test_scout_lands_on_the_remote_default() {
  local rec id out status
  id=base-scout-a2
  rec=$(make_case scout "$id" '- project [no-mistakes] - fixture (added 2026-08-02)')
  read_case "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ" --scout 2>&1)
  status=$?
  expect_code 0 "$status" "scout spawn should succeed"
  assert_present "$WT/RemoteConfig.txt" "scout cannot see the develop-only sources"
  assert_grep "kind=scout" "$HOME_DIR/state/$id.meta" "fixture did not spawn a scout"
  assert_grep "base_branch=develop" "$HOME_DIR/state/$id.meta" \
    "scout spawn record does not show the base branch used"
  pass "a scout is placed on the same resolved base branch as a ship worker"
}

# The escape hatch: a project whose development branch is genuinely not the remote
# default declares it, and the worker lands there instead.
test_declared_base_branch_is_used() {
  local rec id out status
  id=base-declared-a3
  rec=$(make_case declared "$id" '- project [no-mistakes base=release] - fixture (added 2026-08-02)')
  read_case "$rec"
  add_branch release

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should succeed on a declared base branch"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(remote_tip release)" ] \
    || fail "worker was not placed on the declared base branch"
  assert_present "$WT/release.txt" "worker cannot see the declared branch's content"
  assert_grep "base_branch=release" "$HOME_DIR/state/$id.meta" \
    "spawn record does not show the declared base branch"
  assert_grep "base_branch_source=project-override" "$HOME_DIR/state/$id.meta" \
    "spawn record does not show the declared override as the source"
  assert_contains "$out" "base=release(project-override)" \
    "spawn line did not report the declared base branch"
  pass "a declared base branch places the worker there instead of on the remote default"
}

# A declared branch the remote does not have must refuse the whole spawn: a worker
# quietly reading the wrong code is the defect, and failing to launch is not.
test_missing_declared_branch_refuses_the_spawn() {
  local rec id out status
  id=base-missing-a4
  rec=$(make_case missing "$id" '- project [no-mistakes base=no-such-branch] - fixture (added 2026-08-02)')
  read_case "$rec"

  set +e
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "spawn must refuse when the declared base branch does not exist"
  assert_contains "$out" 'project "project"' "refusal did not name the project"
  assert_contains "$out" "no-such-branch" "refusal did not name the missing branch"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused spawn must not leave a task record behind"
  [ "$(git -C "$WT" rev-parse HEAD)" != "$(remote_tip develop)" ] \
    || fail "a refused spawn must not silently place the worker on the default branch instead"
  pass "a declared base branch missing from the remote refuses the spawn, naming project and branch"
}

# A project with no remote has no stale cache to correct; it resolves to its own
# default branch, and the record says so.
test_no_remote_uses_the_local_default() {
  local rec id out status
  id=base-no-remote-a5
  rec=$(make_case no-remote "$id" '- project [local-only] - fixture (added 2026-08-02)')
  read_case "$rec"
  git -C "$PROJ" remote remove origin

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should succeed for a project with no remote"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse refs/heads/main)" ] \
    || fail "worker was not placed on the remote-less project's own default branch"
  assert_grep "base_branch_source=local-default" "$HOME_DIR/state/$id.meta" \
    "spawn record does not show the local default as the source"
  pass "a project with no remote places the worker on its own default branch"
}

# Nothing resolvable at all leaves the worktree exactly where it was, with no base
# branch claimed in the record - the pre-existing behavior, preserved.
test_unresolvable_base_leaves_the_worktree_alone() {
  local rec id out status before
  id=base-none-a6
  rec=$(make_case none "$id" '- project [local-only] - fixture (added 2026-08-02)')
  read_case "$rec"
  git -C "$PROJ" remote remove origin
  git -C "$PROJ" checkout -q --detach HEAD
  before=$(git -C "$WT" rev-parse HEAD)

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should still succeed when no base branch is resolvable"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$before" ] \
    || fail "an unresolvable base branch must leave the worktree where it was"
  assert_no_grep "base_branch=" "$HOME_DIR/state/$id.meta" \
    "no base branch was used, so none should be claimed in the record"
  assert_not_contains "$out" "base=" "spawn line should claim no base branch"
  pass "an unresolvable base branch leaves the worktree untouched and claims nothing"
}

# Promoting a scout in place keeps its worktree, so the ship instructions must
# send it back to the branch it was actually spawned on. Telling it to reset to
# "the default branch" would put a promoted worker back on the stale branch this
# whole path exists to stop handing out.
test_promotion_instructions_name_the_recorded_base_branch() {
  local rec id out
  id=base-promote-a7
  rec=$(make_case promote "$id" '- project [no-mistakes] - fixture (added 2026-08-02)')
  read_case "$rec"

  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ" --scout >/dev/null 2>&1

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1)
  assert_contains "$out" "reset to a clean base on develop" \
    "promotion instructions did not name the branch the task was spawned on"
  assert_not_contains "$out" "default-branch base" \
    "promotion instructions still send a promoted worker to the generic default branch"
  pass "promotion instructions name the base branch the task was actually spawned on"
}

test_worker_lands_on_the_remote_default
test_scout_lands_on_the_remote_default
test_promotion_instructions_name_the_recorded_base_branch
test_declared_base_branch_is_used
test_missing_declared_branch_refuses_the_spawn
test_no_remote_uses_the_local_default
test_unresolvable_base_leaves_the_worktree_alone

echo "# all fm-spawn-base-branch tests passed"
