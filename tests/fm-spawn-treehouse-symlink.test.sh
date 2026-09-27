#!/usr/bin/env bash
# Regression test for spawning from a symlinked treehouse pool root.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-symlink)
export FM_BACKEND=tmux

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN" \
    "$id" "$PROJECT_DIR" "$@" 2>&1
}

make_case() {
  local name=$1 id=$2 case_dir home project pool fakebin
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
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

read_case_record() {
  local IFS='|'
  read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN <<< "$1"
  PATH="$FAKEBIN:$PATH"
}

test_symlinked_pool_slot() {
  local rec id out status pool_real pool_symlink slot_root slot_symlink
  id='symlink-pool-r1'
  rec=$(make_case symlink-pool "$id")
  read_case_record "$rec"

  # Create a real pool directory
  pool_real="$CASE_DIR/real-pool"
  mkdir -p "$pool_real"

  # Symlink to the real pool to simulate relocated treehouse
  pool_symlink="$CASE_DIR/symlink-pool"
  ln -s "$pool_real" "$pool_symlink"

  # Slot inside the real pool
  slot_root="$pool_real/slots"
  mkdir -p "$slot_root/1"
  git -C "$PROJECT_DIR" worktree add "$slot_root/1/project"
  
  # Write treehouse state using the SYMLINKED path
  slot_symlink="$pool_symlink/slots/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot_symlink" \
    > "$slot_root/treehouse-state.json"
    
  # Pass the real physical worktree path to spawn (which is what spawn sees after cd)
  POOL_DIR="$slot_root/1/project"
  
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn from a symlinked Treehouse slot should launch"$'\n'"$out"
  
  # Assert the recorded path is the canonical symlink path, not the real one
  assert_grep "worktree=$slot_symlink" "$HOME_DIR/state/$id.meta" \
    "spawn did not record the canonical symlinked Treehouse path: $(cat "$HOME_DIR/state/$id.meta")"
    
  pass "a symlinked Treehouse slot records the canonical registry path"
}

test_unmanaged_pool_slot_refused() {
  local rec id out status pool_real slot_root
  id='unmanaged-pool-r1'
  rec=$(make_case unmanaged-pool "$id")
  read_case_record "$rec"

  # Create a real pool directory
  pool_real="$CASE_DIR/real-pool"
  mkdir -p "$pool_real"

  # Slot inside the real pool
  slot_root="$pool_real/slots"
  mkdir -p "$slot_root/1"
  git -C "$PROJECT_DIR" worktree add "$slot_root/1/project"
  
  # Write treehouse state but do NOT include this path!
  printf '{"worktrees":[{"name":"1","path":"/some/other/path"}]}\n' \
    > "$slot_root/treehouse-state.json"
    
  POOL_DIR="$slot_root/1/project"
  
  out=$(run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker on a slot not present in treehouse registry"
  assert_contains "$out" "could not resolve Treehouse registry path" \
    "spawn did not refuse the unmanaged worktree with the correct error"
    
  pass "an unmanaged Treehouse slot is refused at spawn time"
}

# Run the test
test_symlinked_pool_slot
test_unmanaged_pool_slot_refused
echo "# all fm-spawn-treehouse-symlink tests passed"
