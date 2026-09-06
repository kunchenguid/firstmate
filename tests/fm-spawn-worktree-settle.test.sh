#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 "$ENTER_WAIT")` loop after
# `treehouse get`).
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
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
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
  local rec id out status pane_reads expected_reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  pane_reads=$(cat "$COUNTFILE")
  expected_reads=2
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$pane_reads" -eq "$expected_reads" ] || fail "already-settled pane used $pane_reads pane reads; expected $expected_reads (initial read plus one confirmation)"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# FM_SPAWN_ENTER_WAIT_SECS overrides the enter-wait bound: with the pane never
# leaving the project (candidate never settles), the loop exhausts and the
# failure names the configured bound, proving the override drives the loop.
test_enter_wait_override_changes_the_bound() {
  local rec id out status start end elapsed
  id=enter-wait-override-z3
  rec=$(make_settle_case enter-wait-override "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  # Point the fake pane at the project itself so it never enters a worktree.
  out=$(FM_SPAWN_ENTER_WAIT_SECS=1 WT_DIR="$PROJ_DIR" STALE_DIR="$PROJ_DIR" run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 1 "$status" "spawn should fail when the pane never enters a worktree"
  assert_contains "$out" "within 1s" "failure did not report the overridden enter-wait bound"
  [ "$elapsed" -le 5 ] || fail "enter-wait=1 loop took ${elapsed}s - the override did not bound the loop"
  pass "FM_SPAWN_ENTER_WAIT_SECS bounds the treehouse-enter wait loop"
}

# A non-positive-integer override (including all-digit zero like 00) is refused
# before the endpoint window exists or treehouse get is sent.
test_enter_wait_invalid_is_refused() {
  local rec id out status bad tmux_log
  for bad in nope 00; do
    id="enter-wait-invalid-$bad-z4"
    rec=$(make_settle_case "enter-wait-invalid-$bad" "$id" 0)
    read_settle_record "$rec"
    tmux_log="$HOME_DIR/tmux-calls.log"
    : > "$tmux_log"

    out=$(FM_SPAWN_ENTER_WAIT_SECS="$bad" FM_FAKE_TMUX_LOG="$tmux_log" run_settle_spawn "$id")
    status=$?
    expect_code 1 "$status" "spawn should refuse enter-wait '$bad'"
    assert_contains "$out" "FM_SPAWN_ENTER_WAIT_SECS must be a positive integer, got '$bad'" \
      "spawn did not refuse enter-wait '$bad'"
    assert_no_grep "new-window" "$tmux_log" "enter-wait '$bad' was refused only after creating the endpoint window"
    assert_no_grep "treehouse get" "$tmux_log" "enter-wait '$bad' was refused only after sending treehouse get"
  done
  pass "a non-positive-integer FM_SPAWN_ENTER_WAIT_SECS is refused before any endpoint exists"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_enter_wait_override_changes_the_bound
test_enter_wait_invalid_is_refused

echo "# all fm-spawn-worktree-settle tests passed"
