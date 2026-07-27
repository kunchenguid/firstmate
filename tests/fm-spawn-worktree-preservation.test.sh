#!/usr/bin/env bash
# Regression test for the isolated-copy preservation boundary in
# bin/fm-spawn.sh (acquire_leased_task_worktree and the worktree-entry branch).
#
# The breach this pins: a task worktree held only by an interactive
# `treehouse get` subshell lives exactly as long as that subshell. A pane falls
# back to that subshell the moment its agent exits normally - the ordinary end
# of a non-Claude harness session - and treehouse then offers to clean and
# return the worktree with an AFFIRMATIVE default, so a single stray Enter
# recycles the pool slot and deletes every untracked file in it (a handoff note,
# a scratch repro, an unstaged fix). Nothing in the agent's exit is abnormal and
# firstmate's record still claims the worktree, so the loss is silent.
#
# The fix acquires a DURABLE LEASE and sends the pane in with cd, so no
# agent-exit path can return or clean the copy at all. The first case proves
# both halves against real treehouse in a throwaway pool; the rest pin the
# acquisition contract with fakes so they run everywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-preservation)

# --- real treehouse: the exit path, unprotected vs protected -----------------

# make_pool_repo <dir>: a throwaway repo whose treehouse pool lives inside it,
# so nothing outside this fixture is ever acquired, cleaned, or returned.
make_pool_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
  printf 'root = "./"\nmax_trees = 2\n' > "$dir/treehouse.toml"
  git -C "$dir" add treehouse.toml
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'treehouse pool config'
}

test_real_treehouse_exit_paths() {
  local repo wt_interactive wt_leased
  if ! command -v treehouse >/dev/null 2>&1; then
    echo "skip: treehouse not found (real acquisition/exit comparison)"
    return 0
  fi
  if ! command -v script >/dev/null 2>&1; then
    echo "skip: script not found (a pty is required to answer treehouse's exit prompt)"
    return 0
  fi
  repo="$TMP_ROOT/pool/repo"
  make_pool_repo "$repo"

  # Unprotected shape (what fm-spawn used to do): the worktree is held by the
  # interactive subshell. Exiting it answers the clean-and-return prompt with
  # its affirmative default and the untracked file is gone.
  ( cd "$repo" && script -qec "printf 'echo note > handoff.md; exit\n\n' | treehouse get" /dev/null ) \
    >/dev/null 2>&1
  wt_interactive=$(find "$repo/.treehouse" -maxdepth 3 -type d -name "$(basename "$repo")" | head -n 1)
  [ -n "$wt_interactive" ] || fail "real treehouse did not create a pool worktree"
  assert_absent "$wt_interactive/handoff.md" \
    "real treehouse kept the untracked file after a subshell exit - the fixture no longer reproduces the breach"

  # Protected shape (what fm-spawn does now): the worktree is durably leased and
  # entered with cd, so the same shell exit changes nothing.
  wt_leased=$( cd "$repo" && treehouse get --lease --lease-holder fm-preservation-test )
  [ -n "$wt_leased" ] || fail "treehouse get --lease did not report a worktree"
  ( cd "$repo" && script -qec "printf 'cd $wt_leased; echo note > handoff.md; exit\n\n' | bash -i" /dev/null ) \
    >/dev/null 2>&1
  assert_present "$wt_leased/handoff.md" \
    "REGRESSION: a shell exit deleted untracked content from a LEASED worktree"
  assert_contains "$( cd "$repo" && treehouse status )" leased \
    "the leased worktree was returned to the pool by a shell exit"
  pass "real treehouse: a subshell exit destroys untracked content, a leased copy entered with cd survives it"
}

test_real_treehouse_adopts_unleased_copy_without_writing_it() {
  local repo fifo transcript holder_pid wt id home fakebin before out
  if ! command -v treehouse >/dev/null 2>&1 || ! command -v script >/dev/null 2>&1; then
    echo "skip: treehouse or script not found (real legacy adoption)"
    return 0
  fi
  repo="$TMP_ROOT/adoption-pool/repo"
  home="$TMP_ROOT/adoption-pool/home"
  id=preservation-adopt-real
  make_pool_repo "$repo"
  mkdir -p "$home/state" "$home/config"
  fakebin=$(fm_fakebin "$TMP_ROOT/adoption-pool/fake")
  ln -s "$(command -v treehouse)" "$fakebin/treehouse"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fifo="$TMP_ROOT/adoption-pool/input"
  transcript="$TMP_ROOT/adoption-pool/transcript"
  mkfifo "$fifo"
  exec 9<>"$fifo"
  ( cd "$repo" && script -qec "treehouse get" /dev/null < "$fifo" > "$transcript" 2>&1 ) &
  holder_pid=$!
  printf 'printf "legacy bytes\\n" > handoff.md\n' >&9
  wt=
  for _ in $(seq 1 30); do
    wt=$(cd "$repo" && treehouse status --json | jq -r '.[] | select(.status == "in-use") | .path' 2>/dev/null | head -n 1)
    [ -z "$wt" ] || break
    sleep 0.1
  done
  if [ -z "$wt" ]; then
    kill "$holder_pid" 2>/dev/null || true
    exec 9>&-
    fail "real treehouse did not expose an in-use legacy worktree"
  fi
  for _ in $(seq 1 30); do
    [ -f "$wt/handoff.md" ] && break
    sleep 0.1
  done
  assert_present "$wt/handoff.md" "interactive legacy copy did not receive handoff.md"
  before=$(sha256sum "$wt/handoff.md")
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$repo" "kind=ship" "harness=codex"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-adopt-worktree.sh" "$id" 2>&1)
  expect_code 0 "$?" "real unleased legacy copy should be adoptable: $out"
  [ "$before" = "$(sha256sum "$wt/handoff.md")" ] \
    || fail "REGRESSION: adoption changed the real legacy handoff.md"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  exec 9>&-
  pass "real treehouse: adoption preserves an unleased in-use copy byte-for-byte"
}

# --- acquisition contract (fakes; runs everywhere) ---------------------------

make_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/project"
  CASE_WT="$case_dir/wt"
  CASE_FAKEBIN=$(fm_fakebin "$case_dir/fake")
  CASE_SENT_FILE="$case_dir/pane-sent"
  CASE_TREEHOUSE_LOG="$case_dir/treehouse-calls"
  mkdir -p "$CASE_HOME/data" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'codex\n' > "$CASE_HOME/config/crew-harness"
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  mkdir -p "$CASE_HOME/data/$id"
  printf 'brief for %s\n' "$id" > "$CASE_HOME/data/$id/brief.md"
  cat > "$CASE_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*) printf 'bash\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    for arg in "$@"; do
      case "$arg" in
        send-keys|-t|-l|Enter|"%"*|firstmate:*) ;;
        *) printf '%s\n' "$arg" >> "${FM_FAKE_SENT_FILE:-/dev/null}" ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$CASE_FAKEBIN/tmux"
  fm_fake_treehouse "$CASE_FAKEBIN"
  : > "$CASE_SENT_FILE"
  : > "$CASE_TREEHOUSE_LOG"
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$CASE_WT" FM_FAKE_LEASE_PATH="$CASE_WT" \
    FM_FAKE_SENT_FILE="$CASE_SENT_FILE" FM_FAKE_TREEHOUSE_LOG="$CASE_TREEHOUSE_LOG" \
    FM_FAKE_TREEHOUSE_FAIL="${FM_FAKE_TREEHOUSE_FAIL:-0}" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CASE_PROJ" 2>&1
}

# The worktree must be leased under the task's own holder, and the pane must be
# sent in with cd - never through the interactive subshell whose exit can clean
# and return the copy.
test_spawn_leases_and_never_uses_the_interactive_subshell() {
  local id out status
  id=preserve-lease-b1
  make_case lease "$id"
  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed: $out"
  assert_grep "get --lease --lease-holder fm-$id" "$CASE_TREEHOUSE_LOG" \
    "spawn did not durably lease its worktree"
  assert_no_grep 'treehouse get' "$CASE_SENT_FILE" \
    "REGRESSION: the pane was sent into an interactive treehouse subshell whose exit can clean and return the copy"
  assert_grep "cd '$CASE_WT'" "$CASE_SENT_FILE" "spawn did not send the pane into the leased worktree with cd"
  assert_grep "worktree=$CASE_WT" "$CASE_HOME/state/$id.meta" "spawn did not record the leased worktree"
  pass "a spawn leases its worktree and enters it with cd, never through the exit-sensitive subshell"
}

# A lease that cannot be taken is terminal: never fall back to the interactive
# form, and never record or launch a task without a durable copy.
test_failed_lease_refuses_without_fallback() {
  local id out status
  id=preserve-leasefail-b2
  make_case leasefail "$id"
  out=$(FM_FAKE_TREEHOUSE_FAIL=1 run_spawn "$id")
  status=$?
  expect_code 1 "$status" "a failed lease should refuse the spawn"
  assert_contains "$out" 'treehouse get --lease failed' "refusal did not name the failed lease"
  assert_no_grep 'treehouse get' "$CASE_SENT_FILE" \
    "REGRESSION: a failed lease fell back to the interactive treehouse subshell"
  assert_absent "$CASE_HOME/state/$id.meta" "a failed lease still recorded the task"
  pass "a failed lease refuses the spawn instead of falling back to the exit-sensitive subshell"
}

# An aborted spawn may release only a lease it just took, and only while the
# copy holds nothing: an automatic return must never delete work.
test_abort_never_returns_a_dirty_copy() {
  local id out status
  id=preserve-abort-b3
  make_case abort "$id"
  # Content the worker would lose, plus a pane that never settles into the
  # leased copy so the spawn aborts after the lease was taken.
  printf 'handoff\n' > "$CASE_WT/handoff.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$CASE_PROJ" FM_FAKE_LEASE_PATH="$CASE_WT" \
    FM_FAKE_SENT_FILE="$CASE_SENT_FILE" FM_FAKE_TREEHOUSE_LOG="$CASE_TREEHOUSE_LOG" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$CASE_PROJ" 2>&1)
  status=$?
  expect_code 1 "$status" "a pane that never enters the leased worktree should abort the spawn"
  assert_present "$CASE_WT/handoff.md" "REGRESSION: an aborted spawn returned a copy holding untracked content"
  assert_no_grep 'return --force' "$CASE_TREEHOUSE_LOG" \
    "REGRESSION: an aborted spawn returned a copy that still held untracked content"
  assert_contains "$out" 'leaving it leased' "the abort did not report why the copy stayed leased"
  pass "an aborted spawn never returns a leased copy that holds uncommitted or untracked content"
}

test_real_treehouse_exit_paths
test_real_treehouse_adopts_unleased_copy_without_writing_it
test_spawn_leases_and_never_uses_the_interactive_subshell
test_failed_lease_refuses_without_fallback
test_abort_never_returns_a_dirty_copy

echo "# all fm-spawn-worktree-preservation tests passed"
