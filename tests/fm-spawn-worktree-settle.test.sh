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
# query can model either a stale first read or the Herdr-shaped failure where
# a transient foreground command reports the worktree twice before the shell
# returns to the primary checkout. It also executes the launch-cwd proof only
# after the launch Enter and derives the simulated launched cwd from the exact
# safely quoted `cd` anchor in the submitted launch line.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || {
  printf '%s' "${1:-}" >> "$FM_FAKE_TMUX_LOG"
  for fm_fake_arg in "${@:2}"; do
    printf '\037%s' "$fm_fake_arg" >> "$FM_FAKE_TMUX_LOG"
  done
  printf '\n' >> "$FM_FAKE_TMUX_LOG"
}
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ -e "${FM_FAKE_LAUNCH_SEEN:-/nonexistent}" ]; then
      if [ "${FM_FAKE_FORCE_WRONG_AFTER_LAUNCH:-0}" = 1 ]; then
        printf '%s\n' "${FM_FAKE_PANE_PRIMARY:-}"
      elif [ -e "${FM_FAKE_LAUNCH_ANCHORED:-/nonexistent}" ]; then
        printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
      else
        printf '%s\n' "${FM_FAKE_PANE_PRIMARY:-}"
      fi
    elif [ "${FM_FAKE_TRANSIENT_MASK:-0}" = 1 ]; then
      if [ "$n" -le "${FM_FAKE_TRANSIENT_READS:-2}" ]; then
        printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
      else
        printf '%s\n' "${FM_FAKE_PANE_PRIMARY:-}"
      fi
    elif [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
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
    if [ -n "${FM_FAKE_LAUNCH_PROOF:-}" ] && case "$*" in *"$FM_FAKE_LAUNCH_PROOF"*) true ;; *) false ;; esac; then
      : > "${FM_FAKE_LAUNCH_PENDING:?}"
      anchor="cd -- '${FM_FAKE_PANE_PATH}'"
      case "$*" in
        *"$anchor"*) : > "${FM_FAKE_LAUNCH_ANCHORED:?}" ;;
      esac
    elif [ -e "${FM_FAKE_LAUNCH_PENDING:-/nonexistent}" ] && case "$*" in *Enter*) true ;; *) false ;; esac; then
      : > "${FM_FAKE_LAUNCH_PROOF:?}"
      : > "${FM_FAKE_LAUNCH_SEEN:?}"
    fi
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
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
  PROJ_REAL=$(cd "$PROJ_DIR" && pwd -P)
  WT_REAL=$(cd "$WT_DIR" && pwd -P)
  STATE_REAL=$(cd "$HOME_DIR/state" && pwd -P)
}

run_settle_spawn() {
  local id=$1 mode=${2:-settled} force_wrong=${3:-0} tmux_log launch_pending launch_seen launch_anchored
  tmux_log="$HOME_DIR/$id.tmux.log"
  launch_pending="$HOME_DIR/$id.launch-pending"
  launch_seen="$HOME_DIR/$id.launch-seen"
  launch_anchored="$HOME_DIR/$id.launch-anchored"
  : > "$tmux_log"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_REAL" FM_FAKE_PANE_PRIMARY="$PROJ_REAL" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_TRANSIENT_MASK="$([ "$mode" = transient ] && printf 1 || printf 0)" \
    FM_FAKE_TRANSIENT_READS=2 FM_FAKE_FORCE_WRONG_AFTER_LAUNCH="$force_wrong" \
    FM_FAKE_TMUX_LOG="$tmux_log" FM_FAKE_LAUNCH_PROOF="$STATE_REAL/$id.launch-cwd" \
    FM_FAKE_LAUNCH_PENDING="$launch_pending" FM_FAKE_LAUNCH_SEEN="$launch_seen" \
    FM_FAKE_LAUNCH_ANCHORED="$launch_anchored" FM_SPAWN_LAUNCH_CWD_POLLS=4 FM_SPAWN_LAUNCH_CWD_INTERVAL=0 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
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
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
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
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_transient_foreground_cwd_cannot_mask_primary_launch() {
  local rec id out status log
  id=settle-transient-mask-z3
  rec=$(make_settle_case settle-transient-mask "$id" 0)
  read_settle_record "$rec"
  log="$HOME_DIR/$id.tmux.log"

  out=$(run_settle_spawn "$id" transient)
  status=$?
  expect_code 0 "$status" "anchored spawn should survive the transient foreground-cwd mask"
  assert_contains "$out" "spawned $id" "anchored transient-mask spawn did not report success"
  assert_grep "worktree=$WT_REAL" "$HOME_DIR/state/$id.meta" \
    "transient-mask spawn did not publish the validated physical worktree"
  assert_contains "$(cat "$log")" "cd -- '$WT_REAL'" \
    "the actual launch line was not anchored to the validated physical worktree"
  assert_present "$HOME_DIR/$id.launch-anchored" \
    "the fake terminal did not recognize the exact safely quoted launch anchor"
  pass "a transient foreground worktree cwd cannot mask a later primary-checkout launch"
}

test_post_launch_wrong_cwd_stops_endpoint_without_metadata() {
  local rec id out status log
  id=settle-post-launch-wrong-z4
  rec=$(make_settle_case settle-post-launch-wrong "$id" 0)
  read_settle_record "$rec"
  log="$HOME_DIR/$id.tmux.log"

  out=$(run_settle_spawn "$id" transient 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when the launched foreground cwd resolves to the primary checkout"
  assert_contains "$out" "launch cwd verification failed" \
    "post-launch wrong-cwd refusal was not loud"
  assert_contains "$out" "metadata was not published" \
    "post-launch wrong-cwd refusal did not state the metadata boundary"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "post-launch wrong-cwd failure published task metadata"
  assert_contains "$(cat "$log")" $'kill-window\037-t\037firstmate:fm-'"$id" \
    "post-launch wrong-cwd failure did not stop the exact task endpoint"
  pass "a post-launch primary-checkout cwd stops the endpoint and publishes no metadata"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_transient_foreground_cwd_cannot_mask_primary_launch
test_post_launch_wrong_cwd_stops_endpoint_without_metadata

echo "# all fm-spawn-worktree-settle tests passed"
