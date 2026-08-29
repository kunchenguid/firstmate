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
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then briefly reports FM_FAKE_PANE_PATH before returning to the primary
# shell cwd unless the spawn explicitly pins that shell in the acquired worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
. "${FM_FAKE_SPAWN_ACK_LIB:?FM_FAKE_SPAWN_ACK_LIB unset}"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ -f "${FM_FAKE_PANE_PINNED_FILE:-}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    elif [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    elif [ "$n" -le "$((FM_FAKE_PANE_STALE_READS + 2))" ]; then
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    else
      printf '%s\n' "${FM_FAKE_PRIMARY_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane)
    if [ -f "${FM_STATE_OVERRIDE:-}/.fake-spawn-pin-pending" ]; then
      ack=$(fm_fake_spawn_ack_capture)
      printf '%s\n' "$ack"
      printf '%s\n' "$ack" > "${FM_FAKE_PIN_OUTPUT_FILE:?FM_FAKE_PIN_OUTPUT_FILE unset}"
      touch "${FM_FAKE_PANE_PINNED_FILE:?FM_FAKE_PANE_PINNED_FILE unset}"
    fi
    exit 0
    ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    case "$*" in
      *"cd -- "*)
        printf '%s\n' "$*" > "${FM_FAKE_PIN_COMMAND_FILE:?FM_FAKE_PIN_COMMAND_FILE unset}"
        fm_fake_spawn_ack_send "$@"
        ;;
      *" -l "*) [ -f "${FM_FAKE_PANE_PINNED_FILE:-}" ] && launch_cwd=${FM_FAKE_PANE_PATH:-} || launch_cwd=${FM_FAKE_PRIMARY_PATH:-}; printf '%s\n' "$launch_cwd" > "${FM_FAKE_LAUNCH_CWD_FILE:?FM_FAKE_LAUNCH_CWD_FILE unset}" ;;
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
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile pinned pincommand pinoutput launchcwd
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$home/projects/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  pinned="$case_dir/pane-pinned"
  pincommand="$case_dir/pin-command"
  pinoutput="$case_dir/pin-output"
  launchcwd="$case_dir/launch-cwd"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads|$pinned|$pincommand|$pinoutput|$launchcwd"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS PINNED_FILE PIN_COMMAND_FILE PIN_OUTPUT_FILE LAUNCH_CWD_FILE <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1 project=${2:-$PROJ_DIR} kind_flag=${3:-}
  local -a delivery_args=(--mode no-mistakes --yolo off)
  [ "$kind_flag" != --scout ] || delivery_args=(--scout)
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
      FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
      FM_FAKE_PRIMARY_PATH="$PROJ_DIR" FM_FAKE_PANE_PINNED_FILE="$PINNED_FILE" \
      FM_FAKE_PIN_COMMAND_FILE="$PIN_COMMAND_FILE" FM_FAKE_PIN_OUTPUT_FILE="$PIN_OUTPUT_FILE" \
      FM_FAKE_LAUNCH_CWD_FILE="$LAUNCH_CWD_FILE" \
      FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
      PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$project" "${delivery_args[@]}" 2>&1
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

# The caller-facing relative form resolves `projects/<repo>` through the active
# home's projects directory. Its metadata must still carry the pane cwd that
# treehouse selected, not the primary project path used to create the pane.
test_relative_project_records_launched_pane_cwd() {
  local rec id out status meta_project meta_worktree
  id=settle-relative-project-z3
  rec=$(make_settle_case settle-relative-project "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" projects/project)
  status=$?
  expect_code 0 "$status" "relative-project spawn should succeed"$'\n'"$out"
  meta_worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  meta_project=$(sed -n 's/^project=//p' "$HOME_DIR/state/$id.meta")
  [ "$meta_worktree" = "$WT_DIR" ] \
    || fail "relative-project meta worktree '$meta_worktree' does not equal launched pane cwd '$WT_DIR'"
  [ "$(cd "$meta_project" && pwd -P)" = "$(cd "$PROJ_DIR" && pwd -P)" ] \
    || fail "relative-project meta project '$meta_project' does not equal primary project '$PROJ_DIR'"
  [ "$meta_worktree" != "$meta_project" ] \
    || fail "relative-project meta collapsed worktree and project to '$meta_worktree'"
  [ "$(cat "$LAUNCH_CWD_FILE")" = "$meta_worktree" ] \
    || fail "relative-project launched pane cwd does not equal meta worktree '$meta_worktree'"
  [ -s "$PIN_OUTPUT_FILE" ] || fail "relative-project spawn did not observe the executed pin acknowledgement"
  if grep -Fq "$(cat "$PIN_OUTPUT_FILE")" "$PIN_COMMAND_FILE"; then
    fail "complete pin acknowledgement appeared in echoed command input"
  fi
  assert_contains "$out" "worktree=$WT_DIR" \
    "relative-project success output did not report the launched pane cwd"
  pass "a relative projects/<repo> spawn records the launched pane cwd as worktree"
}

test_relative_project_scout_records_launched_pane_cwd() {
  local rec id out status meta_project meta_worktree
  id=settle-relative-scout-z4
  rec=$(make_settle_case settle-relative-scout "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" projects/project --scout)
  status=$?
  expect_code 0 "$status" "relative-project scout spawn should succeed"$'\n'"$out"
  meta_worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$id.meta")
  meta_project=$(sed -n 's/^project=//p' "$HOME_DIR/state/$id.meta")
  [ "$meta_worktree" = "$WT_DIR" ] \
    || fail "relative-project scout meta worktree '$meta_worktree' does not equal launched pane cwd '$WT_DIR'"
  [ "$(cd "$meta_project" && pwd -P)" = "$(cd "$PROJ_DIR" && pwd -P)" ] \
    || fail "relative-project scout meta project '$meta_project' does not equal primary project '$PROJ_DIR'"
  [ "$meta_worktree" != "$meta_project" ] \
    || fail "relative-project scout meta collapsed worktree and project to '$meta_worktree'"
  [ "$(cat "$LAUNCH_CWD_FILE")" = "$meta_worktree" ] \
    || fail "relative-project scout launched pane cwd does not equal meta worktree '$meta_worktree'"
  assert_contains "$out" "kind=scout" \
    "relative-project scout success output did not identify the scout kind"
  assert_contains "$out" "worktree=$WT_DIR" \
    "relative-project scout success output did not report the launched pane cwd"
  pass "a relative projects/<repo> scout spawn records the launched pane cwd as worktree"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_relative_project_records_launched_pane_cwd
test_relative_project_scout_records_launched_pane_cwd

echo "# all fm-spawn-worktree-settle tests passed"
