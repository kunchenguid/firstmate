#!/usr/bin/env bash
# Regression tests for secondmate-home task copies made from the home's own clone.
#
# Two homes on one machine each hold their own clone of one remote.
# A Treehouse pool is keyed by the remote, but every slot in it is a linked
# worktree of whichever clone created the pool first, so a second home that
# pools is handed a copy of the FIRST home's clone and its spawn is refused.
# These tests drive the real spawn and teardown paths with a fake pane that
# behaves like a shell - it follows `cd` and, on `treehouse get`, moves into
# the slot the shared pool would hand over - and prove that every secondmate
# home makes its copy from its own clone while the main home still pools.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-clone-worktree)
GIT_ID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')

# A pane stand-in layered over the shared spawn tmux stub.
# It keeps the pane's cwd in FM_FAKE_PANE_CWD_FILE: `treehouse get` moves the
# pane into FM_FAKE_POOL_SLOT (the slot the shared pool hands out), `cd -- <p>`
# moves it to <p>, and every typed line is logged to FM_FAKE_PANE_TYPED_LOG.
make_shell_pane_fakebin() {  # <dir>
  local fakebin
  fakebin=$(make_spawn_fakebin "$1")
  mv "$fakebin/tmux" "$fakebin/tmux-stub"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
here=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  *"#{pane_current_path}"*) cat "$FM_FAKE_PANE_CWD_FILE"; exit 0 ;;
esac
if [ "${1:-}" = send-keys ]; then
  prev= literal=0 payload=
  for a in "${@:2}"; do
    if [ "$prev" = -t ]; then prev=; continue; fi
    case "$a" in
      -t) prev=-t; continue ;;
      -l) literal=1; continue ;;
      Enter|C-m) continue ;;
      *) payload=$a ;;
    esac
  done
  if [ "$literal" = 0 ] && [ -n "$payload" ]; then
    printf '%s\n' "$payload" >> "$FM_FAKE_PANE_TYPED_LOG"
    case "$payload" in
      'treehouse get') printf '%s\n' "$FM_FAKE_POOL_SLOT" > "$FM_FAKE_PANE_CWD_FILE" ;;
      "cd -- '"*"'")
        dest=${payload#"cd -- '"}
        dest=${dest%"'"}
        printf '%s\n' "$dest" > "$FM_FAKE_PANE_CWD_FILE"
        ;;
    esac
  fi
fi
exec "$here/tmux-stub" "$@"
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# One origin, a publisher that advances it after the clones are made, and the
# shared pool whose only slot is a linked worktree of the FIRST clone given.
make_origin() {  # <case-dir>
  local case_dir=$1 seed
  seed="$case_dir/seed"
  git init --quiet -b main "$seed"
  printf 'base\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" "${GIT_ID[@]}" commit -qm initial
  git clone --quiet --bare "$seed" "$case_dir/origin.git"
}

advance_origin() {  # <case-dir>
  local case_dir=$1 publisher
  publisher="$case_dir/publisher"
  git clone --quiet "file://$case_dir/origin.git" "$publisher"
  printf 'advanced\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" "${GIT_ID[@]}" commit -qm advance-main
  git -C "$publisher" push --quiet origin main
}

# A home holding its own clone of the origin. <marker> is a secondmate id, or
# empty for a main home.
make_home() {  # <case-dir> <name> <marker> <harness>
  local case_dir=$1 name=$2 marker=$3 harness=$4 home
  home="$case_dir/$name"
  fm_test_spawn_home "$home" "$harness"
  [ -z "$marker" ] || printf '%s\n' "$marker" > "$home/.fm-secondmate-home"
  git clone --quiet "file://$case_dir/origin.git" "$home/projects/agents"
  printf '%s\n' "$home"
}

# The pool Treehouse keeps for this remote, bound to <owner-clone>.
make_pool() {  # <case-dir> <owner-clone>
  local case_dir=$1 owner=$2 pool slot
  pool="$case_dir/treehouse/agents-9083ce"
  slot="$pool/1/agents"
  mkdir -p "$pool/1"
  printf '{}\n' > "$pool/treehouse-state.json"
  git -C "$owner" worktree add --quiet --detach "$slot" HEAD
  printf '%s\n' "$slot"
}

# Spawn <id> in <home> through the real fm-spawn with a shell-like pane that
# starts in the home's clone. Output and exit code land in SPAWN_OUT/SPAWN_RC.
spawn_in_home() {  # <home> <fakebin> <pool-slot> <id> [args...]
  local home=$1 fakebin=$2 slot=$3 id=$4
  shift 4
  spawn_on_project "$home" "$fakebin" "$slot" "$id" "$home/projects/agents" "$@"
}

# The same, on an explicit <project> that need not be in the home's projects/.
spawn_on_project() {  # <home> <fakebin> <pool-slot> <id> <project> [args...]
  local home=$1 fakebin=$2 slot=$3 id=$4 project=$5
  shift 5
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$project" > "$home/pane-cwd"
  : > "$home/pane-typed.log"
  SPAWN_OUT=$(FM_FAKE_PANE_CWD_FILE="$home/pane-cwd" \
    FM_FAKE_PANE_TYPED_LOG="$home/pane-typed.log" \
    FM_FAKE_POOL_SLOT="$slot" \
    fm_test_run_spawn "$home" "" "$fakebin" "$id" "$project" --scout "$@")
  SPAWN_RC=$?
}

common_dir() {  # <path>
  (cd "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)
}

recorded_worktree() {  # <home> <id>
  sed -n 's/^worktree=//p' "$1/state/$2.meta"
}

test_two_secondmate_homes_each_spawn_from_their_own_clone() {
  local case_dir fakebin home_a home_b slot wt_a wt_b
  case_dir="$TMP_ROOT/two-homes"
  mkdir -p "$case_dir"
  make_origin "$case_dir"
  home_a=$(make_home "$case_dir" home-a mate-a claude)
  home_b=$(make_home "$case_dir" home-b mate-b claude)
  slot=$(make_pool "$case_dir" "$home_a/projects/agents")
  advance_origin "$case_dir"
  fakebin=$(make_shell_pane_fakebin "$case_dir/fake")

  # The collision this suite exists for: the shared slot belongs to home A's
  # clone, so it is no copy of home B's.
  [ "$(common_dir "$slot")" = "$(common_dir "$home_a/projects/agents")" ] \
    || fail "fixture pool slot is not bound to home A's clone"
  [ "$(common_dir "$slot")" != "$(common_dir "$home_b/projects/agents")" ] \
    || fail "fixture pool slot unexpectedly belongs to home B's clone"

  spawn_in_home "$home_b" "$fakebin" "$slot" clone-b-r1
  expect_code 0 "$SPAWN_RC" \
    "the second secondmate home should spawn a worker on a project another home also clones"$'\n'"$SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned clone-b-r1" "home B's spawn did not report success"
  wt_b=$(recorded_worktree "$home_b" clone-b-r1)
  [ -n "$wt_b" ] && [ -d "$wt_b" ] || fail "home B recorded no usable worktree: '$wt_b'"
  [ "$(common_dir "$wt_b")" = "$(common_dir "$home_b/projects/agents")" ] \
    || fail "home B's worktree is not a copy of home B's own clone: $wt_b"
  [ "$(cd "$wt_b" && pwd -P)" != "$(cd "$slot" && pwd -P)" ] \
    || fail "home B was handed the shared pool slot"
  assert_no_grep 'treehouse get' "$home_b/pane-typed.log" \
    "a secondmate home still asked the shared pool for its copy"
  [ "$(git -C "$wt_b" rev-parse HEAD)" = "$(git -C "$wt_b" rev-parse origin/main)" ] \
    || fail "home B's copy did not start from current origin/main"
  [ -f "$wt_b/advanced-main.txt" ] || fail "home B's copy is missing the advanced origin content"

  spawn_in_home "$home_a" "$fakebin" "$slot" clone-a-r1
  expect_code 0 "$SPAWN_RC" "the first secondmate home should spawn too"$'\n'"$SPAWN_OUT"
  wt_a=$(recorded_worktree "$home_a" clone-a-r1)
  [ "$(common_dir "$wt_a")" = "$(common_dir "$home_a/projects/agents")" ] \
    || fail "home A's worktree is not a copy of home A's own clone: $wt_a"
  [ "$(cd "$wt_a" && pwd -P)" != "$(cd "$wt_b" && pwd -P)" ] \
    || fail "two homes were given the same copy"
  [ "$(cd "$wt_a" && pwd -P)" != "$(cd "$slot" && pwd -P)" ] \
    || fail "home A was handed the shared pool slot"
  assert_no_grep 'treehouse get' "$home_a/pane-typed.log" \
    "the first secondmate home still asked the shared pool for its copy"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# home B worktree=%s common=%s\n' "$wt_b" "$(common_dir "$wt_b")"
    printf '# home A worktree=%s common=%s\n' "$wt_a" "$(common_dir "$wt_a")"
    printf '# shared pool slot=%s common=%s\n' "$slot" "$(common_dir "$slot")"
  fi
  pass "two secondmate homes with clones of one remote each spawn from their own clone"
}

test_main_home_still_takes_its_copy_from_the_pool() {
  local case_dir fakebin home slot wt
  case_dir="$TMP_ROOT/main-home"
  mkdir -p "$case_dir"
  make_origin "$case_dir"
  home=$(make_home "$case_dir" main "" codex)
  slot=$(make_pool "$case_dir" "$home/projects/agents")
  fakebin=$(make_shell_pane_fakebin "$case_dir/fake")

  spawn_in_home "$home" "$fakebin" "$slot" main-pool-r1
  expect_code 0 "$SPAWN_RC" "the main home should still spawn from its pool"$'\n'"$SPAWN_OUT"
  assert_grep 'treehouse get' "$home/pane-typed.log" "the main home stopped asking its pool for a copy"
  wt=$(recorded_worktree "$home" main-pool-r1)
  [ "$(cd "$wt" && pwd -P)" = "$(cd "$slot" && pwd -P)" ] \
    || fail "the main home did not record the pool slot: $wt"
  pass "the main home still takes its copy from the pool"
}

# The scope of the fix: a project-less secondmate home, whose crews work on the
# firstmate repo itself, holds no clone of its own, so its pool cannot belong
# to a different clone. It must keep taking pooled copies as its seed contract
# documents; only a clone inside a home's own projects/ stops pooling.
test_project_less_secondmate_home_keeps_its_pool() {
  local case_dir fakebin home repo slot wt
  case_dir="$TMP_ROOT/project-less"
  mkdir -p "$case_dir"
  make_origin "$case_dir"
  git clone --quiet "file://$case_dir/origin.git" "$case_dir/firstmate-repo"
  repo="$case_dir/firstmate-repo"
  fm_test_spawn_home "$case_dir/home" codex
  home="$case_dir/home"
  printf 'mate-p\n' > "$home/.fm-secondmate-home"
  [ -z "$(ls -A "$home/projects")" ] || fail "fixture project-less home holds a clone"
  slot=$(make_pool "$case_dir" "$repo")
  fakebin=$(make_shell_pane_fakebin "$case_dir/fake")

  spawn_on_project "$home" "$fakebin" "$slot" pool-less-r1 "$repo"
  expect_code 0 "$SPAWN_RC" "a project-less secondmate home should still spawn from its pool"$'\n'"$SPAWN_OUT"
  assert_grep 'treehouse get' "$home/pane-typed.log" \
    "a project-less secondmate home stopped asking its pool for a copy"
  wt=$(recorded_worktree "$home" pool-less-r1)
  [ "$(cd "$wt" && pwd -P)" = "$(cd "$slot" && pwd -P)" ] \
    || fail "the project-less home did not record its pool slot: $wt"
  [ ! -e "$home/user-home/.fm-worktrees" ] \
    || fail "the project-less home made a clone copy it has no clone for"
  pass "a project-less secondmate home keeps its documented pool"
}

test_existing_copy_path_is_never_reused() {
  local case_dir fakebin home wt
  case_dir="$TMP_ROOT/no-reuse"
  mkdir -p "$case_dir"
  make_origin "$case_dir"
  home=$(make_home "$case_dir" home-c mate-c codex)
  fakebin=$(make_shell_pane_fakebin "$case_dir/fake")

  spawn_in_home "$home" "$fakebin" /nonexistent reuse-r1
  expect_code 0 "$SPAWN_RC" "the first spawn should succeed"$'\n'"$SPAWN_OUT"
  wt=$(recorded_worktree "$home" reuse-r1)
  printf 'work in progress\n' > "$wt/wip.txt"
  mv "$home/state/reuse-r1.meta" "$home/state/reuse-r1.meta.kept"

  spawn_in_home "$home" "$fakebin" /nonexistent reuse-r1
  [ "$SPAWN_RC" -ne 0 ] || fail "a second spawn adopted a copy another task already made"
  assert_contains "$SPAWN_OUT" "already exists" "the refusal did not name the existing copy"
  [ -f "$wt/wip.txt" ] || fail "the refused spawn disturbed the existing copy's work"
  pass "a copy already made for a task id is never handed to another spawn"
}

test_aborted_spawn_removes_the_copy_it_made() {
  local case_dir fakebin home clone before after
  case_dir="$TMP_ROOT/abort"
  mkdir -p "$case_dir"
  make_origin "$case_dir"
  home=$(make_home "$case_dir" home-d mate-d codex)
  clone="$home/projects/agents"
  fakebin=$(make_shell_pane_fakebin "$case_dir/fake")
  # An unusable origin makes the base refresh refuse after the copy exists.
  git -C "$clone" remote set-url origin "file://$case_dir/missing.git"
  before=$(git -C "$clone" worktree list --porcelain | grep -c '^worktree ')

  spawn_in_home "$home" "$fakebin" /nonexistent abort-r1
  [ "$SPAWN_RC" -ne 0 ] || fail "spawn launched against an unusable origin"
  assert_contains "$SPAWN_OUT" "could not fetch origin" "the abort did not come from the base refresh"
  [ ! -e "$home/state/abort-r1.meta" ] || fail "the aborted spawn published task metadata"
  after=$(git -C "$clone" worktree list --porcelain | grep -c '^worktree ')
  [ "$after" = "$before" ] || fail "the aborted spawn left its copy registered with the clone"
  [ -z "$(find "$home/user-home/.fm-worktrees" -mindepth 2 -maxdepth 2 -name abort-r1 2>/dev/null)" ] \
    || fail "the aborted spawn left its copy on disk"
  pass "an aborted spawn removes the copy it made"
}

test_teardown_removes_the_copy_and_refuses_unlanded_work() {
  local case_dir fakebin home clone wt out rc
  case_dir="$TMP_ROOT/teardown"
  mkdir -p "$case_dir"
  make_origin "$case_dir"
  home=$(make_home "$case_dir" home-e mate-e codex)
  clone="$home/projects/agents"
  fakebin=$(make_shell_pane_fakebin "$case_dir/fake")

  spawn_in_home "$home" "$fakebin" /nonexistent tear-r1
  expect_code 0 "$SPAWN_RC" "spawn should succeed"$'\n'"$SPAWN_OUT"
  wt=$(recorded_worktree "$home" tear-r1)
  sed -i.bak 's/^kind=scout$/kind=ship/' "$home/state/tear-r1.meta" && rm -f "$home/state/tear-r1.meta.bak"
  printf 'unlanded\n' > "$wt/unlanded.txt"

  out=$(teardown_in_home "$home" "$fakebin" tear-r1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "teardown removed a copy holding uncommitted work"$'\n'"$out"
  assert_contains "$out" "REFUSED" "teardown did not refuse the uncommitted work"
  [ -f "$wt/unlanded.txt" ] || fail "the refused teardown discarded the uncommitted work"

  rm -f "$wt/unlanded.txt"
  out=$(teardown_in_home "$home" "$fakebin" tear-r1)
  rc=$?
  expect_code 0 "$rc" "teardown should remove a clean copy"$'\n'"$out"
  [ ! -e "$wt" ] || fail "teardown left the copy on disk: $wt"
  ! git -C "$clone" worktree list --porcelain | grep -qxF "worktree $wt" \
    || fail "teardown left the copy registered with the clone"
  assert_not_contains "$out" "treehouse return" "teardown tried to return a clone copy to the pool"
  pass "teardown refuses unlanded work, then removes a clean copy from its own clone"
}

teardown_in_home() {  # <home> <fakebin> <id>
  local home=$1 fakebin=$2 id=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_PANE_CWD_FILE="$home/pane-cwd" FM_FAKE_PANE_TYPED_LOG="$home/pane-typed.log" \
    FM_FAKE_POOL_SLOT=/nonexistent TMUX="${TMUX:-fake,1,0}" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1
}

test_two_secondmate_homes_each_spawn_from_their_own_clone
test_main_home_still_takes_its_copy_from_the_pool
test_project_less_secondmate_home_keeps_its_pool
test_existing_copy_path_is_never_reused
test_aborted_spawn_removes_the_copy_it_made
test_teardown_removes_the_copy_and_refuses_unlanded_work

echo "# all fm-spawn-secondmate-clone-worktree tests passed"
