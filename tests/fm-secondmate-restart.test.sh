#!/usr/bin/env bash
# tests/fm-secondmate-restart.test.sh - bin/fm-secondmate-restart.sh: relaunch
# one already-live LOCAL second mate with changed launch flags without losing
# its persistent home (AGENTS.md task lifecycle; .agents/skills/
# secondmate-provisioning "Recovery"; the script's own header owns mechanics).
#
# Everything here drives the real fm-secondmate-restart.sh -> real fm-spawn.sh
# chain against a fake backend, so the guarantees are observed through the
# executable interface rather than read out of the source.
#
# The guarantees under test:
#   - a live second mate is retired and relaunched, and the NEW launch flags
#     reach both the launch command and state/<id>.meta.
#   - the persistent home survives verbatim: charter, backlog, project clones,
#     secondmate marker, registry route, and the home's own state/ (including a
#     crewmate endpoint record belonging to that second mate) are untouched.
#   - remote_control is retained across an unflagged restart, turned on by
#     --remote-control, and turned off by --no-remote-control. The separate
#     automatic replay by bin/fm-bootstrap.sh's liveness sweep, which this path
#     must leave alone, stays owned by tests/fm-secondmate-liveness.test.sh
#     (test_sweep_reapplies_remote_control_on_dead_respawn).
#   - an endpoint that does not positively read alive/dead/missing (ambiguous,
#     unreadable, unverified) refuses with NOTHING mutated - no close, no
#     relaunch, meta byte-identical. Zellij is the backend that reaches the
#     unverified branch while still accepting --secondmate spawns.
#   - an unconfirmed close (the endpoint is still there afterwards) refuses and
#     never relaunches, so a refused close can never produce a duplicate agent.
#   - a failed relaunch restores the previous meta record, so the endpoint stays
#     recoverable by the session-start liveness sweep.
#   - a remote route, a non-secondmate task, and an absent record are all
#     refused before any mutation, with the locked registry route authoritative
#     over stale local metadata.
#   - a concurrent spawn/restart of the same id is serialized by the shared
#     state/.spawn-<id>.lock through relaunch and rollback.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-restart)
RESTART="$ROOT/bin/fm-secondmate-restart.sh"

# A fake tmux driven by two files in the case dir, so one fixture can express
# every endpoint state the restart preflight must distinguish:
#   inventory   - what `list-windows` reports (the window name = present,
#                 "absent" = the window is gone, "unreadable" = a probe failure)
#   command     - what `#{pane_current_command}` reports (a harness name = a
#                 live agent, `bash` = an agent-free shell)
# `kill-window` rewrites inventory to "absent" unless FM_FAKE_KILL_REFUSED is
# set, which is how the unconfirmed-close case keeps the endpoint present.
# Every launch payload is appended to FM_FAKE_LAUNCH_LOG.
make_state_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
inv=$(cat "$FM_FAKE_INVENTORY" 2>/dev/null || printf 'absent')
case "${1:-}" in
  list-windows)
    case "$inv" in
      unreadable) printf "%s\n" "permission denied" >&2; exit 1 ;;
      absent) printf '%s\n' other-window; exit 0 ;;
      *) printf '%s\n' "$inv"; exit 0 ;;
    esac
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          cat "$FM_FAKE_COMMAND" 2>/dev/null || printf 'bash\n'
          exit 0
          ;;
        *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
        *pane_tty*) exit 1 ;;
      esac
    done
    printf 'firstmate\n'
    exit 0
    ;;
  kill-window)
    printf 'kill-window %s\n' "$*" >> "${FM_FAKE_LAUNCH_LOG:-/dev/null}"
    [ -n "${FM_FAKE_KILL_REFUSED:-}" ] || printf 'absent' > "$FM_FAKE_INVENTORY"
    exit 0
    ;;
  new-window)
    printf '%s' "${FM_FAKE_NEW_WINDOW_NAME:-}" > /dev/null
    if [ -n "${FM_FAKE_NEW_WINDOW_READY:-}" ]; then
      : > "$FM_FAKE_NEW_WINDOW_READY"
      while [ ! -e "$FM_FAKE_NEW_WINDOW_RELEASE" ]; do sleep 0.01; done
    fi
    [ -z "${FM_FAKE_NEW_WINDOW_FAIL:-}" ] || { printf 'create refused\n' >&2; exit 1; }
    printf '@9\n'
    printf "${FM_FAKE_SPAWN_WINDOW:-fm-unknown}" > "$FM_FAKE_INVENTORY"
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l|Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" kimi
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> [harness]: a primary home plus a seeded secondmate home that
# already holds durable work (charter, backlog, a project clone, and a crewmate
# endpoint record of its own), plus a live kind=secondmate record for it.
# Sets the CASE_* globals used by run_restart.
make_case() {
  local name=$1 harness=${2:-claude} case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_ID=$name
  CASE_DIR=$case_dir
  CASE_HOME="$case_dir/home"
  CASE_SUB="$case_dir/sub"
  CASE_LOG="$case_dir/launch.log"
  CASE_INVENTORY="$case_dir/inventory"
  CASE_COMMAND="$case_dir/command"
  CASE_FAKEBIN=$(make_state_tmux "$case_dir/fake")
  CASE_META="$CASE_HOME/state/$CASE_ID.meta"

  mkdir -p "$CASE_HOME/data" "$CASE_HOME/state" "$CASE_HOME/config" "$CASE_HOME/projects"
  printf '%s\n' "$$" > "$CASE_HOME/state/.lock"
  touch "$CASE_HOME/state/.last-watcher-beat"
  printf '%s\n' "$harness" > "$CASE_HOME/config/secondmate-harness"

  # The persistent second mate home, with material that must survive verbatim.
  mkdir -p "$CASE_SUB/data" "$CASE_SUB/state" "$CASE_SUB/config" "$CASE_SUB/projects/alpha"
  mark_firstmate_home "$CASE_SUB"
  printf '%s\n' "$CASE_ID" > "$CASE_SUB/.fm-secondmate-home"
  printf 'persistent charter for %s\n' "$CASE_ID" > "$CASE_SUB/data/charter.md"
  printf -- '- [ ] sub-item-a1 queued work\n' > "$CASE_SUB/data/backlog.md"
  printf 'clone marker\n' > "$CASE_SUB/projects/alpha/marker.txt"
  # A crewmate this second mate owns: its endpoint record lives in the SUB
  # home's state/ and must not be touched by restarting the parent agent.
  fm_write_meta "$CASE_SUB/state/child-k9.meta" \
    "window=firstmate:fm-child-k9" "endpoint_task_id=child-k9" \
    "worktree=$CASE_SUB/projects/alpha" "project=$CASE_SUB/projects/alpha" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"

  printf -- '- %s - test charter (home: %s; scope: testing; projects: alpha; added 2026-08-08)\n' \
    "$CASE_ID" "$(cd "$CASE_SUB" && pwd -P)" > "$CASE_HOME/data/secondmates.md"

  fm_write_secondmate_meta "$CASE_META" "$(cd "$CASE_SUB" && pwd -P)" \
    "firstmate:fm-$CASE_ID" alpha "$harness"
  printf 'fm-%s' "$CASE_ID" > "$CASE_INVENTORY"
  printf '%s\n' "$harness" > "$CASE_COMMAND"
}

# run_restart [flags...]: drive the real restart against the case fixture.
run_restart() {
  : > "$CASE_LOG"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_FAKE_PANE_PATH="$(cd "$CASE_SUB" && pwd -P)" \
    FM_FAKE_INVENTORY="$CASE_INVENTORY" FM_FAKE_COMMAND="$CASE_COMMAND" \
    FM_FAKE_LAUNCH_LOG="$CASE_LOG" FM_FAKE_SPAWN_WINDOW="fm-$CASE_ID" \
    TMUX="fake,1,0" PATH="$CASE_FAKEBIN:$BASE_PATH" \
    "$RESTART" "$CASE_ID" "$@" 2>&1
}

run_competing_spawn() {
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_FAKE_PANE_PATH="$(cd "$CASE_SUB" && pwd -P)" \
    FM_FAKE_INVENTORY="$CASE_INVENTORY" FM_FAKE_COMMAND="$CASE_COMMAND" \
    FM_FAKE_LAUNCH_LOG="$CASE_LOG" FM_FAKE_SPAWN_WINDOW="fm-$CASE_ID" \
    TMUX="fake,1,0" PATH="$CASE_FAKEBIN:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$CASE_ID" --secondmate "$@" 2>&1
}

# The claude launch arrives as one literal payload; find it by the fixed
# CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION prefix every claude launch carries
# (bin/fm-spawn.sh launch_template()), same as tests/fm-spawn-remote-control.test.sh.
launch_line() {
  grep 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION' "$CASE_LOG" | tail -1
}

assert_home_intact() {
  local why=$1
  assert_grep "persistent charter for $CASE_ID" "$CASE_SUB/data/charter.md" "$why: charter was lost"
  assert_grep 'sub-item-a1' "$CASE_SUB/data/backlog.md" "$why: the second mate's backlog was lost"
  assert_grep 'clone marker' "$CASE_SUB/projects/alpha/marker.txt" "$why: a project clone was lost"
  assert_present "$CASE_SUB/.fm-secondmate-home" "$why: the second mate home marker was removed"
  assert_present "$CASE_SUB/state/child-k9.meta" "$why: the second mate's own crewmate record was removed"
  assert_grep "window=firstmate:fm-child-k9" "$CASE_SUB/state/child-k9.meta" \
    "$why: the second mate's own crewmate endpoint record was rewritten"
  assert_grep "- $CASE_ID - test charter" "$CASE_HOME/data/secondmates.md" "$why: the registry route was changed"
}

test_restart_applies_new_flags_and_keeps_the_home() {
  local out status
  make_case restart-flags claude

  out=$(run_restart --model opus --effort high)
  status=$?
  expect_code 0 "$status" "restarting a live second mate should succeed"$'\n'"$out"
  assert_contains "$out" "restarted restart-flags" "restart should report the relaunch"

  assert_grep 'kill-window' "$CASE_LOG" "the live endpoint was never retired"
  assert_contains "$(launch_line)" "--model 'opus'" "the new model flag did not reach the launch command"
  assert_contains "$(launch_line)" "--effort 'high'" "the new effort flag did not reach the launch command"
  assert_grep 'model=opus' "$CASE_META" "meta did not record the new model"
  assert_grep 'effort=high' "$CASE_META" "meta did not record the new effort"
  assert_grep 'kind=secondmate' "$CASE_META" "the relaunched record is no longer a second mate"
  assert_absent "$CASE_HOME/state/.secondmate-restart-$CASE_ID.meta.bak" \
    "a successful restart left its rollback snapshot behind"
  assert_home_intact "successful restart"
  pass "restart: retires the live endpoint, relaunches with the new flags, and keeps the whole home"
}

test_remote_control_is_retained_unless_flagged_off() {
  local out

  make_case restart-rc-keep claude
  printf 'remote_control=1\n' >> "$CASE_META"
  out=$(run_restart --model opus)
  expect_code 0 "$?" "an unflagged restart of a Remote-Control second mate should succeed"$'\n'"$out"
  assert_contains "$(launch_line)" '--remote-control' "an unflagged restart dropped Remote Control"
  assert_grep 'remote_control=1' "$CASE_META" "an unflagged restart did not retain remote_control=1"

  make_case restart-rc-off claude
  printf 'remote_control=1\n' >> "$CASE_META"
  out=$(run_restart --no-remote-control)
  expect_code 0 "$?" "restart with --no-remote-control should succeed"$'\n'"$out"
  assert_not_contains "$(launch_line)" '--remote-control' "--no-remote-control still passed the flag"
  assert_no_grep 'remote_control=' "$CASE_META" "--no-remote-control left remote_control= in meta"

  make_case restart-rc-on claude
  out=$(run_restart --remote-control)
  expect_code 0 "$?" "restart with --remote-control should succeed"$'\n'"$out"
  assert_contains "$(launch_line)" '--remote-control' "--remote-control did not reach the launch command"
  assert_grep 'remote_control=1' "$CASE_META" "--remote-control did not record remote_control=1"

  pass "restart: keeps Remote Control by default, turns it on with --remote-control, off with --no-remote-control"
}

test_ambiguous_endpoint_refuses_without_mutating() {
  local out status before
  for state in unreadable ambiguous; do
    make_case "restart-$state" claude
    before=$(cat "$CASE_META")
    case "$state" in
      unreadable) printf 'unreadable' > "$CASE_INVENTORY" ;;
      ambiguous) printf 'node\n' > "$CASE_COMMAND" ;;
    esac

    out=$(run_restart --model opus)
    status=$?
    expect_code 1 "$status" "a $state endpoint must refuse the restart"$'\n'"$out"
    assert_contains "$out" "refusing to risk a duplicate agent" "the $state refusal should name the risk"
    assert_no_grep 'kill-window' "$CASE_LOG" "a $state endpoint was closed anyway"
    assert_not_contains "$(cat "$CASE_LOG")" 'charter.md' "a $state endpoint was relaunched anyway"
    [ "$(cat "$CASE_META")" = "$before" ] || fail "a $state refusal changed state/<id>.meta"
    assert_home_intact "$state refusal"
  done
  pass "restart: an ambiguous or unreadable endpoint refuses with nothing closed, relaunched, or rewritten"
}

test_zellij_secondmate_refuses_for_lack_of_a_recovery_classifier() {
  # Zellij accepts --secondmate spawns but has no verified recovery classifier,
  # so fm_backend_agent_state reports `unverified` for it - the same reason the
  # session-start liveness sweep skips it. A restart must refuse rather than
  # close and relaunch on a state it cannot read. Orca and cmux reach the same
  # branch, and additionally cannot hold a secondmate endpoint at all.
  local out status before
  make_case restart-zellij claude
  before=$(cat "$CASE_META")
  fm_write_meta "$CASE_META" \
    "window=zsess:1" "endpoint_task_id=$CASE_ID" \
    "worktree=$CASE_SUB" "project=$CASE_SUB" "harness=claude" "kind=secondmate" \
    "mode=secondmate" "yolo=off" "home=$CASE_SUB" "projects=alpha" \
    "backend=zellij" "zellij_session=zsess" "zellij_tab_id=1" "zellij_pane_id=1"
  before=$(cat "$CASE_META")

  out=$(run_restart --model opus)
  status=$?
  expect_code 1 "$status" "a zellij second mate must refuse the restart"$'\n'"$out"
  assert_contains "$out" "reads as unverified" "the refusal should name the unverified classifier"
  assert_not_contains "$(cat "$CASE_LOG")" 'charter.md' "a zellij second mate was relaunched anyway"
  [ "$(cat "$CASE_META")" = "$before" ] || fail "a zellij refusal changed state/<id>.meta"
  assert_home_intact "zellij refusal"
  pass "restart: a backend with no verified recovery classifier refuses instead of replacing an unreadable endpoint"
}

test_unconfirmed_close_refuses_before_relaunching() {
  local out status before
  make_case restart-close-refused claude
  before=$(cat "$CASE_META")
  export FM_FAKE_KILL_REFUSED=1
  out=$(run_restart --model opus)
  status=$?
  unset FM_FAKE_KILL_REFUSED
  expect_code 1 "$status" "an unconfirmed close must refuse the restart"$'\n'"$out"
  assert_contains "$out" "not confirmed gone" "the refusal should name the unconfirmed close"
  assert_not_contains "$(cat "$CASE_LOG")" 'charter.md' "an unconfirmed close still relaunched a second agent"
  [ "$(cat "$CASE_META")" = "$before" ] || fail "an unconfirmed close changed state/<id>.meta"
  assert_home_intact "unconfirmed close"
  pass "restart: an unconfirmed close refuses before relaunching, so it can never duplicate an agent"
}

test_failed_relaunch_restores_the_previous_record() {
  local out status before
  make_case restart-launch-fail claude
  before=$(cat "$CASE_META")
  export FM_FAKE_NEW_WINDOW_FAIL=1
  out=$(run_restart --model opus)
  status=$?
  unset FM_FAKE_NEW_WINDOW_FAIL
  expect_code 1 "$status" "a failed relaunch must report failure"$'\n'"$out"
  assert_contains "$out" "was retired but its relaunch failed" "the failure should say the endpoint was retired"
  assert_contains "$out" "fm-secondmate-restart.sh $CASE_ID --model opus" \
    "the retry hint must carry the operator's own flags, since the restored record no longer implies them"
  [ "$(cat "$CASE_META")" = "$before" ] \
    || fail "a failed relaunch did not restore the previous record"$'\n'"$(cat "$CASE_META")"
  assert_grep 'kind=secondmate' "$CASE_META" "the restored record must stay recoverable by the liveness sweep"
  assert_grep "window=firstmate:fm-$CASE_ID" "$CASE_META" "the restored record must keep its window= for recovery"
  assert_absent "$CASE_HOME/state/.secondmate-restart-$CASE_ID.meta.bak" \
    "the rollback snapshot should be consumed by the restore"
  assert_home_intact "failed relaunch"
  pass "restart: a failed relaunch restores the previous record so the liveness sweep can recover it"
}

test_post_create_failure_confirms_replacement_gone_before_rollback() {
  local out status before kills
  make_case restart-kimi-fail kimi
  before=$(cat "$CASE_META")
  export FM_KIMI_READY_POLLS=1 FM_KIMI_POLL_INTERVAL=0
  out=$(run_restart --model kimi-test)
  status=$?
  unset FM_KIMI_READY_POLLS FM_KIMI_POLL_INTERVAL
  expect_code 1 "$status" "a post-create Kimi readiness failure must report failure"$'\n'"$out"
  assert_contains "$out" "kimi did not show a verified ready signal" "the fixture did not reach the post-create failure"
  kills=$(grep -cF 'kill-window' "$CASE_LOG")
  [ "$kills" -eq 2 ] || fail "post-create failure did not retire both the old and failed replacement endpoints"
  [ "$(cat "$CASE_INVENTORY")" = absent ] || fail "the failed replacement endpoint was not confirmed gone"
  [ "$(cat "$CASE_META")" = "$before" ] || fail "rollback did not restore the old record after confirming replacement removal"
  assert_absent "$CASE_HOME/state/.secondmate-restart-$CASE_ID.meta.bak" \
    "confirmed replacement cleanup left the rollback snapshot behind"
  pass "restart: post-create failure removes the exact replacement before restoring old metadata"
}

test_missing_endpoint_relaunches_without_a_close() {
  local out status
  make_case restart-missing claude
  printf 'absent' > "$CASE_INVENTORY"

  out=$(run_restart --model opus)
  status=$?
  expect_code 0 "$status" "an already-gone endpoint should still relaunch"$'\n'"$out"
  assert_no_grep 'kill-window' "$CASE_LOG" "an already-gone endpoint should not be closed"
  assert_contains "$(launch_line)" "--model 'opus'" "the relaunch did not carry the new flag"
  assert_home_intact "missing-endpoint restart"
  pass "restart: an already-gone endpoint relaunches with the new flags and closes nothing"
}

test_remote_and_non_secondmate_records_are_refused() {
  local out status before

  make_case restart-remote claude
  printf 'remote_host=example-host\n' >> "$CASE_META"
  before=$(cat "$CASE_META")
  out=$(run_restart --remote-control)
  status=$?
  expect_code 1 "$status" "a remote route must be refused"$'\n'"$out"
  assert_contains "$out" "remote route" "the remote refusal should name the route"
  [ "$(cat "$CASE_META")" = "$before" ] || fail "a remote refusal changed state/<id>.meta"
  assert_no_grep 'kill-window' "$CASE_LOG" "a remote refusal closed a local endpoint"

  make_case restart-registry-remote claude
  printf -- '- %s - remote charter (host: remote-mac; root: /srv/firstmate; home: /srv/secondmate; scope: testing; projects: alpha; added 2026-08-08)\n' \
    "$CASE_ID" > "$CASE_HOME/data/secondmates.md"
  before=$(cat "$CASE_META")
  out=$(run_restart --model opus)
  status=$?
  expect_code 1 "$status" "an authoritative remote route must override stale local metadata"$'\n'"$out"
  assert_contains "$out" "remote route" "the authoritative registry refusal should name the remote route"
  [ "$(cat "$CASE_META")" = "$before" ] || fail "an authoritative remote-route refusal changed stale local metadata"
  assert_no_grep 'kill-window' "$CASE_LOG" "an authoritative remote route closed the stale local endpoint"

  make_case restart-ship claude
  fm_write_meta "$CASE_META" \
    "window=firstmate:fm-$CASE_ID" "endpoint_task_id=$CASE_ID" \
    "worktree=$CASE_SUB" "project=$CASE_SUB" "harness=claude" "kind=ship" \
    "mode=no-mistakes" "yolo=off"
  out=$(run_restart)
  status=$?
  expect_code 1 "$status" "a ship task must be refused"$'\n'"$out"
  assert_contains "$out" "is not a second mate" "the refusal should say the task is not a second mate"

  make_case restart-absent claude
  rm -f "$CASE_META"
  out=$(run_restart)
  status=$?
  expect_code 1 "$status" "an absent record must be refused"$'\n'"$out"
  assert_contains "$out" "nothing to restart" "the refusal should say there is nothing to restart"

  pass "restart: remote routes, non-second-mate tasks, and absent records refuse before any mutation"
}

test_restart_lock_spans_the_relaunch() {
  local out status ready release restart_pid contender
  make_case restart-handoff claude
  ready="$CASE_DIR/new-window-ready"
  release="$CASE_DIR/new-window-release"
  export FM_FAKE_NEW_WINDOW_READY="$ready"
  export FM_FAKE_NEW_WINDOW_RELEASE="$release"
  run_restart --model opus > "$CASE_DIR/restart.out" &
  restart_pid=$!
  while [ ! -e "$ready" ] && kill -0 "$restart_pid" 2>/dev/null; do sleep 0.01; done
  [ -e "$ready" ] || fail "restart did not reach the blocked relaunch boundary"

  contender=$(run_competing_spawn --model sonnet)
  status=$?
  expect_code 1 "$status" "a replacement must not enter while relaunch is publishing metadata"$'\n'"$contender"
  assert_contains "$contender" "another spawn is already creating task" "the relaunch handoff lost task ownership"

  : > "$release"
  wait "$restart_pid"
  status=$?
  out=$(cat "$CASE_DIR/restart.out")
  unset FM_FAKE_NEW_WINDOW_READY FM_FAKE_NEW_WINDOW_RELEASE
  expect_code 0 "$status" "the serialized restart should finish after release"$'\n'"$out"
  assert_grep 'model=opus' "$CASE_META" "the contending replacement overwrote relaunched metadata"
  assert_no_grep 'model=sonnet' "$CASE_META" "the contending replacement published metadata"
  pass "restart: task ownership spans endpoint retirement through relaunch metadata publication"
}

test_concurrent_restart_is_serialized() {
  local out status ready release owner_pid lock
  make_case restart-locked claude
  ready="$CASE_DIR/lock-ready"
  release="$CASE_DIR/lock-release"
  lock="$CASE_HOME/state/.spawn-$CASE_ID.lock"
  # A LIVE holder of the shared per-task spawn lock, exactly as a concurrent
  # spawn or restart would be: the lock owner must stay alive, since a dead
  # owner's lock is legitimately reclaimed as stale.
  ROOT="$ROOT" READY="$ready" RELEASE="$release" LOCK="$lock" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.05; done
    fm_lock_release "$LOCK"
  ' &
  owner_pid=$!
  while [ ! -e "$ready" ] && kill -0 "$owner_pid" 2>/dev/null; do sleep 0.01; done
  [ -e "$ready" ] || fail "could not hold the shared task lock for the contention case"

  out=$(run_restart --model opus)
  status=$?
  : > "$release"
  wait "$owner_pid" || fail "the task lock owner failed"
  expect_code 1 "$status" "a contended task lock must refuse the restart"$'\n'"$out"
  assert_contains "$out" "already changing second mate" "the refusal should name the concurrent change"
  assert_no_grep 'kill-window' "$CASE_LOG" "a lock-refused restart closed the endpoint anyway"
  assert_home_intact "lock-refused restart"
  pass "restart: a concurrent spawn or restart of the same id is serialized by the shared task lock"
}

test_restart_applies_new_flags_and_keeps_the_home
test_remote_control_is_retained_unless_flagged_off
test_ambiguous_endpoint_refuses_without_mutating
test_zellij_secondmate_refuses_for_lack_of_a_recovery_classifier
test_unconfirmed_close_refuses_before_relaunching
test_failed_relaunch_restores_the_previous_record
test_post_create_failure_confirms_replacement_gone_before_rollback
test_missing_endpoint_relaunches_without_a_close
test_remote_and_non_secondmate_records_are_refused
test_concurrent_restart_is_serialized
test_restart_lock_spans_the_relaunch
