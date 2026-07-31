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
# Also covers upstream issue 1336: when the settle loop expires (the pane never
# enters a worktree, as when treehouse get refuses), the failed spawn must
# still leave state/<id>.meta and a failed: line in state/<id>.status so the
# ordinary terminal-state reap path can see it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
  list-windows)
    [ -z "${FM_FAKE_EXISTING_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_EXISTING_WINDOW"
    exit 0
    ;;
  new-window)
    printf '@1\n'
    [ "${FM_FAKE_NEW_WINDOW_FAIL_AFTER_CREATE:-0}" != 1 ]
    exit
    ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
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
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1 pane_path=${2:-$WT_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane_path" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

run_settle_teardown() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1
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

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep

# Upstream issue 1336: a bootstrap that fails after the pane exists (here the
# pane never leaves the project, as when treehouse get refuses on an exhausted
# pool) must still leave a meta record and a failed: status line, so the failed
# spawn presents as an ordinary terminal state the same reap path handles
# instead of an invisible orphan pane.
test_failed_bootstrap_leaves_meta_and_failed_status() {
  local rec id out rc
  id=settle-never-settles-z3
  rec=$(make_settle_case settle-never "$id" 0)
  read_settle_record "$rec"

  rc=0
  out=$(FM_SPAWN_WORKTREE_POLLS=2 run_settle_spawn "$id" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a pane that never enters a worktree should fail the spawn"
  assert_contains "$out" "did not enter a worktree" "spawn failure lost its diagnostic"
  [ -e "$HOME_DIR/state/$id.meta" ] \
    || fail "failed spawn left no meta record behind"
  assert_grep "window=" "$HOME_DIR/state/$id.meta" \
    "failed spawn's meta does not record its endpoint"
  assert_grep "failed: spawn failed before launch completed" "$HOME_DIR/state/$id.status" \
    "failed spawn left no supervisor-visible failed: status line"
  run_settle_teardown "$id" >/dev/null \
    || fail "forced teardown could not reap a failed-spawn stub with no worktree"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "forced teardown left the failed-spawn meta behind"
  [ ! -e "$HOME_DIR/state/$id.status" ] \
    || fail "forced teardown left the failed-spawn status behind"
  pass "a failed spawn leaves ordinary terminal state that forced teardown can reap (upstream issue 1336)"
}

test_failed_bootstrap_leaves_meta_and_failed_status

test_backend_partial_create_failure_leaves_terminal_state() {
  local rec id out rc
  id=settle-partial-create-z4
  rec=$(make_settle_case settle-partial-create "$id" 0)
  read_settle_record "$rec"

  rc=0
  out=$(FM_FAKE_NEW_WINDOW_FAIL_AFTER_CREATE=1 run_settle_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a backend create helper failure should fail the spawn"
  [ -e "$HOME_DIR/state/$id.meta" ] \
    || fail "partial backend create failure left no meta record behind"
  assert_grep "window=firstmate:fm-$id" "$HOME_DIR/state/$id.meta" \
    "partial backend create failure lost its owned endpoint"
  assert_grep "failed: spawn failed before launch completed" "$HOME_DIR/state/$id.status" \
    "partial backend create failure left no terminal status"
  pass "a backend helper failure after partial creation leaves terminal state"
}

test_backend_partial_create_failure_leaves_terminal_state

test_preendpoint_failure_leaves_status_without_meta() {
  local rec id out rc
  id=settle-preendpoint-z5
  rec=$(make_settle_case settle-preendpoint "$id" 0)
  read_settle_record "$rec"
  rm -f "$HOME_DIR/data/$id/brief.md"

  rc=0
  out=$(run_settle_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn with no brief should fail"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "pre-endpoint failure wrote unreapable endpoint metadata"
  assert_grep 'failed: spawn failed before launch completed' "$HOME_DIR/state/$id.status" \
    "pre-endpoint failure left no visible failed status"
  pass "a pre-endpoint failure leaves status without unreapable metadata"
}

test_preendpoint_failure_leaves_status_without_meta

test_duplicate_spawn_does_not_terminalize_live_task() {
  local rec id out rc meta_before meta_after
  id=settle-duplicate-z6
  rec=$(make_settle_case settle-duplicate "$id" 0)
  read_settle_record "$rec"
  run_settle_spawn "$id" >/dev/null || fail "duplicate-spawn setup failed"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")

  rc=0
  out=$(FM_FAKE_EXISTING_WINDOW="fm-$id" run_settle_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "duplicate spawn should be refused"
  assert_contains "$out" "already exists" "duplicate spawn lost its refusal diagnostic"
  meta_after=$(cat "$HOME_DIR/state/$id.meta")
  [ "$meta_after" = "$meta_before" ] || fail "duplicate spawn mutated the live task metadata"
  ! grep -q '^failed:' "$HOME_DIR/state/$id.status" 2>/dev/null \
    || fail "duplicate spawn falsely marked the live task terminal"
  pass "a duplicate spawn cannot terminalize an existing live task"
}

test_duplicate_spawn_does_not_terminalize_live_task

echo "# all fm-spawn-worktree-settle tests passed"
