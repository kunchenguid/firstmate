#!/usr/bin/env bash
# Synthetic/offline away spend admission through production backend and DoD classifiers.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-spend-cap)
fm_git_identity fmtest fmtest@example.invalid
SPAWN_PID=
SPAWN_RELEASE=
cleanup_launch() {
  [ -z "$SPAWN_RELEASE" ] || touch "$SPAWN_RELEASE"
  if [ -n "$SPAWN_PID" ]; then
    kill "$SPAWN_PID" 2>/dev/null || true
    wait "$SPAWN_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_launch EXIT

test_fresh_launch_reservation() {
  local kind scenario entry dir home id out rc count i endpoint_state staged marker
  local -a args
  for entry in ship:delayed scout:delayed ship:raw scout:raw ship:timeout scout:cancel ship:failed scout:finished ship:cleanup-refused ship:rename-timeout scout:move-cancel ship:socket-cancel scout:rename-raw-cancel; do
    kind=${entry%:*}
    scenario=${entry#*:}
    dir="$TMP_ROOT/launch-$kind-$scenario"
    home="$dir/home"
    id="spend-launch-$kind-$scenario-$$"
    fm_test_spawn_home "$home" codex
    fm_test_spawn_brief "$home" "$id"
    fm_git_worktree "$dir/project" "$dir/wt" "slot-$kind-$scenario"
    mkdir -p "$home/fakebin"
    fm_fake_exit0 "$home/fakebin" treehouse no-mistakes
    cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  has-session|set-window-option) exit 0 ;;
  kill-window)
    [ ! -f "$FM_HOME/refuse-cleanup" ] || exit 1
    [ ! -f "$FM_HOME/invisible" ] && [ -f "$FM_HOME/endpoint" ] || exit 1
    rm -f "$FM_HOME/endpoint"
    ;;
  new-window) touch "$FM_HOME/endpoint"; printf '@1\n' ;;
  list-windows)
    [ ! -f "$FM_HOME/invisible" ] || exit 0
    [ ! -f "$FM_HOME/endpoint" ] || printf 'fm-%s\n' "$FM_RESERVATION_ID"
    ;;
  display-message)
    [ ! -f "$FM_HOME/invisible" ] || exit 1
    case "${*: -1}" in
      '#{pane_current_path}') printf '%s\n' "$FM_RESERVATION_WT" ;;
      '#{pane_current_command}')
        [ ! -f "$FM_HOME/unreadable" ] || exit 1
        if [ -f "$FM_HOME/started" ]; then
          [ ! -f "$FM_HOME/invisible" ] || exit 1
          if [ -f "$FM_HOME/raw" ]; then printf 'custom-agent\n'; else printf 'codex\n'; fi
        else printf 'bash\n'; fi
        ;;
      '#S'|'#{session_name}') printf 'firstmate\n' ;;
      '#{pane_id}') printf '%%1\n' ;;
      *) exit 1 ;;
    esac
    ;;
  send-keys)
    case "$*" in
      *launch.*.sh*)
        staged=${*: -1}
        staged=${staged#". '"}
        staged=${staged%"'"}
        printf '%s\n' "$staged" > "$FM_HOME/staged-path"
        touch "$FM_HOME/paused"
        for _ in $(seq 1 200); do
          [ ! -f "$FM_HOME/release" ] || exit 0
          sleep 0.1
        done
        exit 1
        ;;
      *Enter*) [ ! -f "$FM_HOME/paused" ] || touch "$FM_HOME/delivered" ;;
    esac
    ;;
  capture-pane) printf '> \n' ;;
  rename-session|move-window) touch "$FM_HOME/invisible" ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$home/fakebin/tmux"
    FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
      || fail "launch away entry failed"
    args=()
    if [ "$kind" = ship ]; then args=(--mode no-mistakes --yolo off); else args=(--scout); fi
    if [ "$scenario" = raw ] || [ "$scenario" = rename-raw-cancel ]; then
      touch "$home/raw"
      args=('custom-agent --flag' "${args[@]}")
    fi
    SPAWN_RELEASE="$home/release"
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_BACKEND=tmux FM_SUPERVISION_ACTOR=main \
      FM_SPAWN_NO_GUARD=1 TMUX=fake,1,0 FM_RESERVATION_ID="$id" \
      FM_RESERVATION_WT="$dir/wt" PATH="$home/fakebin:$PATH" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$dir/project" "${args[@]}" > "$home/launch.log" 2>&1 &
    SPAWN_PID=$!
    for i in $(seq 1 200); do
      [ ! -f "$home/paused" ] || break
      kill -0 "$SPAWN_PID" 2>/dev/null || break
      sleep 0.1
    done
    [ -f "$home/paused" ] || fail "launch did not reach delivery: $(cat "$home/launch.log")"
    [ -f "$home/state/$id.meta" ] || fail "paused launch has no published record"
    [ ! -e "$home/state/.task-set.lock" ] || fail "launch still holds task-set lock"
    endpoint_state=$(FM_HOME="$home" FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" \
      PATH="$home/fakebin:$PATH" bash -c '. "$1"; fm_backend_agent_state tmux "$2"' \
      _ "$ROOT/bin/fm-backend.sh" "firstmate:fm-$id")
    [ "$endpoint_state" = dead ] || fail "paused endpoint did not reproduce shell-only death: $endpoint_state"
    count=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
    [ "$count" = 1 ] || fail "published shell-only $kind launch lost its reservation: $count"
    rc=0
    out=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" \
      FM_SUPERVISION_ACTOR=main fm_test_run_spawn "$home" "$dir/wt" "$home/fakebin" \
      "spend-next-$kind-$$" "$dir/project" "${args[@]}") || rc=$?
    [ "$rc" -eq 1 ] || fail "concurrent fresh spawn was not refused: $out"
    assert_contains "$out" "caps concurrent workers" "startup reservation did not enforce admission: $out"
    touch "$SPAWN_RELEASE"
    for i in $(seq 1 200); do
      [ ! -f "$home/delivered" ] || break
      kill -0 "$SPAWN_PID" 2>/dev/null || break
      sleep 0.1
    done
    [ -f "$home/delivered" ] || fail "launch key was not delivered: $(cat "$home/launch.log")"
    kill -0 "$SPAWN_PID" 2>/dev/null || fail "spawn exited before establishing delayed startup"
    count=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
    [ "$count" = 1 ] || fail "successfully delivered $kind launch lost its reservation: $count"
    rc=0
    out=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" \
      FM_SUPERVISION_ACTOR=main fm_test_run_spawn "$home" "$dir/wt" "$home/fakebin" \
      "spend-after-key-$kind-$$" "$dir/project" "${args[@]}") || rc=$?
    [ "$rc" -eq 1 ] || fail "post-delivery concurrent spawn was not refused: $out"
    assert_contains "$out" "caps concurrent workers" "post-delivery reservation did not enforce admission: $out"
    case "$scenario" in
      delayed|raw)
        touch "$home/unreadable"
        count=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
        [ "$count" = 1 ] || fail "uncertain startup lost its reservation"
        rm "$home/unreadable"
        rc=0
        out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SUPERVISION_ACTOR=main \
          FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" PATH="$home/fakebin:$PATH" \
          "$ROOT/bin/fm-afk-return.sh" check 2>&1) || rc=$?
        [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || fail "return count failed: $out"
        assert_contains "$out" '1 task(s) live at return.' "return dropped a delivered launch reservation: $out"
        touch "$home/started"
        ;;
      cancel) kill -TERM "$SPAWN_PID" ;;
      timeout) ;;
      rename-timeout|move-cancel|socket-cancel|rename-raw-cancel)
        case "$scenario" in
          rename*) FM_HOME="$home" "$home/fakebin/tmux" rename-session -t firstmate relocated ;;
          move*) FM_HOME="$home" "$home/fakebin/tmux" move-window -s "firstmate:fm-$id" -t relocated ;;
          socket*) touch "$home/invisible" ;;
        esac
        touch "$home/started"
        endpoint_state=$(FM_HOME="$home" FM_RESERVATION_ID="$id" \
          PATH="$home/fakebin:$PATH" bash -c '. "$1"; fm_backend_agent_state tmux "$2"' \
          _ "$ROOT/bin/fm-backend.sh" "firstmate:fm-$id")
        [ "$endpoint_state" = missing ] || fail "relocated launch did not reproduce missing identity: $endpoint_state"
        FM_HOME="$home" FM_RESERVATION_ID="$id" PATH="$home/fakebin:$PATH" bash -c \
          '. "$1"; fm_backend_kill tmux "$2"' _ "$ROOT/bin/fm-backend.sh" "firstmate:fm-$id" \
          || fail "fixture did not reproduce the idempotent close's absence success"
        [ "$scenario" = rename-timeout ] || kill -TERM "$SPAWN_PID"
        ;;
      failed|finished|cleanup-refused)
        staged=$(cat "$home/staged-path")
        cat > "$home/fakebin/codex" <<'SH'
#!/usr/bin/env bash
exit "${FM_FAKE_AGENT_EXIT_CODE:-0}"
SH
        chmod +x "$home/fakebin/codex"
        if [ "$scenario" = finished ]; then rc=0; else rc=17; fi
        [ "$scenario" != cleanup-refused ] || touch "$home/refuse-cleanup"
        PATH="$home/fakebin:$PATH" FM_FAKE_AGENT_EXIT_CODE="$rc" bash "$staged" > "$home/agent.log" 2>&1
        ;;
    esac
    rc=0
    wait "$SPAWN_PID" || rc=$?
    SPAWN_PID=
    case "$scenario" in
      rename-timeout|move-cancel|socket-cancel|rename-raw-cancel)
        [ "$rc" -ne 0 ] || fail "unconfirmed cancellation reported success"
        [ "$scenario" != rename-timeout ] || assert_grep 'startup was not established within 30s' "$home/launch.log" "relocated startup did not reach timeout cancellation"
        [ -f "$home/endpoint" ] && [ -f "$home/started" ] || fail "relocated worker did not survive"
        staged=$(cat "$home/staged-path")
        [ ! -f "$staged" ] || fail "unconfirmed cancellation left a runnable staged launch"
        [ -f "$home/state/$id.meta" ] || fail "unconfirmed cancellation discarded the surviving worker's record"
        [ ! -e "$home/state/.meta-$id.lock" ] || fail "unconfirmed cancellation retained the lifecycle lock"
        marker=$(bash -c '. "$1"; fm_meta_get "$2" cleanup_recovery' _ \
          "$ROOT/bin/fm-backend.sh" "$home/state/$id.meta")
        [ "$marker" = launch ] || fail "unconfirmed cancellation did not retain its cleanup reservation"
        FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" assert_spending_snapshot "$home"
        pass "$kind $scenario cancellation retains the surviving worker, admission reservation and return cost"
        continue
        ;;
      timeout|cancel|failed|cleanup-refused)
        [ "$rc" -ne 0 ] || fail "unsuccessful startup reported success: $(cat "$home/launch.log")"
        [ "$scenario" != timeout ] || assert_grep 'startup was not established within 30s' "$home/launch.log" "timeout did not report startup failure"
        staged=$(cat "$home/staged-path")
        [ ! -f "$staged" ] || fail "cancelled startup left a runnable staged launch"
        if [ "$scenario" = cleanup-refused ]; then
          [ -f "$home/state/$id.meta" ] || fail "uncertain cleanup discarded the endpoint record"
          count=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
          [ "$count" = 1 ] || fail "uncancelled startup stopped reserving spending capacity"
          out=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" \
            FM_SUPERVISION_ACTOR=main fm_test_run_spawn "$home" "$dir/wt" "$home/fakebin" \
            "$id" --relaunch) || fail "recovery relaunch failed: $out"
          assert_contains "$out" "spawned $id" "recovery relaunch did not report success"
          count=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
          [ "$count" = 0 ] || fail "successful recovery retained the previous cleanup reservation"
        else
          [ ! -e "$home/state/$id.meta" ] || fail "cancelled startup retained its record"
          [ ! -e "$home/endpoint" ] || fail "cancelled startup retained its endpoint"
        fi
        count=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
        [ "$count" = 0 ] || fail "cancelled startup left a permanent reservation: $count"
        pass "$kind $scenario startup frees capacity after confirmed cancellation"
        continue
        ;;
    esac
    [ "$rc" -eq 0 ] || fail "reserved launch failed: $(cat "$home/launch.log")"
    [ ! -e "$home/state/.meta-$id.lock" ] || fail "successful launch left its lifecycle lock"
    count=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
    if [ "$scenario" = finished ]; then
      [ "$count" = 0 ] || fail "a command that finished between probes retained its reservation"
    else
      [ "$count" = 1 ] || fail "started worker stopped counting: $count"
      if [ "$scenario" = raw ]; then
        FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" assert_spending_snapshot "$home"
      fi
      rm "$home/started"
    fi
    count=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
    [ "$count" = 0 ] || fail "stopped worker retained its launch reservation: $count"
    pass "$kind $scenario startup reserves admission after delivery; stopped workers free room"
  done
}

test_admission_exemptions() {
  local dir out rc
  dir="$TMP_ROOT/exemptions"
  install_tools "$dir"
  FM_HOME="$dir" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "exemption away entry failed"
  fm_write_meta "$dir/state/active.meta" "kind=ship" "window=fixture:worker"
  rc=0
  out=$(FM_HOME="$dir" PATH="$dir/fakebin:$PATH" FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-spawn.sh" absent --relaunch 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "expected missing relaunch record: $out"
  assert_contains "$out" "needs an existing task record" "relaunch did not reach its own gate: $out"
  assert_not_contains "$out" "caps concurrent workers" "relaunch acquired a fresh-spawn cap gate"
  rc=0
  out=$(FM_HOME="$dir" PATH="$dir/fakebin:$PATH" FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-spawn.sh" mate "$dir/absent-home" --secondmate 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "secondmate with absent home unexpectedly launched"
  assert_not_contains "$out" "caps concurrent workers" "secondmate acquired a fresh-spawn cap gate"
  FM_HOME="$dir" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "away archive failed"
  FM_AFK_MODE=quiet FM_HOME="$dir" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "quiet entry failed"
  rc=0
  out=$(FM_HOME="$dir" PATH="$dir/fakebin:$PATH" FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-spawn.sh" fresh "$dir/absent-project" --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fresh spawn with absent project unexpectedly launched"
  assert_not_contains "$out" "caps concurrent workers" "quiet mode enforced the away cap"
  pass "relaunches, secondmates and quiet mode keep their admission exemptions"
}

test_reservation_precedes_exclusions() (
  trap - EXIT
  dir="$TMP_ROOT/reservation-count"
  install_tools "$dir"
  FM_STATE_OVERRIDE="$dir/state" . "$ROOT/bin/fm-wake-lib.sh"
  for target in dead:worker missing:worker ''; do
    fm_write_meta "$dir/state/task.meta" "kind=scout" "window=$target"
    printf 'done: report complete\n' > "$dir/state/task.status"
    lock=$(fm_meta_lock_path "$dir/state/task.meta") || fail "invalid lock path"
    fm_lock_acquire_wait "$lock" || fail "could not reserve launch"
    count=$(count_workers "$dir") || fail "reserved count failed"
    [ "$count" = 1 ] || fail "live lock did not reserve endpoint '$target': $count"
    fm_lock_release "$lock"
    count=$(count_workers "$dir") || fail "unreserved count failed"
    if [ "$target" = missing:worker ]; then
      [ "$count" = 1 ] || fail "unproven missing endpoint lost its reservation: $count"
    else
      [ "$count" = 0 ] || fail "released endpoint '$target' still counted: $count"
    fi
  done
  fm_write_meta "$dir/state/task.meta" "kind=secondmate" "window=unreadable:worker"
  fm_lock_acquire_wait "$lock" || fail "could not lock secondmate"
  count=$(count_workers "$dir") || fail "secondmate reservation count failed"
  [ "$count" = 0 ] || fail "locked secondmate acquired an ordinary reservation"
  fm_lock_release "$lock"
  fm_write_meta "$dir/state/task.meta" "kind=ship" "window=dead:worker"
  FM_STATE_OVERRIDE="$dir/state" bash -c \
    '. "$1"; fm_lock_acquire_wait "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" \
    || fail "could not create abandoned lifecycle lock"
  count=$(count_workers "$dir") || fail "abandoned reservation count failed"
  [ "$count" = 0 ] || fail "abandoned reservation blocked a stopped worker: $count"
  pass "live reservations precede endpoint and done exclusions; mates and abandoned locks remain excluded"
)

# Only external tool reads are faked; the spend, crew-state, busy and DoD
# classifiers all execute their production code. No real backend is driven.
install_tools() {  # <case-dir>
  local dir=$1 tool
  mkdir -p "$dir/fakebin" "$dir/state"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    [ ! -f "$FM_HOME/invisible" ] && [ "${FM_FAKE_SOCKET_UNREACHABLE:-0}" != 1 ] || exit 0
    case "$3" in
      *unreadable*) echo 'no current client' >&2; exit 1 ;;
      *missing*) exit 0 ;;
    esac
    printf 'worker\n'
    ;;
  display-message)
    case "${*: -1}" in
      '#{pane_current_command}')
        case "$4" in
          dead:*) printf 'bash\n' ;;
          ambiguous:*) printf 'sleep\n' ;;
          *) printf 'claude\n' ;;
        esac
        ;;
      '#{pane_id}') printf '%%1\n' ;;
      *) exit 1 ;;
    esac
    ;;
  capture-pane) printf 'all quiet\n> \n' ;;
  rename-session|move-window) touch "$FM_HOME/invisible" ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/run.toon" ]; then
  case "${1:-}" in
    axi) cat "$FM_HOME/run.toon" ;;
    runs) cat "$FM_HOME/runs.toon" ;;
    daemon) printf 'daemon running (pid 4242)\n' ;;
    *) exit 1 ;;
  esac
fi
exit 0
SH
  for tool in herdr orca zellij cmux; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/fakebin/$tool"
  done
  chmod +x "$dir/fakebin/"*
}

test_positive_death_and_ambiguous_endpoint() {
  local dir count
  dir="$TMP_ROOT/death-count"
  install_tools "$dir"
  fm_write_meta "$dir/state/stopped.meta" "kind=ship" "window=dead:worker"
  fm_write_meta "$dir/state/ambiguous.meta" "kind=ship" "window=ambiguous:worker"
  count=$(count_workers "$dir") || fail "death count failed"
  [ "$count" = 1 ] || fail "positive-death/ambiguous count=$count, expected 1"
  pass "positive endpoint death frees cap room while an unattributed process still counts"
}

assert_spending_snapshot() {
  local dir=$1 out rc=0 count
  count=$(count_workers "$dir") || fail "spend snapshot failed"
  [ "$count" = 1 ] || fail "spending worker count=$count, expected 1"
  FM_HOME="$dir" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "snapshot away entry failed"
  out=$(PATH="$dir/fakebin:$PATH" NM_HOME="$dir/unused-nm-home" FM_HOME="$dir" \
    FM_SUPERVISION_ACTOR=main "$ROOT/bin/fm-spawn.sh" fresh "$dir/absent-project" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "snapshot admission did not refuse: $out"
  assert_contains "$out" "caps concurrent workers" "snapshot admitted another worker: $out"
  rc=0
  out=$(PATH="$dir/fakebin:$PATH" NM_HOME="$dir/unused-nm-home" FM_HOME="$dir" \
    FM_CREW_STATE_NO_FORGE=1 FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-afk-return.sh" check 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || fail "snapshot return failed: $out"
  assert_contains "$out" '1 task(s) live at return.' "return dropped a spending worker: $out"
}

test_unregistered_herdr_worker() {
  local dir count state
  dir="$TMP_ROOT/raw-herdr"
  install_tools "$dir"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pane get')
    if [ -f "$FM_HOME/gone" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
    else
      printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n'
    fi
    ;;
  'agent get') printf '{"error":{"code":"agent_not_found"}}\n' ;;
  'pane process-info')
    [ ! -f "$FM_HOME/unreadable" ] || exit 1
    name=custom-agent
    [ ! -f "$FM_HOME/stopped" ] || name=bash
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":101,"foreground_processes":[{"pid":102,"name":"%s","argv":["%s","--flag"]}]}}}\n' "$name" "$name"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '101 1 bash\n'
SH
  chmod +x "$dir/fakebin/herdr" "$dir/fakebin/ps"
  fm_write_meta "$dir/state/task.meta" "backend=herdr" "window=fixture:w1:p2" \
    "kind=ship" "harness=custom-agent"
  state=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" bash -c \
    '. "$1"; fm_backend_agent_state herdr fixture:w1:p2' _ "$ROOT/bin/fm-backend.sh")
  [ "$state" = dead ] || fail "unregistered fixture did not reproduce the recovery identity verdict: $state"
  state=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" bash -c \
    '. "$1"; fm_backend_worker_state herdr fixture:w1:p2' _ "$ROOT/bin/fm-backend.sh")
  [ "$state" = ambiguous ] || fail "raw Herdr startup did not establish an unattributed running process: $state"
  assert_spending_snapshot "$dir"
  touch "$dir/unreadable"
  count=$(count_workers "$dir")
  [ "$count" = 1 ] || fail "unreadable raw process was excluded"
  rm "$dir/unreadable"
  touch "$dir/stopped"
  count=$(FM_HERDR_PS_BIN="$dir/fakebin/ps" count_workers "$dir")
  [ "$count" = 0 ] || fail "confirmed shell-only raw worker still counted"
  printf 'cleanup_recovery=launch\n' >> "$dir/state/task.meta"
  count=$(FM_HERDR_PS_BIN="$dir/fakebin/ps" count_workers "$dir")
  [ "$count" = 1 ] || fail "uncancelled raw launch lost its cleanup reservation"
  touch "$dir/gone"
  count=$(count_workers "$dir")
  [ "$count" = 0 ] || fail "positively absent Herdr endpoint retained cleanup reservation"
  pass "unregistered Herdr processes count conservatively until shell-only or positively gone"
}

test_tmux_unproven_absence() {
  local dir action state count
  for action in rename-session move-window foreign-socket; do
    dir="$TMP_ROOT/absence-$action"
    install_tools "$dir"
    fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "kind=ship" "harness=claude"
    count=$(count_workers "$dir")
    [ "$count" = 1 ] || fail "initial worker did not count"
    if [ "$action" = foreign-socket ]; then
      export FM_FAKE_SOCKET_UNREACHABLE=1
    else
      FM_HOME="$dir" "$dir/fakebin/tmux" "$action" -t fixture renamed
    fi
    state=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" bash -c \
      '. "$1"; fm_backend_agent_state tmux fixture:worker' _ "$ROOT/bin/fm-backend.sh")
    [ "$state" = missing ] || fail "$action did not reproduce a missing recorded target: $state"
    assert_spending_snapshot "$dir"
    printf 'cleanup_recovery=launch\n' >> "$dir/state/task.meta"
    count=$(count_workers "$dir")
    [ "$count" = 1 ] || fail "$action erased an unresolved cleanup reservation"
    unset FM_FAKE_SOCKET_UNREACHABLE
    pass "$action does not prove the tmux worker stopped"
  done
}

test_completed_run_busy_turn() {
  local dir head out count
  dir="$TMP_ROOT/completed-run-busy"
  install_tools "$dir"
  git init -q -b fm/worker "$dir/wt"
  git -C "$dir/wt" commit -q --allow-empty -m init
  head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" update-ref refs/remotes/origin/worker "$head"
  fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
    "project=$dir/wt" "kind=ship" "mode=no-mistakes" "harness=claude"
  printf 'done: PR https://example.test/o/r/pull/9 checks green\n' > "$dir/state/task.status"
  cat > "$dir/run.toon" <<EOF
run:
  id: "01RUN"
  branch: fm/worker
  status: completed
  head: "$head"
  pr: "https://example.test/o/r/pull/9"
  findings: none
outcome: passed
EOF
  printf '  completed fm/worker %s 2026-10-04 10:00\n' "${head:0:7}" > "$dir/runs.toon"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
    --source claude-hook --event stop >/dev/null || fail "run idle record failed"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: done" "completed run not accepted: $out"
  assert_contains "$out" "source: run-step" "run did not own terminal classification: $out"
  count=$(count_workers "$dir")
  [ "$count" = 0 ] || fail "settled completed run still counted"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task busy --current-gen \
    --source claude-hook --event user-prompt-submit >/dev/null || fail "run busy record failed"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: done" "run fixture lost the stale terminal verdict: $out"
  assert_contains "$out" "source: run-step" "steered run was no longer attributed: $out"
  assert_spending_snapshot "$dir"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "busy test changed HEAD"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task idle --current-gen \
    --source claude-hook --event stop >/dev/null || fail "run stop record failed"
  count=$(count_workers "$dir")
  [ "$count" = 0 ] || fail "settled steered run did not free capacity"
  pass "current turn busy overrides a completed attributed run without a new HEAD or status"
}

count_workers() {  # <case-dir>
  PATH="$1/fakebin:$PATH" NM_HOME="$1/unused-nm-home" \
    FM_HOME="$1" "$ROOT/bin/fm-afk-spend-count.sh" "$1/state"
}

read_worker() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" NM_HOME="$1/unused-nm-home" \
    FM_HOME="$1" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$2"
}

test_exited_worker_does_not_fill_cap() {
  local home root out rc
  home="$TMP_ROOT/exited"
  root="$home/project"
  install_tools "$home"
  mkdir -p "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "away entry failed"
  fm_write_meta "$home/state/exited.meta" "window=dead:worker" "kind=ship"

  rc=0
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-spawn.sh" fresh \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "expected queued-work gate, got rc=$rc: $out"
  assert_contains "$out" "queued unblocked work" "spawn never reached the next admission gate: $out"
  assert_not_contains "$out" "caps concurrent workers" "an exited worker filled the cap: $out"
  pass "an exited worker frees cap room and spawn reaches its queued-work gate"
}

test_unreadable_and_unverified_backends_still_count() {
  local dir backend target count
  dir="$TMP_ROOT/backend-count"
  install_tools "$dir"
  for backend in tmux herdr orca zellij cmux; do
    case "$backend" in
      tmux) target=unreadable:worker ;;
      herdr) target=fm-lab-synthetic:w1:p2 ;;
      *) target='recorded-target' ;;
    esac
    fm_write_meta "$dir/state/$backend.meta" "kind=ship" "backend=$backend" "window=$target"
  done
  fm_write_meta "$dir/state/exited.meta" "kind=scout" "window=dead:worker"
  fm_write_meta "$dir/state/no-target.meta" "kind=ship"
  fm_write_meta "$dir/state/mate.meta" "kind=secondmate" "window=unreadable:worker"
  count=$(count_workers "$dir") || fail "backend count failed"
  [ "$count" = 5 ] || fail "unreadable/unverified backend count=$count, expected 5 (one per supported backend)"
  pass "five unreadable/unverified backends count; stopped endpoints, absent targets and secondmates do not"
}

test_handoff_and_ready_use_production_crew_state() {
  local dir head out count
  dir="$TMP_ROOT/delivery-count"
  install_tools "$dir"
  git init -q -b fm/worker "$dir/wt"
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" update-ref refs/remotes/origin/main "$(git -C "$dir/wt" rev-parse HEAD)"
  git -C "$dir/wt" commit -q --allow-empty -m 'unpublished implementation'
  head=$(git -C "$dir/wt" rev-parse HEAD)
  fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
    "project=$dir/wt" "kind=ship" "mode=no-mistakes" "harness=claude"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
    --source claude-hook --event stop >/dev/null || fail "idle record failed"

  printf 'done: implementation complete\n' > "$dir/state/task.status"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: done" "fixture did not reach production handoff classification: $out"
  count=$(count_workers "$dir") || fail "handoff count failed"
  [ "$count" = 1 ] || fail "unpublished pre-validation handoff count=$count, expected 1; crew-state: $out"
  pass "production crew-state accepts a handoff but away spend keeps it counted"

  printf 'done: PR https://example.test/o/r/pull/9 checks green\n' > "$dir/state/task.status"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: blocked" "invalid ready head was not blocked: $out"
  assert_contains "$out" "named head $head is unreachable" "named-head gate was not exercised: $out"
  count=$(count_workers "$dir") || fail "invalid-ready count failed"
  [ "$count" = 1 ] || fail "invalid ready head count=$count, expected 1"
  pass "production named-head refusal keeps an unpublished ready claim counted"

  git -C "$dir/wt" update-ref refs/remotes/origin/worker "$head"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: done" "preserved ready head was not accepted: $out"
  count=$(count_workers "$dir") || fail "ready count failed"
  [ "$count" = 0 ] || fail "accepted ready head count=$count, expected 0"
  pass "accepted terminal-ready delivery leaves the away spend count"

  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task busy --current-gen \
    --source claude-hook --event user-prompt-submit >/dev/null || fail "busy record failed"
  out=$(read_worker "$dir" task)
  assert_contains "$out" "state: working" "stale ready log hid authoritative busy state: $out"
  count=$(count_workers "$dir") || fail "busy recount failed"
  [ "$count" = 1 ] || fail "stale ready log with active current state count=$count, expected 1"
  pass "authoritative busy state overrides an unchanged ready log for spend admission"

  printf 'working: review feedback arrived\n' >> "$dir/state/task.status"
  count=$(count_workers "$dir") || fail "resumed recount failed"
  [ "$count" = 1 ] || fail "explicitly resumed worker count=$count, expected 1"
  pass "an explicit working declaration keeps resumed work counted"
}

test_other_delivery_modes_and_scout() {
  local dir mode count
  dir="$TMP_ROOT/other-deliveries"
  install_tools "$dir"
  git init -q -b fm/worker "$dir/wt"
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" update-ref refs/remotes/origin/worker "$(git -C "$dir/wt" rev-parse HEAD)"
  git clone -q "$dir/wt" "$dir/project"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
    --source claude-hook --event stop >/dev/null || fail "idle record failed"
  for mode in direct-PR local-only; do
    fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
      "project=$dir/project" "kind=ship" "mode=$mode" "harness=claude"
    printf 'done: ready for review\n' > "$dir/state/task.status"
    count=$(count_workers "$dir") || fail "$mode count failed"
    [ "$count" = 0 ] || fail "accepted $mode delivery count=$count, expected 0"
    "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task busy --current-gen \
      --source claude-hook --event user-prompt-submit >/dev/null || fail "$mode busy record failed"
    count=$(count_workers "$dir")
    [ "$count" = 1 ] || fail "busy $mode delivery was excluded"
    "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task unknown --current-gen \
      --source claude-hook --event unavailable >/dev/null || fail "$mode unknown record failed"
    count=$(count_workers "$dir")
    [ "$count" = 1 ] || fail "unknown $mode delivery was excluded"
    "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task idle --current-gen \
      --source claude-hook --event stop >/dev/null || fail "$mode stop record failed"
  done
  fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
    "project=$dir/project" "kind=ship" "harness=claude"
  printf 'done: implementation complete\n' > "$dir/state/task.status"
  count=$(count_workers "$dir") || fail "default-mode count failed"
  [ "$count" = 1 ] || fail "default no-mistakes handoff count=$count, expected 1"
  fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
    "kind=scout" "harness=claude"
  printf 'done: report complete\n' > "$dir/state/task.status"
  count=$(count_workers "$dir") || fail "scout count failed"
  [ "$count" = 0 ] || fail "finished scout count=$count, expected 0"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task busy --current-gen \
    --source claude-hook --event user-prompt-submit >/dev/null || fail "scout busy record failed"
  count=$(count_workers "$dir")
  [ "$count" = 1 ] || fail "busy scout with stale done status was excluded"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task unknown --current-gen \
    --source claude-hook --event unavailable >/dev/null || fail "scout unknown record failed"
  count=$(count_workers "$dir")
  [ "$count" = 1 ] || fail "unknown scout with stale done status was excluded"
  pass "direct-PR, local-only and scout deliveries are excluded; the default-mode handoff still counts"
}

test_completed_run_unknown_activity() {
  local dir head out harness activity
  dir="$TMP_ROOT/completed-run-unknown"
  install_tools "$dir"
  git init -q -b fm/worker "$dir/wt"
  git -C "$dir/wt" commit -q --allow-empty -m init
  head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" update-ref refs/remotes/origin/worker "$head"
  printf 'done: PR https://example.test/o/r/pull/9 checks green\n' > "$dir/state/task.status"
  cat > "$dir/run.toon" <<EOF
run:
  id: "01RUN"
  branch: fm/worker
  status: completed
  head: "$head"
  pr: "https://example.test/o/r/pull/9"
  findings: none
outcome: passed
EOF
  printf '  completed fm/worker %s 2026-10-04 10:00\n' "${head:0:7}" > "$dir/runs.toon"
  for harness in claude codex; do
    fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
      "project=$dir/wt" "kind=ship" "mode=no-mistakes" "harness=$harness"
    for activity in busy unknown; do
      "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state "$activity" \
        --source fm-spawn --event resume >/dev/null || fail "resume record failed"
      if [ "$harness" = codex ]; then
        out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" bash -c \
          '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"; fm_busy_classify_meta "$2/state/task.meta" task "$2/state"' \
          _ "$ROOT" "$dir")
        [ "$out" = 'unknown codex-unverified' ] || fail "Codex did not reproduce unknown activity: $out"
      fi
      out=$(read_worker "$dir" task)
      assert_contains "$out" "state: done" "completed run did not reproduce stale done: $out"
      assert_contains "$out" "source: run-step" "completed run was not attributed: $out"
      assert_spending_snapshot "$dir"
    done
    [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "resume changed HEAD"
  done
  # Even an idle record cannot turn an unreadable endpoint into proven idle presence.
  fm_write_meta "$dir/state/task.meta" "window=unreadable:worker" "worktree=$dir/wt" \
    "project=$dir/wt" "kind=ship" "mode=no-mistakes" "harness=claude"
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
    --source claude-hook --event stop >/dev/null || fail "idle record failed"
  assert_spending_snapshot "$dir"
  pass "busy then unknown activity and unreadable endpoints override an accepted completed run"
}

test_bounded_presence_reads() {
  local dir stage harness backend target count rc
  # Each fixture stalls an external read reached by a different production path.
  for stage in inventory process activity crew-presence crew-capture herdr-presence herdr-agent herdr-process herdr-absence herdr-activity herdr-crew; do
    dir="$TMP_ROOT/hung-$stage"
    install_tools "$dir"
    mkdir -p "$dir/wt"
    backend=tmux
    target=fixture:worker
    harness=claude
    [ "$stage" != activity ] || harness=grok
    case "$stage" in herdr-*) backend=herdr; target=fixture:w1:p2 ;; esac
    fm_write_meta "$dir/state/task.meta" "window=$target" "worktree=$dir/wt" \
      "kind=scout" "backend=$backend" "harness=$harness"
    printf 'done: report complete\n' > "$dir/state/task.status"
    if [ "$stage" != activity ] && [ "$stage" != herdr-activity ]; then
      "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
        --source claude-hook --event stop >/dev/null || fail "hang idle record failed"
    fi
    mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-ok"
    cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$FM_HANG_STAGE:$1:${*: -1}" in
  inventory:list-windows:*|process:display-message:'#{pane_current_command}'|\
  activity:capture-pane:*|crew-presence:display-message:'#{pane_id}'|crew-capture:capture-pane:*)
    touch "$FM_HOME/read-hung"
    sleep 30
    exit 1
    ;;
esac
exec "$FM_HOME/fakebin/tmux-ok" "$@"
SH
    cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pane get')
    if [ "$FM_HANG_STAGE" = herdr-absence ] && [ ! -f "$FM_HOME/absence-read" ]; then
      touch "$FM_HOME/absence-read"
      printf '{"error":{"code":"pane_not_found"}}\n'
      exit 0
    fi
    case "$FM_HANG_STAGE" in
      herdr-presence|herdr-absence) touch "$FM_HOME/read-hung"; sleep 30; exit 1 ;;
    esac
    printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  'agent get')
    if [ "$FM_HANG_STAGE" = herdr-agent ]; then
      touch "$FM_HOME/read-hung"; sleep 30; exit 1
    fi
    printf '{"error":{"code":"agent_not_found"}}\n'
    ;;
  'pane process-info')
    if [ "$FM_HANG_STAGE" = herdr-process ]; then
      touch "$FM_HOME/read-hung"; sleep 30; exit 1
    fi
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":101,"foreground_processes":[{"pid":102,"name":"claude","argv":["claude"]}]}}}\n'
    ;;
  'status --json')
    if [ "$FM_HANG_STAGE" = herdr-activity ]; then
      touch "$FM_HOME/read-hung"; sleep 30; exit 1
    fi
    printf '{"server":{"running":true}}\n'
    ;;
  'pane read') touch "$FM_HOME/read-hung"; sleep 30; exit 1 ;;
  *) exit 1 ;;
esac
SH
    chmod +x "$dir/fakebin/tmux" "$dir/fakebin/herdr"
    # This outer watchdog makes an unbounded regression fail instead of wedging CI.
    rc=0
    count=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_HANG_STAGE="$stage" \
      NM_HOME="$dir/unused-nm-home" bash -c \
      '. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 12 "$1/bin/fm-afk-spend-count.sh" "$2"' \
      _ "$ROOT" "$dir/state") || rc=$?
    [ -f "$dir/read-hung" ] || fail "$stage never reached the stalled CLI read"
    [ "$rc" -eq 0 ] || fail "$stage stalled the counter (exit $rc)"
    [ "$count" = 1 ] || fail "$stage dropped the worker after timeout: $count"
    pass "$stage timeout returns a conservative spend count"
  done
}

test_completed_run_unknown_activity
test_bounded_presence_reads
test_exited_worker_does_not_fill_cap
test_fresh_launch_reservation
test_admission_exemptions
test_reservation_precedes_exclusions
test_unreadable_and_unverified_backends_still_count
test_positive_death_and_ambiguous_endpoint
test_unregistered_herdr_worker
test_tmux_unproven_absence
test_completed_run_busy_turn
test_handoff_and_ready_use_production_crew_state
test_other_delivery_modes_and_scout
