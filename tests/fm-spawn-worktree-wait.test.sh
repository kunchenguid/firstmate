#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's post-treehouse-get worktree-wait loop:
# rejecting the project and FM_ROOT pane reads in either order, and the
# FM_SPAWN_WORKTREE_TIMEOUT override. Uses a fake tmux that serves a
# scripted sequence of pane_current_path answers so the loop's poll-by-poll
# behavior is deterministic without a real terminal or treehouse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-wait)

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    seqfile="${FM_FAKE_PANE_SEQ:-}"
    if [ -n "$seqfile" ] && [ -s "$seqfile" ]; then
      line=$(head -n1 "$seqfile")
      tail -n +2 "$seqfile" > "$seqfile.next"
      mv "$seqfile.next" "$seqfile"
      printf '%s\n' "$line"
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

make_case() {
  local name=$1 case_dir home proj wt
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$name"
  printf 'brief for %s\n' "$name" > "$home/data/$name/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt"
}

run_spawn() {
  local home=$1 fakebin=$2 seqfile=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_SEQ="$seqfile" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A transient FM_ROOT pane read (the pane's parent, before the shell finishes
# cd'ing into the project) must not be accepted as the worktree: FM_ROOT and
# the project are both rejected unconditionally, so the loop keeps polling
# until a real departure. This is the case fm-spawn's own FM_ROOT is itself a
# valid, distinct git worktree that validate_spawn_worktree cannot reject on
# its own - so without this rejection the transient read is silently accepted
# as correct.
test_transient_fm_root_read_is_skipped() {
  local id=transient-root-w1 rec case_dir home proj wt seqfile out status
  rec=$(make_case "$id")
  IFS='|' read -r case_dir home proj wt <<EOF
$rec
EOF
  seqfile="$case_dir/pane.seq"
  printf '%s\n' "$ROOT" "$proj" "$wt" > "$seqfile"
  out=$(run_spawn "$home" "$(make_fakebin "$case_dir/fake")" "$seqfile" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane is actually seen at the project"
  assert_contains "$out" "worktree=$wt" "spawn did not record the real worktree ($out)"
  pass "a transient FM_ROOT pane read before the project is skipped"
}

# FM_SPAWN_WORKTREE_TIMEOUT overrides both the poll count and the error
# message; a pane that never leaves the project must fail fast at the
# configured bound instead of the 60s default.
test_configurable_timeout_used_in_error() {
  local id=timeout-w1 rec case_dir home proj wt seqfile out status
  rec=$(make_case "$id")
  IFS='|' read -r case_dir home proj wt <<EOF
$rec
EOF
  seqfile="$case_dir/pane.seq"
  printf '%s\n' "$proj" "$proj" "$proj" > "$seqfile"
  out=$(FM_SPAWN_WORKTREE_TIMEOUT=2 run_spawn "$home" "$(make_fakebin "$case_dir/fake")" "$seqfile" "$id" "$proj")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when the pane never leaves the project"
  assert_contains "$out" "did not enter a worktree within 2s" "error did not honor FM_SPAWN_WORKTREE_TIMEOUT ($out)"
  pass "FM_SPAWN_WORKTREE_TIMEOUT overrides the wait bound and error message"
}

# A later FM_ROOT read, after the project has already been seen, must also be
# rejected: FM_ROOT is never a valid worktree and accepting it would launch
# the crewmate into the primary checkout (the tangle this loop guards). The
# rejection is unconditional regardless of poll order, so pairing this with
# the transient-read case above covers both orderings.
test_fm_root_rejected_after_project_seen() {
  local id=fm-root-after-proj-w1 rec case_dir home proj wt seqfile out status
  rec=$(make_case "$id")
  IFS='|' read -r case_dir home proj wt <<EOF
$rec
EOF
  seqfile="$case_dir/pane.seq"
  printf '%s\n' "$proj" "$ROOT" "$wt" > "$seqfile"
  out=$(run_spawn "$home" "$(make_fakebin "$case_dir/fake")" "$seqfile" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "spawn should skip the post-project FM_ROOT read and accept the real worktree"
  assert_contains "$out" "worktree=$wt" "spawn accepted FM_ROOT instead of the real worktree ($out)"
  pass "FM_ROOT read after the project is rejected, not accepted as the worktree"
}

test_transient_fm_root_read_is_skipped
test_configurable_timeout_used_in_error
test_fm_root_rejected_after_project_seen
