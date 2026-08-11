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
# It also covers the ownership boundary after allocation: a candidate already
# recorded by another ordinary task must be refused before spawn mutates that
# copy or publishes a second owner.
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
    if [ -n "${FM_FAKE_PANE_READ_DELAY:-}" ]; then
      sleep "$FM_FAKE_PANE_READ_DELAY"
    fi
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
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_PANE_READ_DELAY="${FM_FAKE_PANE_READ_DELAY:-}" \
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

# A recorded task remains the owner of its isolated copy regardless of whether
# its endpoint is quiet, paused, blocked, or otherwise inactive. The allocator
# may still return that copy, but spawn must refuse it before refreshing the
# branch or publishing another task record.
test_recorded_task_copy_is_not_reallocated() {
  local rec owner_id new_id out status before after
  owner_id=settle-owner-z3
  new_id=settle-contender-z4
  rec=$(make_settle_case settle-recorded-owner "$new_id" 0)
  read_settle_record "$rec"
  fm_write_meta "$HOME_DIR/state/$owner_id.meta" \
    "window=firstmate:fm-$owner_id" \
    "endpoint_task_id=$owner_id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship"
  printf 'paused: waiting on an external answer\n' > "$HOME_DIR/state/$owner_id.status"
  printf 'owner-only commit\n' > "$WT_DIR/owner-only.txt"
  git -C "$WT_DIR" add owner-only.txt
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'owner branch must not move'
  before=$(git -C "$WT_DIR" rev-parse HEAD)

  set +e
  out=$(run_settle_spawn "$new_id")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "spawn reused a copy already recorded by $owner_id"
  assert_contains "$out" "$owner_id" "refusal did not identify the owning task"
  assert_contains "$out" "$WT_DIR" "refusal did not identify the conflicting worktree"
  assert_absent "$HOME_DIR/state/$new_id.meta" "refused spawn published a second owner"
  after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "refused spawn changed the recorded owner's branch head"
  pass "a paused recorded task keeps exclusive ownership of its isolated copy"
}

# A present ordinary-task record with ambiguous ownership fields cannot prove a
# copy is free. Spawn must stop without changing the candidate's clean branch.
test_ambiguous_ownership_record_stops_allocation() {
  local rec owner_id new_id out status before after
  owner_id=settle-ambiguous-z5
  new_id=settle-ambiguous-contender-z6
  rec=$(make_settle_case settle-ambiguous-owner "$new_id" 0)
  read_settle_record "$rec"
  fm_write_meta "$HOME_DIR/state/$owner_id.meta" \
    "window=firstmate:fm-$owner_id" \
    "worktree=$WT_DIR" \
    "worktree=$STALE_DIR" \
    "kind=ship"
  before=$(git -C "$WT_DIR" rev-parse HEAD)

  set +e
  out=$(run_settle_spawn "$new_id")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "spawn accepted ambiguous worktree ownership"
  assert_contains "$out" "$owner_id" "ambiguous-record refusal did not identify the task"
  assert_contains "$out" "ambiguous worktree" "ambiguous-record refusal did not explain the unsafe field"
  assert_absent "$HOME_DIR/state/$new_id.meta" "ambiguous ownership published a contender record"
  after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "ambiguous ownership changed the candidate branch head"
  pass "ambiguous ordinary-task ownership stops allocation safely"
}

# The per-home task-set lock spans candidate selection through metadata
# publication. Two different task ids racing for one allocator result may have
# either a lock refusal or a later owner refusal, but exactly one may publish.
test_concurrent_spawns_cannot_claim_one_copy_twice() {
  local rec first_id second_id first_pid second_pid first_status second_status owners
  first_id=settle-race-a-z7
  second_id=settle-race-b-z8
  rec=$(make_settle_case settle-concurrent "$first_id" 0)
  read_settle_record "$rec"
  mkdir -p "$HOME_DIR/data/$second_id"
  printf 'brief for %s\n' "$second_id" > "$HOME_DIR/data/$second_id/brief.md"

  FM_FAKE_PANE_READ_DELAY=0.3 run_settle_spawn "$first_id" \
    > "$HOME_DIR/first.out" 2>&1 &
  first_pid=$!
  sleep 0.1
  FM_FAKE_PANE_READ_DELAY=0.3 run_settle_spawn "$second_id" \
    > "$HOME_DIR/second.out" 2>&1 &
  second_pid=$!
  set +e
  wait "$first_pid"
  first_status=$?
  wait "$second_pid"
  second_status=$?
  set -e

  [ $(( (first_status == 0) + (second_status == 0) )) -eq 1 ] \
    || fail "concurrent spawns produced $first_status/$second_status instead of exactly one owner"
  owners=0
  [ ! -f "$HOME_DIR/state/$first_id.meta" ] || owners=$((owners + 1))
  [ ! -f "$HOME_DIR/state/$second_id.meta" ] || owners=$((owners + 1))
  [ "$owners" -eq 1 ] || fail "concurrent spawns published $owners ownership records"
  pass "concurrent spawns cannot both publish ownership of one isolated copy"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_recorded_task_copy_is_not_reallocated
test_ambiguous_ownership_record_stops_allocation
test_concurrent_spawns_cannot_claim_one_copy_twice

echo "# all fm-spawn-worktree-settle tests passed"
