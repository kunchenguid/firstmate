#!/usr/bin/env bash
# Regression tests for scout worktree isolation (#1746).
#
# A scout brief invites the worker to install, run, and make scratch commits in
# its worktree, and teardown discards that worktree. When the recorded worktree
# is the project's own clone instead of a disposable one, all three of those
# become operations on the captain's primary checkout. These tests pin the
# three guards that keep that impossible:
#   - bin/fm-brief.sh --scout emits the isolation assertion ship briefs carry.
#   - bin/fm-spawn.sh --scout refuses when the resolved path is not a real
#     worktree distinct from the project, and writes no metadata.
#   - bin/fm-teardown.sh refuses, --force included, when the recorded worktree
#     resolves to the same path as the recorded project.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-scout-isolation)

# --- brief ------------------------------------------------------------------

test_scout_brief_carries_the_isolation_assertion() {
  local home="$TMP_ROOT/brief/home" id=scout-brief-a1 out
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF" "$id" some-repo --scout > /dev/null
  out=$(cat "$home/data/$id/brief.md")
  assert_contains "$out" 'Verify isolation before anything else' \
    "scout brief has no isolation assertion"
  assert_contains "$out" 'git rev-parse --show-toplevel' \
    "scout brief does not tell the worker how to verify isolation"
  assert_contains "$out" 'blocked: launched in primary checkout, not an isolated worktree' \
    "scout brief does not tell the worker to stop and report"
  pass "a scout brief carries the same isolation assertion a ship brief does"
}

# --- spawn ------------------------------------------------------------------

# A fake tmux whose pane_current_path always reports FM_FAKE_PANE_PATH, standing
# in for a `treehouse get` that left the pane somewhere that is not a real
# worktree of its own.
make_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_scout_spawn_refuses_a_path_that_is_not_its_own_worktree() {
  local case_dir="$TMP_ROOT/spawn" home proj wt fakebin id=scout-spawn-b2 out status
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" wt-scout
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$proj/scratch"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$proj/scratch" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --scout 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "scout spawn succeeded from a non-worktree path: $out"
  assert_contains "$out" 'did not yield an isolated worktree' \
    "scout spawn did not refuse with the isolation error"
  assert_absent "$home/state/$id.meta" \
    "scout spawn recorded metadata for a non-isolated worktree"
  pass "a scout spawn that cannot resolve its own worktree refuses and records nothing"
}

# --- teardown ---------------------------------------------------------------

make_teardown_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/teardown/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/project"
  : > "$dir/project/sentinel"
  : > "$dir/runtime.log"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$dir"
}

assert_teardown_refuses_clone_as_worktree() {  # <name> <kind> <force...>
  local name=$1 kind=$2 dir id=clone-as-wt out status
  shift 2
  dir=$(make_teardown_case "$name")
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/project" \
    "project=$dir/project" \
    "kind=$kind"
  set +e
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$name: teardown accepted the clone as its discard target"
  assert_contains "$out" 'REFUSED' "$name: teardown did not refuse loudly"
  assert_contains "$out" 'records the project clone' \
    "$name: teardown refused for some other reason, not the clone-as-worktree record"
  assert_present "$dir/project/sentinel" "$name: the clone was touched before refusal"
  assert_present "$dir/home/state/$id.meta" "$name: task state was cleared before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$name: a runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_teardown_refuses_when_the_worktree_is_the_clone() {
  assert_teardown_refuses_clone_as_worktree scout scout
  assert_teardown_refuses_clone_as_worktree ship ship
  pass "cleanup refuses when the recorded worktree is the project clone"
}

test_teardown_refuses_the_clone_even_under_force() {
  assert_teardown_refuses_clone_as_worktree forced scout --force
  pass "discard authority never extends to the project clone"
}

test_scout_brief_carries_the_isolation_assertion
test_scout_spawn_refuses_a_path_that_is_not_its_own_worktree
test_teardown_refuses_when_the_worktree_is_the_clone
test_teardown_refuses_the_clone_even_under_force

echo "# all fm-scout-isolation tests passed"
