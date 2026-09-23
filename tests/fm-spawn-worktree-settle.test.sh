#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    case "$*" in
      *codex*) [ -z "${FM_FAKE_WORKER_LAUNCH:-}" ] || : > "$FM_FAKE_WORKER_LAUNCH" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_WORKER_LAUNCH="${FM_FAKE_WORKER_LAUNCH:-}" \
    FM_ACCOUNT_TASK_WORKSPACE_ROOT="${FM_ACCOUNT_TASK_WORKSPACE_ROOT:-}" \
    FM_REAL_TASKS_AXI="${FM_REAL_TASKS_AXI:-}" \
    FM_TEST_COMMIT_META="${FM_TEST_COMMIT_META:-}" \
    FM_TEST_COMMIT_OBSERVED="${FM_TEST_COMMIT_OBSERVED:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 2 ] || fail "already-settled pane took $reads reads to confirm - expected the first read plus one confirmation"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# A restricted receiver pins a workspace root before invoking fm-spawn.
# The real spawn path must enforce that root after Treehouse settles but before
# publishing metadata or launching the worker.
test_restricted_account_workspace_root_is_enforced() {
  local rec id out status approved
  id=settle-account-root-z5
  rec=$(make_settle_case settle-account-root "$id" 0)
  read_settle_record "$rec"
  approved="$TMP_ROOT/settle-account-root/approved"
  mkdir -p "$approved"

  out=$(FM_ACCOUNT_TASK_WORKSPACE_ROOT="$approved" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "restricted spawn accepted a worktree outside its qualified root"
  assert_contains "$out" "outside its qualified workspace root" \
    "restricted spawn did not name the workspace-root refusal"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "restricted workspace refusal published task metadata"
  pass "restricted account-task spawn refuses a worktree outside its qualified root before launch"
}

test_restricted_account_workspace_root_must_be_ancestor() {
  local rec id out status launch_marker
  id=settle-account-exact-root-z6
  rec=$(make_settle_case settle-account-exact-root "$id" 0)
  read_settle_record "$rec"
  launch_marker="$TMP_ROOT/settle-account-exact-root/worker-launched"

  out=$(FM_ACCOUNT_TASK_WORKSPACE_ROOT="$WT_DIR" \
    FM_FAKE_WORKER_LAUNCH="$launch_marker" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "restricted spawn accepted its qualified root as its worktree"
  assert_contains "$out" "outside its qualified workspace root" \
    "restricted spawn did not reject a worktree equal to the workspace root"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "exact-root refusal published task metadata"
  [ ! -e "$launch_marker" ] || fail "exact-root refusal launched a worker"
  pass "restricted account-task spawn requires a strict workspace-root descendant"
}

test_restricted_account_launch_publishes_commit_receipt() {
  local rec id out status spawn_gen commit real_tasks
  id=settle-account-commit-z7
  rec=$(make_settle_case settle-account-commit "$id" 0)
  read_settle_record "$rec"
  real_tasks=$(command -v tasks-axi) || fail "tasks-axi is required for the commit-boundary regression"
  touch "$HOME_DIR/data/backlog.md"
  TASKS_AXI_BACKEND=markdown "$real_tasks" add "$id" "Account commit boundary" \
    --file "$HOME_DIR/data/backlog.md" >/dev/null || fail "could not prepare the account-task backlog row"
  cat > "$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = start ]; then
  spawn_gen=$(sed -n 's/^spawn_gen=//p' "$FM_TEST_COMMIT_META")
  commit=$(sed -n 's/^account_task_commit=//p' "$FM_TEST_COMMIT_META")
  [ -n "$spawn_gen" ] && [ "$commit" = "$spawn_gen" ] || exit 86
  : > "$FM_TEST_COMMIT_OBSERVED"
fi
exec "$FM_REAL_TASKS_AXI" "$@"
SH
  chmod +x "$FAKEBIN_DIR/tasks-axi"

  out=$(TASKS_AXI_BACKEND=markdown \
    FM_REAL_TASKS_AXI="$real_tasks" \
    FM_TEST_COMMIT_META="$HOME_DIR/state/$id.meta" \
    FM_TEST_COMMIT_OBSERVED="$TMP_ROOT/settle-account-commit/commit-observed" \
    FM_ACCOUNT_TASK_WORKSPACE_ROOT="$TMP_ROOT/settle-account-commit" \
    run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "restricted spawn should commit a qualified worktree launch"$'\n'"$out"
  spawn_gen=$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$id.meta")
  commit=$(sed -n 's/^account_task_commit=//p' "$HOME_DIR/state/$id.meta")
  [ -n "$spawn_gen" ] || fail "restricted spawn omitted its generation"
  [ "$commit" = "$spawn_gen" ] || fail "restricted spawn did not bind its final commit receipt to the generation"
  [ -e "$TMP_ROOT/settle-account-commit/commit-observed" ] \
    || fail "the final backlog transition did not observe the generation-bound receipt"
  pass "restricted account-task spawn publishes a generation-bound final commit receipt"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_restricted_account_workspace_root_is_enforced
test_restricted_account_workspace_root_must_be_ancestor
test_restricted_account_launch_publishes_commit_receipt

echo "# all fm-spawn-worktree-settle tests passed"
