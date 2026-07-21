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
    [ -e "${FM_FAKE_ENDPOINT_ALIVE:?}" ] || exit 1
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
  *"#{pane_current_command}"*)
    [ -e "${FM_FAKE_ENDPOINT_ALIVE:?}" ] || exit 1
    if [ -e "${FM_FAKE_LAUNCH_SEEN:-/nonexistent}" ]; then
      printf '%s\n' "${FM_FAKE_FOREGROUND_COMMAND:-codex}"
    else
      printf '%s\n' "${FM_FAKE_OLD_FOREGROUND_COMMAND:-${FM_FAKE_FOREGROUND_COMMAND:-codex}}"
    fi
    exit 0
    ;;
  *"#{pane_pid}"*)
    [ -e "${FM_FAKE_ENDPOINT_ALIVE:?}" ] || exit 1
    printf '4242\n'
    exit 0
    ;;
  *"#{pane_id}"*)
    [ -e "${FM_FAKE_ENDPOINT_ALIVE:?}" ]
    exit
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_INSPECTION_UNKNOWN:-0}" = 1 ] && [ ! -e "${FM_FAKE_ENDPOINT_ALIVE:?}" ]; then
      exit 1
    fi
    exit 0
    ;;
  list-sessions)
    if [ "${FM_FAKE_INSPECTION_UNKNOWN:-0}" = 1 ]; then
      printf 'transport failure\n' >&2
      exit 1
    fi
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  new-window) : > "${FM_FAKE_ENDPOINT_ALIVE:?}"; exit 0 ;;
  kill-window)
    [ "${FM_FAKE_KILL_STICKS:-0}" = 1 ] || rm -f -- "${FM_FAKE_ENDPOINT_ALIVE:?}"
    exit 0
    ;;
  send-keys)
    if [ "${FM_FAKE_SEND_FAIL:-}" = export ] && case "$*" in *"export GOTMPDIR="*) true ;; *) false ;; esac; then
      exit 1
    fi
    if [ "${FM_FAKE_SEND_FAIL:-}" = literal ] && case "$*" in *"${FM_FAKE_LAUNCH_PROOF:-/nonexistent}"*) true ;; *) false ;; esac; then
      exit 1
    fi
    if [ "${FM_FAKE_SEND_FAIL:-}" = enter ] && [ -e "${FM_FAKE_LAUNCH_PENDING:-/nonexistent}" ] && case "$*" in *Enter*) true ;; *) false ;; esac; then
      exit 1
    fi
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
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_PI_PROCESS:-0}" = 1 ] || exit 1
[ "${1:-}" = -P ] && [ "${2:-}" = 4242 ] || exit 1
printf '4243\n'
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_PI_PROCESS:-0}" = 1 ] || exit 1
printf 'node /opt/pi/bin/pi --model test\n'
SH
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_META_TMP_DIR:-}" ]; then
  printf '%s\n' "$FM_FAKE_META_TMP_DIR"
else
  /usr/bin/mktemp "$@"
fi
SH
cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
last=
for arg in "$@"; do
  last=$arg
done
if [ "${FM_FAKE_LN_FAIL:-0}" = 1 ] && [ "$last" = "${FM_FAKE_META_PATH:-}" ]; then
  exit 1
fi
/bin/ln "$@"
SH
  chmod +x "$fakebin/pgrep" "$fakebin/ps" "$fakebin/mktemp" "$fakebin/ln"
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
  local id=$1 mode=${2:-settled} force_wrong=${3:-0} send_fail=${4:-} kill_sticks=${5:-0}
  local tmux_log launch_pending launch_seen launch_anchored endpoint_alive
  tmux_log="$HOME_DIR/$id.tmux.log"
  launch_pending="$HOME_DIR/$id.launch-pending"
  launch_seen="$HOME_DIR/$id.launch-seen"
  launch_anchored="$HOME_DIR/$id.launch-anchored"
  endpoint_alive="$HOME_DIR/$id.endpoint-alive"
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
    FM_FAKE_LAUNCH_ANCHORED="$launch_anchored" FM_FAKE_ENDPOINT_ALIVE="$endpoint_alive" \
    FM_FAKE_META_PATH="$HOME_DIR/state/$id.meta" \
    FM_FAKE_SEND_FAIL="$send_fail" FM_FAKE_KILL_STICKS="$kill_sticks" \
    FM_SPAWN_LAUNCH_CWD_POLLS=4 FM_SPAWN_LAUNCH_CWD_INTERVAL=0 \
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
  assert_contains "$out" "launch verification failed" \
    "post-launch wrong-cwd refusal was not loud"
  assert_contains "$out" "metadata was not published" \
    "post-launch wrong-cwd refusal did not state the metadata boundary"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "post-launch wrong-cwd failure published task metadata"
  assert_contains "$(cat "$log")" $'kill-window\037-t\037firstmate:fm-'"$id" \
    "post-launch wrong-cwd failure did not stop the exact task endpoint"
  pass "a post-launch primary-checkout cwd stops the endpoint and publishes no metadata"
}

test_post_allocation_send_failures_stop_endpoint_without_metadata() {
  local send_stage rec id out status
  for send_stage in export literal enter; do
    id="settle-send-fail-$send_stage"
    rec=$(make_settle_case "send-fail-$send_stage" "$id" 0)
    read_settle_record "$rec"
    out=$(run_settle_spawn "$id" settled 0 "$send_stage")
    status=$?
    [ "$status" -ne 0 ] || fail "spawn must fail when the $send_stage send fails"
    assert_contains "$out" "launch verification failed" "$send_stage send failure was not routed through launch cleanup"
    assert_contains "$out" "The exact endpoint was stopped" "$send_stage send failure did not verify endpoint closure"
    assert_absent "$HOME_DIR/state/$id.meta" "$send_stage send failure published metadata"
    assert_absent "$HOME_DIR/$id.endpoint-alive" "$send_stage send failure left the endpoint alive"
  done
  pass "every post-allocation send failure stops the exact endpoint without metadata"
}

test_cleanup_failure_reports_live_endpoint_explicitly() {
  local rec id out status
  id=settle-cleanup-sticks-z5
  rec=$(make_settle_case cleanup-sticks "$id" 0)
  read_settle_record "$rec"
  out=$(run_settle_spawn "$id" settled 0 literal 1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when launch send and endpoint cleanup fail"
  assert_contains "$out" "closure could not be verified after three cleanup attempts" \
    "cleanup failure did not report the still-live exact endpoint"
  assert_present "$HOME_DIR/$id.endpoint-alive" "cleanup failure fixture did not retain the endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" "cleanup failure published metadata"
  pass "an unclosed endpoint is reported explicitly after bounded cleanup retries"
}

test_cleanup_inspection_failure_is_unknown_not_absent() {
  local rec id out status
  id=settle-cleanup-unknown-z8
  rec=$(make_settle_case cleanup-unknown "$id" 0)
  read_settle_record "$rec"
  out=$(FM_FAKE_INSPECTION_UNKNOWN=1 run_settle_spawn "$id" settled 0 literal)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when launch send and closure inspection fail"
  assert_contains "$out" "state 'unknown'" "inspection failure was incorrectly treated as confirmed absence"
  assert_absent "$HOME_DIR/state/$id.meta" "inspection failure published metadata"
  pass "an unreadable endpoint never counts as confirmed closed"
}

test_bare_shell_cwd_never_publishes_metadata() {
  local rec id out status
  id=settle-bare-shell-z6
  rec=$(make_settle_case bare-shell "$id" 0)
  read_settle_record "$rec"
  out=$(FM_FAKE_FOREGROUND_COMMAND=zsh run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must reject a bare shell at the expected cwd"
  assert_contains "$out" "agent=dead" "bare-shell failure did not include the tmux liveness verdict"
  assert_absent "$HOME_DIR/state/$id.meta" "bare-shell cwd check published metadata"
  assert_absent "$HOME_DIR/$id.endpoint-alive" "bare-shell cwd check left the endpoint alive"
  pass "tmux cwd verification requires a live verified harness process"
}

test_pi_liveness_is_positive_and_pi_exit_is_rejected() {
  local rec id out status
  id=settle-pi-live-z9
  rec=$(make_settle_case pi-live "$id" 0)
  read_settle_record "$rec"
  printf 'pi\n' > "$HOME_DIR/config/crew-harness"
  out=$(FM_FAKE_FOREGROUND_COMMAND=node FM_FAKE_PI_PROCESS=1 run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should accept a positively identified live Pi process"
  assert_present "$HOME_DIR/state/$id.meta" "live Pi process did not publish metadata"

  id=settle-pi-exit-z10
  rec=$(make_settle_case pi-exit "$id" 0)
  read_settle_record "$rec"
  printf 'pi\n' > "$HOME_DIR/config/crew-harness"
  out=$(FM_FAKE_FOREGROUND_COMMAND=zsh run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must reject Pi after it exits to a bare shell"
  assert_contains "$out" "agent=dead" "Pi exit did not surface the dead process verdict"
  assert_absent "$HOME_DIR/state/$id.meta" "exited Pi process published metadata"
  pass "tmux positively identifies live Pi and rejects exited Pi"
}

test_recovery_metadata_is_preserved_then_atomically_replaced() {
  local rec id out status old_meta
  id=settle-recovery-z11
  rec=$(make_settle_case recovery "$id" 0)
  read_settle_record "$rec"
  old_meta="window=firstmate:fm-$id
worktree=$WT_REAL
project=$PROJ_REAL
harness=codex
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$id
model=old-model
effort=low"
  printf '%s\n' "$old_meta" > "$HOME_DIR/state/$id.meta"
  out=$(run_settle_spawn "$id" settled 0 literal)
  status=$?
  [ "$status" -ne 0 ] || fail "recovery launch-send fixture must fail"
  [ "$(cat "$HOME_DIR/state/$id.meta")" = "$old_meta" ] \
    || fail "failed recovery changed the prior metadata"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "recovery should replace metadata after new-agent verification"
  assert_grep 'model=default' "$HOME_DIR/state/$id.meta" "recovery did not publish replacement metadata"
  assert_no_grep 'model=old-model' "$HOME_DIR/state/$id.meta" "recovery retained stale metadata"
  pass "recovery preserves old metadata until verified atomic replacement"
}

test_metadata_render_write_failure_never_publishes() {
  local rec id out status bad_tmp
  id=settle-render-fail-z12
  rec=$(make_settle_case render-fail "$id" 0)
  read_settle_record "$rec"
  bad_tmp="$HOME_DIR/state/render-target-directory"
  mkdir -p "$bad_tmp"
  out=$(FM_FAKE_META_TMP_DIR="$bad_tmp" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when the metadata write fails"
  assert_contains "$out" "metadata could not be published atomically" \
    "metadata write failure did not use launch cleanup"
  assert_absent "$HOME_DIR/state/$id.meta" "metadata write failure published metadata"
  assert_absent "$HOME_DIR/$id.endpoint-alive" "metadata write failure left the endpoint alive"
  pass "a failed metadata write cannot publish partial routing state"
}

test_metadata_publication_is_atomic_and_preserves_worktree() {
  local rec id out status
  id=settle-meta-fail-z7
  rec=$(make_settle_case meta-fail "$id" 0)
  read_settle_record "$rec"
  out=$(FM_FAKE_LN_FAIL=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when metadata cannot be published"
  assert_contains "$out" "metadata could not be published atomically" \
    "metadata failure did not use the preserving launch cleanup path"
  assert_absent "$HOME_DIR/$id.endpoint-alive" "metadata failure left the endpoint alive"
  assert_present "$WT_REAL/.git" "metadata failure did not preserve the allocated worktree"
  find "$HOME_DIR/state" -maxdepth 1 -name ".$id.meta.*" -print -quit | grep . >/dev/null \
    && fail "metadata failure left a temporary publication file"
  pass "metadata publication is atomic and failure preserves the worktree"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_transient_foreground_cwd_cannot_mask_primary_launch
test_post_launch_wrong_cwd_stops_endpoint_without_metadata
test_post_allocation_send_failures_stop_endpoint_without_metadata
test_cleanup_failure_reports_live_endpoint_explicitly
test_cleanup_inspection_failure_is_unknown_not_absent
test_bare_shell_cwd_never_publishes_metadata
test_pi_liveness_is_positive_and_pi_exit_is_rejected
test_recovery_metadata_is_preserved_then_atomically_replaced
test_metadata_render_write_failure_never_publishes
test_metadata_publication_is_atomic_and_preserves_worktree

echo "# all fm-spawn-worktree-settle tests passed"
