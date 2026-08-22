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
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
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
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then
  holder=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --lease-holder ]; then
      holder=$2
      shift
    fi
    shift
  done
  countfile="${FM_FAKE_TREEHOUSE_GET_COUNTFILE:?}"
  n=0
  [ -f "$countfile" ] && n=$(cat "$countfile")
  n=$((n + 1))
  printf '%s\n' "$n" > "$countfile"
  printf 'get holder=%s n=%s\n' "$holder" "$n" >> "${FM_FAKE_TREEHOUSE_GET_LOG:?}"
  if [ "$n" -gt 1 ]; then
    # Real durable leases are never handed out by a later generic get.
    if [ -n "${FM_FAKE_TREEHOUSE_SECOND_GET_PATH:-}" ]; then
      jq -cn --arg path "$FM_FAKE_TREEHOUSE_SECOND_GET_PATH" --arg holder "$holder" \
        '{name:"slot-other",path:$path,lease_id:"lease-other",lease_holder:$holder}'
      exit 0
    fi
    echo "error: leased worktree is never handed out by a later get" >&2
    exit 1
  fi
  jq -cn --arg path "${FM_FAKE_TREEHOUSE_PATH:?}" --arg holder "$holder" \
    --arg lease "${FM_FAKE_TREEHOUSE_LEASE:-lease-settle}" \
    '{name:"slot-settle",path:$path,lease_id:$lease,lease_holder:$holder}'
  exit 0
fi
if [ "${1:-}" = status ]; then
  jq -cn --arg path "${FM_FAKE_TREEHOUSE_PATH:?}" \
    --arg holder "${FM_FAKE_TREEHOUSE_HOLDER:?}" \
    --arg lease "${FM_FAKE_TREEHOUSE_LEASE:-lease-settle}" \
    '[{name:"slot-settle",path:$path,status:"leased",lease_id:$lease,lease_holder:$holder}]'
fi
if [ "${1:-}" = return ]; then
  printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_RETURN_LOG:?}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
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
  : > "$case_dir/treehouse-return.log"
  : > "$case_dir/treehouse-get.log"
  : > "$case_dir/treehouse-get-count"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1 mode=${2:-no-mistakes} pane_path=${3:-$WT_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane_path" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_TREEHOUSE_PATH="$WT_DIR" \
    FM_FAKE_TREEHOUSE_HOLDER="$id" \
    FM_FAKE_TREEHOUSE_RETURN_LOG="$(dirname "$HOME_DIR")/treehouse-return.log" \
    FM_FAKE_TREEHOUSE_GET_LOG="$(dirname "$HOME_DIR")/treehouse-get.log" \
    FM_FAKE_TREEHOUSE_GET_COUNTFILE="$(dirname "$HOME_DIR")/treehouse-get-count" \
    FM_FAKE_TREEHOUSE_SECOND_GET_PATH="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode "$mode" --yolo off 2>&1
}

run_settle_teardown() {
  local id=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_PATH="$WT_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    FM_FAKE_TREEHOUSE_HOLDER="$id" \
    FM_FAKE_TREEHOUSE_RETURN_LOG="$(dirname "$HOME_DIR")/treehouse-return.log" \
    "$TEARDOWN" "$id" --force 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status expected_base
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
  expected_base=$(git -C "$WT_DIR" rev-parse HEAD)
  assert_grep "base_commit=$expected_base" "$HOME_DIR/state/$id.meta" \
    "meta did not bind the task to its exact pre-launch base commit"
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
  [ "$elapsed" -le 15 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep plus ordinary spawn overhead"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_same_worktree_relaunch_preserves_original_task_base() {
  local rec id out status original_base current_head recorded_base
  id=settle-relaunch-base-z3
  rec=$(make_settle_case settle-relaunch-base "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "initial spawn should record a task base"
  original_base=$(sed -n 's/^base_commit=//p' "$HOME_DIR/state/$id.meta")
  [ -n "$original_base" ] || fail "initial spawn recorded no task base"

  printf 'task work\n' > "$WT_DIR/task.txt"
  git -C "$WT_DIR" add task.txt
  git -C "$WT_DIR" -c user.name=test -c user.email=test@example.com commit -q -m "task work"
  current_head=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$current_head" != "$original_base" ] || fail "relaunch fixture did not advance the task worktree"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "same-worktree relaunch should succeed"
  recorded_base=$(sed -n 's/^base_commit=//p' "$HOME_DIR/state/$id.meta")
  [ "$recorded_base" = "$original_base" ] ||
    fail "same-worktree relaunch replaced the original task base with current HEAD"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "writer relaunch replaced the recorded worktree"
  assert_grep "treehouse_lease=lease-settle" "$HOME_DIR/state/$id.meta" \
    "writer relaunch replaced the recorded lease"
  gets=$(grep -c '^get ' "$(dirname "$HOME_DIR")/treehouse-get.log" || true)
  [ "$gets" = 1 ] || fail "writer relaunch called generic treehouse get $gets times"
  pass "a same-worktree relaunch preserves the original pre-launch task base"
}

test_writer_occupancy_identity_round_trip() {
  local rec id out status
  id=settle-occupancy-roundtrip-z4
  rec=$(make_settle_case settle-occupancy-roundtrip "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" local-only)
  status=$?
  expect_code 0 "$status" "ordinary writer spawn should record occupancy identity"
  assert_grep "treehouse_lease=lease-settle" "$HOME_DIR/state/$id.meta" \
    "ordinary writer metadata omitted the per-acquisition lease identity"

  out=$(run_settle_teardown "$id")
  status=$?
  expect_code 0 "$status" "matching spawned occupancy teardown failed: $out"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "matching occupancy identity did not permit task record retirement"
  pass "ordinary writer occupancy identity survives spawn-to-teardown round trip"
}

test_failed_settle_returns_allocated_lease() {
  local rec id out status
  id=settle-abort-return-z5
  rec=$(make_settle_case settle-abort-return "$id" 0)
  read_settle_record "$rec"
  cat > "$FAKEBIN_DIR/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN_DIR/sleep"

  status=0
  out=$(run_settle_spawn "$id" local-only "$STALE_DIR") || status=$?
  [ "$status" -ne 0 ] || fail "spawn unexpectedly accepted a pane outside its acquired lease"
  assert_grep "$WT_DIR" "$(dirname "$HOME_DIR")/treehouse-return.log" \
    "failed pane settle did not return the allocated lease path"
  assert_grep "--if-lease-id lease-settle --if-lease-holder $id" \
    "$(dirname "$HOME_DIR")/treehouse-return.log" \
    "failed pane settle returned without its acquired lease identity"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "failed pane settle transferred lease custody into metadata"
  pass "failed pane settle returns its allocated Treehouse lease"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_same_worktree_relaunch_preserves_original_task_base
test_writer_occupancy_identity_round_trip
test_failed_settle_returns_allocated_lease

echo "# all fm-spawn-worktree-settle tests passed"
