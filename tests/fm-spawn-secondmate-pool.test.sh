#!/usr/bin/env bash
# Regression tests for which Treehouse pool a ship or scout spawn draws from.
#
# Treehouse names a pool from the repository basename and origin URL alone, so a
# secondmate home's standalone clone of a project resolves to the same default
# pool as the root home's clone, and that pool's slots are worktrees of the root
# home's clone. A secondmate spawn that took one was refused at Claude trust
# registration as "not a worktree of project". These tests drive the real spawn
# path with a fake terminal that answers the typed `treehouse get` the way
# Treehouse resolves pools: the default root hands out the shared pool's slot,
# and an explicit --root grows a slot from the pane's clone under that root.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-pool)

make_pool_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -s "$FM_FAKE_PANE_FILE" ]; then
      cat "$FM_FAKE_PANE_FILE"
    else
      printf '%s\n' "$FM_FAKE_PANE_PATH"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    text=${4:-}
    case "$text" in
      'treehouse get')
        printf '%s\n' "$text" >> "$FM_FAKE_TREEHOUSE_LOG"
        printf '%s\n' "$FM_FAKE_DEFAULT_SLOT" > "$FM_FAKE_PANE_FILE"
        ;;
      "treehouse --root '"*"' get")
        printf '%s\n' "$text" >> "$FM_FAKE_TREEHOUSE_LOG"
        root=${text#"treehouse --root '"}
        root=${root%"' get"}
        pool="$root/.treehouse/project-pool"
        slot="$pool/1/project"
        mkdir -p "$pool"
        printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
        git -C "$FM_FAKE_PANE_PATH" worktree add --quiet --detach "$slot" >/dev/null 2>&1 || exit 1
        printf '%s\n' "$slot" > "$FM_FAKE_PANE_FILE"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

make_main_home() {  # <case-dir>
  local case_dir=$1 main pool slot
  main="$case_dir/main-home"
  pool="$case_dir/treehouse/project-pool"
  slot="$pool/1/project"
  fm_test_spawn_home "$main" claude
  fm_git_init_commit "$main/projects/project"
  fm_git_add_origin "$main/projects/project" "$case_dir/origin.git"
  mkdir -p "$pool"
  printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
  git -C "$main/projects/project" worktree add --quiet --detach "$slot"
}

make_mate_home() {  # <case-dir> <route>
  local case_dir=$1 route=$2 mate
  mate="$case_dir/mate-home"
  fm_test_spawn_home "$mate" claude
  git clone --quiet "file://$case_dir/origin.git" "$mate/projects/project"
  if [ "$route" = local ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
      "$case_dir/main-home" > "$mate/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=parent-machine\n' \
      > "$mate/.fm-secondmate-parent"
  fi
}

run_pool_spawn() {  # <case-dir> <home> <id>
  local case_dir=$1 home=$2 id=$3
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/treehouse.log"
  rm -f "$case_dir/pane"
  FM_FAKE_PANE_FILE="$case_dir/pane" \
    FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    FM_FAKE_DEFAULT_SLOT="$case_dir/treehouse/project-pool/1/project" \
    fm_test_run_spawn "$home" "$home/projects/project" "$case_dir/fake/fakebin" \
    "$id" "$home/projects/project" --scout
}

common_dir_of() {
  CDPATH='' cd -- "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" && pwd -P
}

meta_worktree() {  # <home> <id>
  sed -n 's/^worktree=//p' "$1/state/$2.meta"
}

test_local_secondmate_spawns_from_its_own_clone_pool() {
  local case_dir id out status wt mate state
  case_dir="$TMP_ROOT/local-mate"
  id='mate-pool-own-clone-s1'
  make_pool_fakebin "$case_dir/fake" >/dev/null
  make_main_home "$case_dir"
  make_mate_home "$case_dir" local
  mate="$case_dir/mate-home"
  state=$(CDPATH='' cd -- "$mate/state" && pwd -P)

  out=$(run_pool_spawn "$case_dir" "$mate" "$id")
  status=$?
  expect_code 0 "$status" "a local secondmate spawn should launch from its own clone's pool"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the secondmate spawn did not report success"
  assert_not_contains "$out" "not a worktree of project" \
    "the secondmate spawn was handed another clone's slot"
  [ "$(cat "$case_dir/treehouse.log")" = "treehouse --root '$state/treehouse' get" ] \
    || fail "the secondmate spawn did not root its pool in its own state: $(cat "$case_dir/treehouse.log")"
  wt=$(meta_worktree "$mate" "$id")
  case "$wt" in
    "$state/treehouse/"*) ;;
    *) fail "the secondmate spawn recorded a worktree outside its own pool: $wt" ;;
  esac
  [ "$(common_dir_of "$wt")" = "$(common_dir_of "$mate/projects/project")" ] \
    || fail "the secondmate slot is not a worktree of the secondmate's own clone"
  [ -f "$(dirname "$wt")/.fm-slot-owner" ] \
    || fail "the secondmate spawn did not claim its own pool slot"
  pass "a local secondmate spawn takes its slot from a pool of its own clone"
}

test_root_home_keeps_the_default_pool() {
  local case_dir id out status main
  case_dir="$TMP_ROOT/root-home"
  id='main-pool-default-s2'
  make_pool_fakebin "$case_dir/fake" >/dev/null
  make_main_home "$case_dir"
  main="$case_dir/main-home"

  out=$(run_pool_spawn "$case_dir" "$main" "$id")
  status=$?
  expect_code 0 "$status" "a root-home spawn should launch from the default pool"$'\n'"$out"
  [ "$(cat "$case_dir/treehouse.log")" = "treehouse get" ] \
    || fail "the root-home spawn changed its pool command: $(cat "$case_dir/treehouse.log")"
  assert_grep "worktree=$case_dir/treehouse/project-pool/1/project" "$main/state/$id.meta" \
    "the root-home spawn did not take the default pool's slot"
  [ ! -e "$main/state/treehouse" ] || fail "the root-home spawn created a home-scoped pool root"
  pass "a root-home spawn keeps Treehouse's default pool"
}

test_remote_seeded_home_keeps_the_default_pool() {
  local case_dir id out status mate
  case_dir="$TMP_ROOT/remote-mate"
  id='remote-pool-default-s3'
  make_pool_fakebin "$case_dir/fake" >/dev/null
  make_main_home "$case_dir"
  make_mate_home "$case_dir" remote
  mate="$case_dir/mate-home"

  out=$(run_pool_spawn "$case_dir" "$mate" "$id")
  status=$?
  [ "$(cat "$case_dir/treehouse.log")" = "treehouse get" ] \
    || fail "a remote-seeded home, the root of its own machine, left the default pool: $(cat "$case_dir/treehouse.log")"
  [ ! -e "$mate/state/treehouse" ] || fail "a remote-seeded home created a home-scoped pool root"
  [ "$status" -ne 0 ] || fail "the shared default slot here belongs to another clone and must still be refused"
  assert_contains "$out" "not a worktree of project" \
    "a slot of another clone was not refused by the worktree-of-project check"
  pass "a remote-seeded home keeps the default pool and the worktree-of-project check stays intact"
}

test_local_secondmate_spawns_from_its_own_clone_pool
test_root_home_keeps_the_default_pool
test_remote_seeded_home_keeps_the_default_pool

echo "# all fm-spawn-secondmate-pool tests passed"
