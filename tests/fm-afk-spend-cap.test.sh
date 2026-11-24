#!/usr/bin/env bash
# Synthetic/offline away spend admission through production backend and DoD classifiers.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-spend-cap)
fm_git_identity fmtest fmtest@example.invalid
SPAWN_PID=
SPAWN_RELEASE=
FM_TEST_REAL_TMUX=$(command -v tmux || true)
REAL_TMUX_SOCKET=
cleanup_launch() {
  [ -z "$SPAWN_RELEASE" ] || touch "$SPAWN_RELEASE"
  if [ -n "$SPAWN_PID" ]; then
    kill "$SPAWN_PID" 2>/dev/null || true
    wait "$SPAWN_PID" 2>/dev/null || true
  fi
  if [ -n "${REAL_TMUX_SOCKET:-}" ] && [ -n "${FM_TEST_REAL_TMUX:-}" ]; then
    "$FM_TEST_REAL_TMUX" -L "$REAL_TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_launch EXIT

test_fresh_launch_reservation() {
  local kind scenario entry dir home id out rc count i endpoint_state staged marker start_wait
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
        staged=
        prev=
        for a in "$@"; do
          if [ "$prev" = "-l" ]; then
            case "$a" in
              ". '"*) rest=${a#". '"}; staged=${rest%%"'"*} ;;
            esac
          fi
          prev=$a
        done
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
    start_wait=30
    case "$scenario" in
      timeout|rename-timeout) start_wait=2 ;;
    esac
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_BACKEND=tmux FM_SUPERVISION_ACTOR=main \
      FM_SPAWN_NO_GUARD=1 FM_TEST_SPAWN_START_WAIT_SECONDS="$start_wait" TMUX=fake,1,0 FM_RESERVATION_ID="$id" \
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
    count=$(FM_SPAWN_CAP_LAUNCH_GRACE=0 FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
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
    count=$(FM_SPAWN_CAP_LAUNCH_GRACE=0 FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
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
        count=$(FM_SPAWN_CAP_LAUNCH_GRACE=0 FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
        [ "$count" = 1 ] || fail "uncertain startup lost its reservation"
        rm "$home/unreadable"
        rc=0
        out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_SUPERVISION_ACTOR=main \
          FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" PATH="$home/fakebin:$PATH" \
          "$ROOT/bin/fm-afk-return.sh" check 2>&1) || rc=$?
        [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || fail "return count failed: $out"
        assert_contains "$out" '1 task(s) live at return.' "return dropped a delivered launch reservation: $out"
        touch "$home/started"
        # Raw admission treats pane-command `other` as ambiguous until the
        # staged start marker exists, so a simulated start must write it too.
        if [ -f "$home/raw" ] && [ -f "$home/staged-path" ]; then
          touch "$(cat "$home/staged-path").start"
        fi
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
        [ "$scenario" != rename-timeout ] || assert_grep 'startup was not established within 2s' "$home/launch.log" "relocated startup did not reach timeout cancellation"
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
        [ "$scenario" != timeout ] || assert_grep 'startup was not established within 2s' "$home/launch.log" "timeout did not report startup failure"
        staged=$(cat "$home/staged-path")
        [ ! -f "$staged" ] || fail "cancelled startup left a runnable staged launch"
        if [ "$scenario" = cleanup-refused ]; then
          [ -f "$home/state/$id.meta" ] || fail "uncertain cleanup discarded the endpoint record"
          count=$(FM_SPAWN_CAP_LAUNCH_GRACE=0 FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
          [ "$count" = 1 ] || fail "uncancelled startup stopped reserving spending capacity"
          out=$(FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" \
            FM_SUPERVISION_ACTOR=main fm_test_run_spawn "$home" "$dir/wt" "$home/fakebin" \
            "$id" --relaunch) || fail "recovery relaunch failed: $out"
          assert_contains "$out" "spawned $id" "recovery relaunch did not report success"
          count=$(FM_SPAWN_CAP_LAUNCH_GRACE=0 FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
          [ "$count" = 0 ] || fail "successful recovery retained the previous cleanup reservation"
        else
          [ ! -e "$home/state/$id.meta" ] || fail "cancelled startup retained its record"
          [ ! -e "$home/endpoint" ] || fail "cancelled startup retained its endpoint"
        fi
        count=$(FM_SPAWN_CAP_LAUNCH_GRACE=0 FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
        [ "$count" = 0 ] || fail "cancelled startup left a permanent reservation: $count"
        pass "$kind $scenario startup frees capacity after confirmed cancellation"
        continue
        ;;
    esac
    [ "$rc" -eq 0 ] || fail "reserved launch failed: $(cat "$home/launch.log")"
    [ ! -e "$home/state/.meta-$id.lock" ] || fail "successful launch left its lifecycle lock"
    count=$(FM_SPAWN_CAP_LAUNCH_GRACE=0 FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
    if [ "$scenario" = finished ]; then
      [ "$count" = 0 ] || fail "a command that finished between probes retained its reservation"
    else
      [ "$count" = 1 ] || fail "started worker stopped counting: $count"
      if [ "$scenario" = raw ]; then
        FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" assert_spending_snapshot "$home"
      fi
      rm "$home/started"
    fi
    count=$(FM_SPAWN_CAP_LAUNCH_GRACE=0 FM_RESERVATION_ID="$id" FM_RESERVATION_WT="$dir/wt" count_workers "$home")
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
    if [ "$target" = missing:worker ] || [ -z "$target" ]; then
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
  printf '  completed fm/worker %s 2026-10-04 10:00  https://example.test/o/r/pull/9\n' "${head:0:7}" > "$dir/runs.toon"
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
    FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-afk-contract.sh" live-workers
}

test_recent_spawn_generation_skips_endpoint_probe() {
  local home now out
  home="$TMP_ROOT/recent-spawn-gen"
  install_tools "$home"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/probed"
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  now=$(date +%s)
  fm_write_meta "$home/state/task.meta" \
    "window=firstmate:fm-task" "kind=ship" "spawn_gen=s${now}.1"
  out=$(count_workers "$home") || fail "recent launch count failed: $out"
  [ "$out" = 1 ] || fail "recent launch did not reserve one slot: $out"
  [ ! -e "$home/probed" ] || fail "recent launch did not skip the backend probe"
  fm_write_meta "$home/state/task.meta" \
    "window=firstmate:fm-task" "kind=ship" "spawn_gen=s$((now - 180)).1"
  out=$(count_workers "$home") || fail "aged launch count failed: $out"
  [ "$out" = 1 ] || fail "unproven aged endpoint did not reserve one slot: $out"
  [ -e "$home/probed" ] || fail "aged launch did not probe its endpoint"
  pass "recent spawn generations reserve capacity without probing; aged generations use the endpoint probe"
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
  [ "$count" = 6 ] || fail "unreadable/unverified backend count=$count, expected 6 (five supported backends and one absent target)"
  pass "unreadable/unverified backends and an absent target count; stopped endpoints and secondmates do not"
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
  printf '  completed fm/worker %s 2026-10-04 10:00  https://example.test/o/r/pull/9\n' "${head:0:7}" > "$dir/runs.toon"
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
  for stage in inventory process activity waiting-activity crew-capture herdr-presence herdr-agent herdr-process herdr-absence herdr-activity herdr-crew; do
    dir="$TMP_ROOT/hung-$stage"
    install_tools "$dir"
    mkdir -p "$dir/wt"
    backend=tmux
    target=fixture:worker
    harness=claude
    case "$stage" in activity|waiting-activity) harness=grok ;; esac
    case "$stage" in herdr-*) backend=herdr; target=fixture:w1:p2 ;; esac
    fm_write_meta "$dir/state/task.meta" "window=$target" "worktree=$dir/wt" \
      "kind=scout" "backend=$backend" "harness=$harness"
    printf 'done: report complete\n' > "$dir/state/task.status"
    [ "$stage" != waiting-activity ] || printf 'paused: waiting\n' > "$dir/state/task.status"
    if [ "$stage" != activity ] && [ "$stage" != waiting-activity ] && [ "$stage" != herdr-activity ]; then
      "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
        --source claude-hook --event stop >/dev/null || fail "hang idle record failed"
    fi
    mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-ok"
    cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$FM_HANG_STAGE:$1:${*: -1}" in
  inventory:list-windows:*|process:display-message:'#{pane_current_command}'|\
  activity:capture-pane:*|waiting-activity:capture-pane:*|crew-presence:display-message:'#{pane_id}'|crew-capture:capture-pane:*)
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
      '. "$1/bin/fm-timeout-lib.sh"; fm_run_timed 12 env FM_STATE_OVERRIDE="$2" "$1/bin/fm-afk-contract.sh" live-workers' \
      _ "$ROOT" "$dir/state") || rc=$?
    [ -f "$dir/read-hung" ] || fail "$stage never reached the stalled CLI read"
    [ "$rc" -eq 0 ] || fail "$stage stalled the counter (exit $rc)"
    [ "$count" = 1 ] || fail "$stage dropped the worker after timeout: $count"
    pass "$stage timeout returns a conservative spend count"
  done
}

test_waiting_workers_require_proven_idle() {
  local dir verb kind form declaration activity count expected head out failures=0
  waiting_count_check() {
    local expected=$1 label=$2 observed
    observed=$(count_workers "$dir") || fail "$label count failed"
    if [ "$observed" = "$expected" ]; then
      pass "$label counts $expected worker(s)"
    else
      printf 'FAIL: %s counts %s, expected %s\n' "$label" "$observed" "$expected" >&2
      failures=$((failures + 1))
    fi
  }
  for verb in paused captain-held needs-decision; do
    for kind in ship scout; do
      for form in plain keyed; do
        dir="$TMP_ROOT/waiting-$verb-$kind-$form"
        install_tools "$dir"
        git init -q -b fm/worker "$dir/wt"
        git -C "$dir/wt" commit -q --allow-empty -m init
        declaration=$verb
        [ "$form" != keyed ] || declaration="$verb [key=wait]"
        printf 'done: implementation complete\n%s: waiting for an answer\n' "$declaration" \
          > "$dir/state/task.status"
        for activity in idle busy unknown missing malformed gen-mismatch source-mismatch unreadable-endpoint; do
          fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
            "project=$dir/wt" "kind=$kind" "mode=no-mistakes" "harness=claude"
          "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
            --source claude-hook --event stop >/dev/null || fail "$verb idle arm failed"
          expected=1
          case "$activity" in
            idle) expected=0 ;;
            busy|unknown)
              "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" task "$activity" --current-gen \
                --source claude-hook --event user-prompt-submit >/dev/null \
                || fail "$verb $activity record failed"
              ;;
            missing) rm "$dir/state/task.busy-state" ;;
            malformed) printf 'invalid record\n' > "$dir/state/task.busy-state" ;;
            gen-mismatch) printf 'different-generation\n' > "$dir/state/task.busy-gen" ;;
            source-mismatch)
              fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
                "project=$dir/wt" "kind=$kind" "mode=no-mistakes" "harness=codex"
              ;;
            unreadable-endpoint)
              fm_write_meta "$dir/state/task.meta" "window=unreadable:worker" "worktree=$dir/wt" \
                "project=$dir/wt" "kind=$kind" "mode=no-mistakes" "harness=claude"
              ;;
          esac
          waiting_count_check "$expected" "$verb $kind $form with $activity evidence"
        done
      done
    done

    dir="$TMP_ROOT/waiting-$verb-ship-plain"
    fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/wt" \
      "project=$dir/wt" "kind=ship" "mode=no-mistakes" "harness=claude"
    "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" task --state idle \
      --source claude-hook --event stop >/dev/null || fail "$verb run idle arm failed"
    head=$(git -C "$dir/wt" rev-parse HEAD)
    cat > "$dir/run.toon" <<EOF
run:
  id: "01RUN"
  branch: fm/worker
  status: running
  head: "$head"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
    printf '  running fm/worker %s 2026-10-13 10:00\n' "${head:0:7}" > "$dir/runs.toon"
    out=$(read_worker "$dir" task)
    assert_contains "$out" 'state: working' "$verb fixture did not reproduce an executing run: $out"
    assert_contains "$out" 'source: run-step' "$verb fixture lost run attribution: $out"
    waiting_count_check 1 "$verb with an executing validation run"
    sed 's/review,running/review,awaiting_approval/' "$dir/run.toon" > "$dir/run.next"
    mv "$dir/run.next" "$dir/run.toon"
    out=$(read_worker "$dir" task)
    assert_contains "$out" 'state: parked' "$verb fixture did not park at the gate: $out"
    waiting_count_check 0 "$verb with an idle parked validation run"
    sed -e 's/status: running/status: completed/' \
      -e 's/review,awaiting_approval/review,completed/' "$dir/run.toon" > "$dir/run.next"
    mv "$dir/run.next" "$dir/run.toon"
    printf '  completed fm/worker %s 2026-10-13 10:00\n' "${head:0:7}" > "$dir/runs.toon"
    for form in plain keyed; do
      declaration=$verb
      [ "$form" != keyed ] || declaration="$verb [key=wait]"
      printf 'done: implementation complete\n%s: waiting for an answer\n' "$declaration" \
        > "$dir/state/task.status"
      out=$(read_worker "$dir" task)
      assert_contains "$out" 'state: done' "$verb $form fixture did not complete validation: $out"
      assert_contains "$out" 'source: run-step' "$verb $form completed run lost attribution: $out"
      waiting_count_check 0 "$verb $form with an idle completed validation run"
    done
    sed 's/status: completed/status: cancelled/' "$dir/run.toon" > "$dir/run.next"
    mv "$dir/run.next" "$dir/run.toon"
    printf '  cancelled fm/worker %s 2026-10-13 10:00\n' "${head:0:7}" > "$dir/runs.toon"
    out=$(read_worker "$dir" task)
    assert_contains "$out" 'state: unknown' "$verb fixture did not reproduce an uncertain run: $out"
    assert_contains "$out" 'source: run-step' "$verb uncertain run lost attribution: $out"
    waiting_count_check 1 "$verb with an idle uncertain validation run"
    rm "$dir/run.toon" "$dir/runs.toon"
    printf '%s [key=wait]: waiting\nresolved [key=wait]: answered\n' "$verb" > "$dir/state/task.status"
    waiting_count_check 1 "$verb with its wait retracted"
    printf '%s [key=wait]: waiting\nworking: resumed without resolving the old key\n' "$verb" > "$dir/state/task.status"
    waiting_count_check 1 "$verb followed by a newer working event"
    printf '%s [key=wait]: waiting\nunknown-prefix: contradictory newer event\n' "$verb" > "$dir/state/task.status"
    waiting_count_check 1 "$verb fixture with a newer unrecognized event"
  done

  dir="$TMP_ROOT/waiting-needs-decision-ship-plain"
  printf 'needs-decision [key=a]: waiting\nworking: resumed\nresolved [key=b]: unrelated answer\n' > "$dir/state/task.status"
  waiting_count_check 1 'open decision with working before an unrelated resolution'
  printf 'needs-decision [key=a]: waiting\nneeds-decision [key=b]: waiting\nworking: resumed\nresolved [key=b]: answered\n' > "$dir/state/task.status"
  waiting_count_check 1 'older open decision with working before the newer resolution'

  dir="$TMP_ROOT/waiting-paused-ship-plain"
  printf 'paused [key=wait]: waiting\nresolved [key=other]: unrelated answer\n' > "$dir/state/task.status"
  waiting_count_check 0 'idle paused worker after an unrelated resolution'
  printf 'blocked [key=block]: unresolved obstacle\npaused: waiting\n' > "$dir/state/task.status"
  waiting_count_check 1 'idle pause with an open blocker'
  for verb in custom-paused custom-held; do
    printf '%s: waiting\n' "$verb" > "$dir/state/task.status"
    count=$(FM_CLASSIFY_PAUSED_VERB=custom-paused FM_CLASSIFY_CAPTAIN_HELD_VERB=custom-held count_workers "$dir")
    if [ "$count" = 0 ]; then
      pass "$verb uses the configured verb name"
    else
      printf 'FAIL: %s counts %s, expected 0\n' "$verb" "$count" >&2
      failures=$((failures + 1))
    fi
  done
  dir="$TMP_ROOT/waiting-captain-held-ship-plain"
  printf 'captain-held: waiting\n' > "$dir/state/task.status"
  fm_write_meta "$dir/state/task.meta" "window=fixture:worker" "worktree=$dir/missing-wt" \
    "kind=ship" "mode=no-mistakes" "harness=claude"
  waiting_count_check 1 'captain-held with a missing worktree current-state source'
  [ "$failures" = 0 ] || fail "$failures waiting-worker cases failed"
}

# The reads share one total deadline (FM_AFK_LIVE_WORKERS_TIMEOUT, default 20s).
# A probe that never answers is cut off; remaining records count as spending
# without being read, and live-workers still returns promptly. The sleep is
# longer than the bound so a missing deadline would stall; the test itself stays
# fast because the bound is 2s.
test_live_workers_total_budget_counts_unread_records() {
  local home out err t0 elapsed i
  home="$TMP_ROOT/live-budget"
  install_tools "$home"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
sleep 30
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  for i in 1 2 3; do
    fm_write_meta "$home/state/slow-$i.meta" "window=firstmate:fm-slow-$i" "kind=ship"
  done
  err="$home/live-workers.err"
  t0=$SECONDS
  out=$(FM_AFK_LIVE_WORKERS_TIMEOUT=2 FM_SPAWN_CAP_LAUNCH_GRACE=0 count_workers "$home" 2>"$err")
  elapsed=$((SECONDS - t0))
  [ "$elapsed" -le 8 ] || fail "live-workers ignored its total time bound (${elapsed}s)"
  [ "$out" = 3 ] || fail "records cut off by the time bound were not counted as spending: $out"
  assert_contains "$(cat "$err")" "truncated" \
    "live-workers did not report that remaining records were truncated: $(cat "$err")"
  pass "live-workers shares one total time bound and counts unread remaining records as spending"
}

# Fake tmux for capped spawn tests. Runs the typed `. 'path'; fallback` line
# with FM_FAKE_PANE_SHELL (bash, dash, or fish). Optional
# FM_FAKE_PANE_GIT_CONFIG_COUNT is exported into that pane. Copies the staged
# exit file to $FM_HOME/launch.exit and records the staged path.
write_capped_pane_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
window_file="$(dirname "$0")/.spawn-window"
case "${1:-}" in
  display-message)
    case "$*" in
      *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
      *"#{pane_current_command}"*) printf 'sleep\n'; exit 0 ;;
    esac
    printf 'firstmate\n'
    exit 0
    ;;
  list-windows)
    [ ! -s "$window_file" ] || cat "$window_file"
    exit 0
    ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    printf '@1\n'
    exit 0
    ;;
  kill-window)
    : > "$window_file"
    exit 0
    ;;
  send-keys)
    prev=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then
        case "$a" in
          ". '"*)
            rest=${a#". '"}
            staged=${rest%%"'"*}
            printf '%s\n' "$staged" > "$FM_HOME/staged-path"
            if [ -f "$staged" ]; then
              (
                sleep 0.5
                if [ -n "${FM_FAKE_PANE_GIT_CONFIG_COUNT:-}" ]; then
                  export GIT_CONFIG_COUNT="$FM_FAKE_PANE_GIT_CONFIG_COUNT"
                fi
                case "${FM_FAKE_PANE_SHELL:-bash}" in
                  fish) runner=fish ;;
                  dash) runner=dash ;;
                  zsh) runner=zsh ;;
                  *) runner=bash ;;
                esac
                run_line=$a
                if [ -n "${FM_FAKE_PANE_KEEP_TRAP:-}" ]; then
                  run_line="trap 'echo SURVIVED > \"$FM_HOME/trap.fired\"' EXIT; $a; trap > \"$FM_HOME/trap.saved\""
                fi
                $runner -c "$run_line"
                [ ! -f "$staged.exit" ] || cp "$staged.exit" "$FM_HOME/launch.exit"
              ) >"$FM_HOME/pane.out" 2>"$FM_HOME/pane.err" &
            fi
            ;;
        esac
      fi
      prev=$a
    done
    exit 0
    ;;
  has-session|new-session|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

capped_spawn_home() {  # <home> <proj> <wt> <id> <fakebin>
  fm_test_spawn_home "$1" claude
  fm_git_worktree "$2" "$3" "fm/$4"
  fm_test_spawn_brief "$1" "$4"
  mkdir -p "$5"
  fm_fake_exit0 "$5" treehouse no-mistakes
  write_capped_pane_tmux "$5"
  if command -v tasks-axi >/dev/null 2>&1; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$1/data/backlog.md"
    tasks-axi add "$4" "capped spawn fixture" --kind ship \
      --file "$1/data/backlog.md" >/dev/null \
      || fail "could not seed the capped spawn backlog row"
  fi
}

run_capped_spawn() {  # <pane-shell> <home> <wt> <fakebin> <id> <proj> [spawn-args...]
  local pane_shell=$1 home=$2 wt=$3 fakebin=$4
  shift 4
  export FM_FAKE_PANE_SHELL="$pane_shell" FM_TEST_PANE_SHELL="$pane_shell"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "capped spawn away entry failed"
  FM_SUPERVISION_ACTOR=main FM_BACKEND=tmux \
    FM_TEST_SPAWN_START_WAIT_SECONDS="${FM_TEST_SPAWN_START_WAIT_SECONDS:-8}" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

# OSC 7501 arm/disarm classify as `other` (ambiguous). A capped raw command
# that exits 127 must not treat that probe as a successful start.
# pane_shell is bash or fish: the fake sources the typed launch line in that
# shell so capture and fallback match the destination pane.
capped_raw_exit_127_rolls_back_with() {  # <pane-shell>
  local pane_shell=$1 home proj wt id out rc row fakebin label
  label=$pane_shell
  home="$TMP_ROOT/raw-127-$pane_shell/home"
  proj="$TMP_ROOT/raw-127-$pane_shell/project"
  wt="$TMP_ROOT/raw-127-$pane_shell/wt"
  id="raw-127-$pane_shell-$$"
  fakebin="$TMP_ROOT/raw-127-$pane_shell/fakebin"
  capped_spawn_home "$home" "$proj" "$wt" "$id" "$fakebin"
  rc=0
  out=$(run_capped_spawn "$pane_shell" "$home" "$wt" "$fakebin" \
    "$id" "$proj" 'no-such-fm-raw-cmd-127 --typo' --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -ne 0 ] || fail "capped raw command that exited 127 in $label reported success: $out"
  assert_contains "$out" "exited with status 127" \
    "capped raw 127 in $label did not report the command exit: $out"
  [ "$(cat "$home/launch.exit" 2>/dev/null)" = 127 ] \
    || fail "capped raw 127 in $label did not write exit file 127: $(cat "$home/launch.exit" 2>/dev/null)"
  [ ! -e "$home/state/$id.meta" ] || fail "capped raw 127 in $label kept its task record"
  if command -v tasks-axi >/dev/null 2>&1; then
    row=$(tasks-axi show "$id" --file "$home/data/backlog.md" 2>/dev/null |
      sed -n 's/^  state: *//p' | head -1)
    [ "$row" = queued ] || fail "capped raw 127 in $label left backlog at ${row:-missing}"
  fi
}

test_capped_raw_exit_127_rolls_back() {
  capped_raw_exit_127_rolls_back_with bash
  pass "a capped raw launch that exits 127 rolls back its record and queued backlog row"
}

test_capped_raw_exit_127_rolls_back_in_fish() {
  command -v fish >/dev/null 2>&1 \
    || fail "fish is required to prove capped raw-launch rollback in a fish pane"
  capped_raw_exit_127_rolls_back_with fish
  pass "a capped raw launch sourced by fish writes its exit file and rolls back on 127"
}

assert_capped_launch_not_sh_wrapped() {  # <staged-file> <raw-command>
  local staged=$1 raw=$2 body
  [ -f "$staged" ] || fail "capped spawn wrote no staged launch file"
  body=$(cat "$staged")
  case "$body" in
    *"/bin/sh -c "*) fail "capped launch wrapped the agent in /bin/sh -c: $body" ;;
  esac
  case "$body" in
    *"$raw"*) ;;
    *) fail "capped launch lost the agent line bytes: missing [$raw] in $body" ;;
  esac
}

test_capped_claude_doorbell_quotes_in_fish() {
  local home proj wt id out rc fakebin staged last
  command -v fish >/dev/null 2>&1 \
    || fail "fish is required to prove capped Claude doorbell quoting"
  home="$TMP_ROOT/doorbell-fish/home"
  proj="$TMP_ROOT/doorbell-fish/project"
  wt="$TMP_ROOT/doorbell-fish/wt"
  id="doorbell-fish-$$"
  fakebin="$TMP_ROOT/doorbell-fish/fakebin"
  capped_spawn_home "$home" "$proj" "$wt" "$id" "$fakebin"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" > "${FM_HOME}/claude.last-arg"
i=1
: > "${FM_HOME}/claude.argv.txt"
for a in "$@"; do
  printf 'ARG %s %s\n' "$i" "$a" >> "${FM_HOME}/claude.argv.txt"
  i=$((i + 1))
done
exit 0
SH
  chmod +x "$fakebin/claude"
  rc=0
  out=$(run_capped_spawn fish "$home" "$wt" "$fakebin" \
    "$id" "$proj" --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -eq 0 ] || fail "capped Claude spawn on fish failed: $out"
  staged=$(cat "$home/staged-path" 2>/dev/null)
  [ -f "$staged" ] || fail "capped Claude spawn on fish wrote no staged file"
  case "$(cat "$staged")" in
    *"/bin/sh -c "*) fail "capped Claude launch wrapped the agent in /bin/sh -c" ;;
  esac
  last=$(cat "$home/claude.last-arg" 2>/dev/null)
  [ -n "$last" ] || fail "capped Claude on fish did not record argv: $(cat "$home/pane.err" 2>/dev/null)"
  case "$last" in
    ": Firstmate operational input waiting: read '"*"' and handle its contents as Firstmate operational input.") ;;
    *) fail "capped Claude on fish lost doorbell quotes; argv was: $last" ;;
  esac
  [ "$(printf '%s' "$last" | "$ROOT/bin/fm-operational-input.sh" doorbell-kind)" = launch-brief ] \
    || fail "capped Claude doorbell on fish is not a launch-brief: $last"
  pass "a capped Claude launch on fish keeps doorbell quotes in argv"
}

capped_raw_quote_backslash_roundtrip_with() {  # <pane-shell>
  local pane_shell=$1 home proj wt id out rc fakebin staged raw expected runner
  home="$TMP_ROOT/raw-rt-$pane_shell/home"
  proj="$TMP_ROOT/raw-rt-$pane_shell/project"
  wt="$TMP_ROOT/raw-rt-$pane_shell/wt"
  id="raw-rt-$pane_shell-$$"
  fakebin="$TMP_ROOT/raw-rt-$pane_shell/fakebin"
  raw=$'printf %s -- it\\\'s a\\\\b'
  case "$pane_shell" in
    fish) runner=fish ;;
    dash) runner=dash ;;
    *) runner=bash ;;
  esac
  expected=$("$runner" -c "$raw")
  capped_spawn_home "$home" "$proj" "$wt" "$id" "$fakebin"
  rc=0
  out=$(run_capped_spawn "$pane_shell" "$home" "$wt" "$fakebin" \
    "$id" "$proj" "$raw" --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -eq 0 ] || fail "capped raw quote/backslash spawn on $pane_shell failed: $out"
  staged=$(cat "$home/staged-path" 2>/dev/null)
  assert_capped_launch_not_sh_wrapped "$staged" "$raw"
  [ "$(cat "$home/pane.out" 2>/dev/null)" = "$expected" ] \
    || fail "capped raw quote/backslash on $pane_shell did not round-trip; got [$(cat "$home/pane.out" 2>/dev/null)] want [$expected]"
}

test_capped_raw_quote_backslash_roundtrip() {
  local pane_shell
  command -v fish >/dev/null 2>&1 \
    || fail "fish is required to prove capped raw quote/backslash round-trip"
  command -v dash >/dev/null 2>&1 \
    || fail "dash is required to prove capped raw quote/backslash round-trip"
  for pane_shell in bash dash fish; do
    capped_raw_quote_backslash_roundtrip_with "$pane_shell"
  done
  pass "a capped raw command containing \\' and \\\\ round-trips on bash, dash, and fish"
}

test_capped_raw_source_and_cmd_on_bash() {
  local home proj wt id out rc fakebin staged src raw
  home="$TMP_ROOT/raw-source-bash/home"
  proj="$TMP_ROOT/raw-source-bash/project"
  wt="$TMP_ROOT/raw-source-bash/wt"
  id="raw-source-bash-$$"
  fakebin="$TMP_ROOT/raw-source-bash/fakebin"
  capped_spawn_home "$home" "$proj" "$wt" "$id" "$fakebin"
  src="$TMP_ROOT/raw-source-bash/activate.sh"
  mkdir -p "$(dirname "$src")"
  printf 'echo FROMFILE\n' > "$src"
  raw="source '$src' && echo RAN"
  rc=0
  out=$(run_capped_spawn bash "$home" "$wt" "$fakebin" \
    "$id" "$proj" "$raw" --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -eq 0 ] || fail "capped source && cmd spawn on bash failed: $out"
  staged=$(cat "$home/staged-path" 2>/dev/null)
  assert_capped_launch_not_sh_wrapped "$staged" "$raw"
  [ "$(cat "$home/pane.out" 2>/dev/null)" = $'FROMFILE\nRAN' ] \
    || fail "capped source && cmd on bash lost pane-shell parity: [$(cat "$home/pane.out" 2>/dev/null)]"
  pass "a capped raw source && cmd runs in the bash pane"
}

test_capped_bad_git_config_fails_fast() {
  local home proj wt id out rc fakebin t0 elapsed
  home="$TMP_ROOT/gitcfg-fast/home"
  proj="$TMP_ROOT/gitcfg-fast/project"
  wt="$TMP_ROOT/gitcfg-fast/wt"
  id="gitcfg-fast-$$"
  fakebin="$TMP_ROOT/gitcfg-fast/fakebin"
  capped_spawn_home "$home" "$proj" "$wt" "$id" "$fakebin"
  t0=$SECONDS
  rc=0
  out=$(
    export FM_FAKE_PANE_GIT_CONFIG_COUNT=bad
    FM_TEST_SPAWN_START_WAIT_SECONDS=8 \
      run_capped_spawn bash "$home" "$wt" "$fakebin" \
      "$id" "$proj" --mode no-mistakes --yolo off
  ) || rc=$?
  elapsed=$((SECONDS - t0))
  [ "$rc" -ne 0 ] || fail "capped spawn with bad GIT_CONFIG_COUNT succeeded: $out"
  assert_contains "$out" "exited with status" \
    "capped bad GIT_CONFIG_COUNT did not report the helper exit: $out"
  assert_not_contains "$out" "was not established within" \
    "capped bad GIT_CONFIG_COUNT timed out instead of failing fast: $out"
  [ "$elapsed" -le 6 ] \
    || fail "capped bad GIT_CONFIG_COUNT was not fast (${elapsed}s): $out"
  [ "$(cat "$home/launch.exit" 2>/dev/null)" = 1 ] \
    || fail "capped bad GIT_CONFIG_COUNT did not write exit status 1: $(cat "$home/launch.exit" 2>/dev/null)"
  pass "a capped launch with bad GIT_CONFIG_COUNT fails fast with its exit status"
}

test_spend_cap_forwards_truncation_note() {
  local home out rc i
  home="$TMP_ROOT/trunc-note"
  install_tools "$home"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
sleep 30
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  mkdir -p "$home/data" "$home/config" "$home/projects"
  for i in 1 2 3; do
    fm_write_meta "$home/state/slow-$i.meta" "window=firstmate:fm-slow-$i" "kind=ship"
  done
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "truncation-note away entry failed"
  rc=0
  out=$(PATH="$home/fakebin:$PATH" NM_HOME="$home/unused-nm-home" \
    FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_AFK_LIVE_WORKERS_TIMEOUT=2 \
    "$ROOT/bin/fm-spawn.sh" fresh "$home/absent-project" \
    --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "truncated spend-cap spawn did not refuse: $out"
  assert_contains "$out" "caps concurrent workers" "truncated spend-cap spawn did not refuse admission: $out"
  assert_contains "$out" "live-workers truncated: remaining records counted as spending" \
    "spawn swallowed the live-workers truncation note: $out"
  pass "spend-cap admission forwards the live-workers truncation note"
}

# Real tmux pane: start already in the isolated worktree so treehouse get is a
# no-op, then run a capped Claude whose process is `sleep` (ambiguous, not
# raw) so the wait loop keeps waiting until the exit file or the timeout.
capped_kill_pane_rolls_back_with() {  # <pane-shell>
  local pane_shell=$1 home proj wt id fakebin real_tmux socket shim spawn_home
  local real_shell pane_cmd qfake qwt qshell start rc out pid i f
  [ -n "$FM_TEST_REAL_TMUX" ] || fail "tmux is required to prove capped pane-death rollback"
  command -v "$pane_shell" >/dev/null 2>&1 \
    || fail "$pane_shell is required to prove capped pane-death rollback"
  case "$pane_shell" in
    fish) real_shell=$(command -v fish) ;;
    *) real_shell=$(command -v bash) ;;
  esac
  [ -n "$real_shell" ] || fail "could not resolve $pane_shell"
  real_tmux=$FM_TEST_REAL_TMUX
  home="$TMP_ROOT/kill-pane-$pane_shell/home"
  proj="$TMP_ROOT/kill-pane-$pane_shell/project"
  wt="$TMP_ROOT/kill-pane-$pane_shell/wt"
  id="kill-pane-$pane_shell-$$"
  fakebin="$TMP_ROOT/kill-pane-$pane_shell/fakebin"
  socket="fm-kill-pane-$pane_shell-$$"
  REAL_TMUX_SOCKET=$socket
  capped_spawn_home "$home" "$proj" "$wt" "$id" "$fakebin"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
exec sleep 60
SH
  chmod +x "$fakebin/claude"
  shim="$TMP_ROOT/kill-pane-$pane_shell/shim"
  mkdir -p "$shim"
  cat > "$shim/tmux" <<SH
#!/usr/bin/env bash
exec "$real_tmux" -f /dev/null -L "$socket" "\$@"
SH
  chmod +x "$shim/tmux"
  spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  qfake=$(printf '%q' "$fakebin")
  qwt=$(printf '%q' "$wt")
  qshell=$(printf '%q' "$real_shell")
  pane_cmd="export PATH=$qfake:\$PATH; cd $qwt && exec $qshell"
  case "$pane_shell" in
    fish) pane_cmd="$pane_cmd --no-config" ;;
    *) pane_cmd="$pane_cmd --noprofile --norc" ;;
  esac
  "$real_tmux" -f /dev/null -L "$socket" new-session -d -s firstmate -n supervisor \
    || fail "real tmux: could not create the firstmate session for $pane_shell"
  "$real_tmux" -L "$socket" set-option -g remain-on-exit on
  "$real_tmux" -L "$socket" set-option -t firstmate default-shell /bin/bash
  "$real_tmux" -L "$socket" set-option -t firstmate default-command "$pane_cmd"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "kill-pane away entry failed"
  rc=0
  env -u TMUX FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR= FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_SUPERVISION_ACTOR=main \
    FM_TEST_SPAWN_START_WAIT_SECONDS=8 \
    PATH="$shim:$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --mode no-mistakes --yolo off \
    >"$home/launch.log" 2>&1 &
  # shellcheck disable=SC2031 # $! is this background spawn, captured before any later command substitution.
  SPAWN_PID=$!
  start=
  for i in $(seq 1 80); do
    for f in /tmp/fm-"$id"+*/launch.*.start; do
      if [ -f "$f" ]; then
        start=$f
        break
      fi
    done
    [ -n "$start" ] && break
    kill -0 "$SPAWN_PID" 2>/dev/null || break
    sleep 0.1
  done
  [ -n "$start" ] || fail "capped $pane_shell pane never wrote a start marker: $(cat "$home/launch.log")"
  pid=$("$real_tmux" -L "$socket" display-message -p -t "firstmate:fm-$id" '#{pane_pid}' 2>/dev/null || true)
  [ -n "$pid" ] || fail "capped $pane_shell pane pid was empty after start: $(cat "$home/launch.log")"
  kill -HUP "$pid" 2>/dev/null || true
  wait "$SPAWN_PID" || rc=$?
  SPAWN_PID=
  out=$(cat "$home/launch.log")
  "$real_tmux" -L "$socket" kill-server >/dev/null 2>&1 || true
  REAL_TMUX_SOCKET=
  [ "$rc" -ne 0 ] || fail "capped $pane_shell pane death was recorded as success: $out"
  assert_not_contains "$out" "spawned $id" \
    "capped $pane_shell pane death printed a successful spawn: $out"
  case "$pane_shell" in
    bash)
      assert_contains "$out" "exited with status 129" \
        "capped bash pane death did not map EXIT 0 to 129: $out"
      ;;
    fish)
      assert_contains "$out" "was not established within" \
        "capped fish pane death did not fall through to rollback: $out"
      ;;
  esac
  if [ -e "$home/state/$id.meta" ]; then
    grep -qx 'cleanup_recovery=launch' "$home/state/$id.meta" \
      || fail "capped $pane_shell pane death kept a published record: $(cat "$home/state/$id.meta")"
  fi
}

test_capped_kill_pane_rolls_back() {
  command -v fish >/dev/null 2>&1 \
    || fail "fish is required to prove capped pane-death rollback"
  capped_kill_pane_rolls_back_with bash
  capped_kill_pane_rolls_back_with fish
  pass "a capped launch whose pane dies mid-startup rolls back on bash and fish"
}

test_capped_posix_exit_trap_survives() {
  local pane_shell home proj wt id fakebin out rc
  command -v zsh >/dev/null 2>&1 \
    || fail "zsh is required to prove a pre-existing EXIT trap survives a capped launch"
  command -v dash >/dev/null 2>&1 \
    || fail "dash is required to prove a pre-existing EXIT trap survives a capped launch"
  for pane_shell in bash zsh dash; do
    home="$TMP_ROOT/keep-trap-$pane_shell/home"
    proj="$TMP_ROOT/keep-trap-$pane_shell/project"
    wt="$TMP_ROOT/keep-trap-$pane_shell/wt"
    id="keep-trap-$pane_shell-$$"
    fakebin="$TMP_ROOT/keep-trap-$pane_shell/fakebin"
    capped_spawn_home "$home" "$proj" "$wt" "$id" "$fakebin"
    rc=0
    out=$(
      export FM_FAKE_PANE_KEEP_TRAP=1
      run_capped_spawn "$pane_shell" "$home" "$wt" "$fakebin" \
        "$id" "$proj" 'echo keep-trap-ok' --mode no-mistakes --yolo off
    ) || rc=$?
    [ "$rc" -eq 0 ] || fail "capped keep-trap spawn on $pane_shell failed: $out"
    [ "$(cat "$home/trap.fired" 2>/dev/null)" = SURVIVED ] \
      || fail "capped launch on $pane_shell dropped the pre-existing EXIT trap: $(cat "$home/pane.err" 2>/dev/null) saved=$(cat "$home/trap.saved" 2>/dev/null)"
  done
  pass "a pre-existing EXIT trap survives a capped launch on bash, zsh, and dash"
}

probe_capped_herdr_dialect() {  # fail|empty-pid
  local mode=$1
  ROOT="$ROOT" FM_HERDR_PROCESS_INFO_MODE="$mode" bash -c '
    set -u
    BACKEND=herdr
    T=fixture:w1:p2
    SHELL=/usr/bin/fish
    unset FM_TEST_PANE_SHELL SPAWN_CAPPED_PANE_DIALECT
    case "${FM_HERDR_PROCESS_INFO_MODE:-}" in
      fail) fm_backend_herdr_cli() { return 1; } ;;
      *) fm_backend_herdr_cli() { printf "%s\n" "{\"result\":{\"process_info\":{}}}"; } ;;
    esac
    eval "$(sed -n "/^spawn_capped_pane_comm()/,/^# Keep the uncapped OSC frame/p" \
      "$ROOT/bin/fm-spawn.sh" | sed "\$d")"
    spawn_capped_pane_dialect
  '
}

test_capped_herdr_empty_process_info_uses_shell() {
  local got
  got=$(probe_capped_herdr_dialect fail)
  [ "$got" = fish ] \
    || fail "herdr process-info failure with SHELL=/usr/bin/fish picked '$got', not fish"
  got=$(probe_capped_herdr_dialect empty-pid)
  [ "$got" = fish ] \
    || fail "herdr process-info with no shell_pid and SHELL=/usr/bin/fish picked '$got', not fish"
  pass "empty Herdr process-info with SHELL=/usr/bin/fish picks the fish dialect"
}

# Real tmux session on a private socket. login=1 execs a login shell so the
# throwaway HOME can install a pre-existing EXIT trap.
capped_real_tmux_open() {  # <pane-shell> <home> <proj> <wt> <id> <fakebin> [login]
  local pane_shell=$1 home=$2 proj=$3 wt=$4 id=$5 fakebin=$6 login=${7:-}
  local real_tmux real_shell shim spawn_home qfake qwt qshell qhome pane_cmd rcfile
  [ -n "$FM_TEST_REAL_TMUX" ] || fail "tmux is required to prove capped pane-shell restore"
  command -v "$pane_shell" >/dev/null 2>&1 \
    || fail "$pane_shell is required to prove capped pane-shell restore"
  real_tmux=$FM_TEST_REAL_TMUX
  real_shell=$(command -v "$pane_shell")
  [ -n "$real_shell" ] || fail "could not resolve $pane_shell"
  capped_spawn_home "$home" "$proj" "$wt" "$id" "$fakebin"
  spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  shim="$home/../shim"
  mkdir -p "$shim"
  cat > "$shim/tmux" <<SH
#!/usr/bin/env bash
exec "$real_tmux" -f /dev/null -L "$REAL_TMUX_SOCKET" "\$@"
SH
  chmod +x "$shim/tmux"
  qfake=$(printf '%q' "$fakebin")
  qwt=$(printf '%q' "$wt")
  qshell=$(printf '%q' "$real_shell")
  qhome=$(printf '%q' "$spawn_home")
  if [ -n "$login" ]; then
    rcfile="trap 'echo SURVIVED >> \"\$HOME/trap.fired\"' EXIT"
    cat > "$spawn_home/.profile" <<EOF
$rcfile
export PATH=$qfake:\$PATH
EOF
    cp "$spawn_home/.profile" "$spawn_home/.bash_profile"
    cp "$spawn_home/.profile" "$spawn_home/.zprofile"
    cp "$spawn_home/.profile" "$spawn_home/.zshenv"
    pane_cmd="export PATH=$qfake:\$PATH HOME=$qhome ZDOTDIR=$qhome; cd $qwt && exec $qshell -l"
  else
    pane_cmd="export PATH=$qfake:\$PATH HOME=$qhome; cd $qwt && exec $qshell"
  fi
  "$real_tmux" -f /dev/null -L "$REAL_TMUX_SOCKET" new-session -d -s firstmate -n supervisor \
    || fail "real tmux: could not create the firstmate session for $pane_shell"
  "$real_tmux" -L "$REAL_TMUX_SOCKET" set-option -g remain-on-exit on
  "$real_tmux" -L "$REAL_TMUX_SOCKET" set-option -t firstmate default-shell /bin/bash
  "$real_tmux" -L "$REAL_TMUX_SOCKET" set-option -t firstmate default-command "$pane_cmd"
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
    || fail "real-tmux away entry failed"
  printf '%s' "$shim" > "$home/real-tmux-shim"
}

capped_real_tmux_spawn_env() {  # <home> <shim> <fakebin> <cmd...>
  local home=$1 shim=$2 fakebin=$3
  shift 3
  env -u TMUX FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    CLAUDE_CONFIG_DIR= FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_SUPERVISION_ACTOR=main \
    FM_TEST_SPAWN_START_WAIT_SECONDS="${FM_TEST_SPAWN_START_WAIT_SECONDS:-8}" \
    PATH="$shim:$fakebin:$PATH" "$@"
}

wait_capped_launch_artifact() {  # <id> <suffix> [samples]
  local id=$1 suffix=$2 samples=${3:-80} i f
  for i in $(seq 1 "$samples"); do
    for f in /tmp/fm-"$id"+*/launch.*"$suffix"; do
      if [ -f "$f" ]; then
        printf '%s' "$f"
        return 0
      fi
    done
    sleep 0.1
  done
  return 1
}

test_capped_dash_missing_traps_still_disarms() {
  local home proj wt id fakebin shim rc out exitf staged disarm_line
  command -v dash >/dev/null 2>&1 \
    || fail "dash is required to prove a missing saved-trap file still disarms"
  home="$TMP_ROOT/dash-missing-traps/home"
  proj="$TMP_ROOT/dash-missing-traps/project"
  wt="$TMP_ROOT/dash-missing-traps/wt"
  id="dash-missing-traps-$$"
  fakebin="$TMP_ROOT/dash-missing-traps/fakebin"
  REAL_TMUX_SOCKET="fm-dash-traps-$$"
  capped_real_tmux_open dash "$home" "$proj" "$wt" "$id" "$fakebin"
  shim=$(cat "$home/real-tmux-shim")
  rc=0
  out=$(
    FM_TEST_PANE_SHELL=dash FM_FAKE_PANE_SHELL=dash \
      capped_real_tmux_spawn_env "$home" "$shim" "$fakebin" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" \
      "for f in /tmp/fm-${id}+*/.launch.*.traps; do rm -f \"\$f\"; done; echo AGENT_OK" \
      --mode no-mistakes --yolo off
  ) || rc=$?
  "$FM_TEST_REAL_TMUX" -L "$REAL_TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  REAL_TMUX_SOCKET=
  [ "$rc" -eq 0 ] || fail "capped dash spawn with a deleted trap file failed: $out"
  exitf=$(wait_capped_launch_artifact "$id" ".exit" 1) || exitf=
  [ -n "$exitf" ] && [ "$(cat "$exitf")" = 0 ] \
    || fail "capped dash missing-traps did not write exit file 0: $(cat "$exitf" 2>/dev/null)"
  staged=$(printf '%s' "$exitf" | sed 's/\.exit$//')
  [ -f "$staged" ] || fail "capped dash missing-traps lost its staged launch file"
  disarm_line=$(tail -n 1 "$staged")
  case "$disarm_line" in
    *fm-osc7501.sh*disarm*) ;;
    *) fail "capped dash missing-traps launch had no disarm line: $disarm_line" ;;
  esac
  [ -z "$(compgen -G "/tmp/fm-$id+*/.launch.*.traps" || true)" ] \
    || fail "capped dash missing-traps left a trap file behind"
  pass "a capped dash launch still writes its exit file and runs disarm when the saved-trap file is gone"
}

capped_raw_return_restores_trap_with() {  # <pane-shell>
  local pane_shell=$1 home proj wt id fakebin shim rc out exitf trapsf inspected i
  local target fn_out trap_live
  home="$TMP_ROOT/return4-$pane_shell/home"
  proj="$TMP_ROOT/return4-$pane_shell/project"
  wt="$TMP_ROOT/return4-$pane_shell/wt"
  id="return4-$pane_shell-$$"
  fakebin="$TMP_ROOT/return4-$pane_shell/fakebin"
  REAL_TMUX_SOCKET="fm-return4-$pane_shell-$$"
  capped_real_tmux_open "$pane_shell" "$home" "$proj" "$wt" "$id" "$fakebin" login
  shim=$(cat "$home/real-tmux-shim")
  rc=0
  FM_TEST_PANE_SHELL=$pane_shell FM_FAKE_PANE_SHELL=$pane_shell \
    capped_real_tmux_spawn_env "$home" "$shim" "$fakebin" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" 'return 4' \
    --mode no-mistakes --yolo off >"$home/launch.log" 2>&1 &
  # shellcheck disable=SC2031 # $! is this background spawn, captured before any later command substitution.
  SPAWN_PID=$!
  exitf=
  for i in $(seq 1 80); do
    exitf=$(wait_capped_launch_artifact "$id" ".exit" 1) && break
    kill -0 "$SPAWN_PID" 2>/dev/null || break
  done
  [ -n "$exitf" ] || fail "capped return 4 on $pane_shell wrote no exit file: $(cat "$home/launch.log")"
  target="firstmate:fm-$id"
  fn_out=$home/fn.out
  trap_live=$home/trap.live
  "$FM_TEST_REAL_TMUX" -L "$REAL_TMUX_SOCKET" send-keys -t "$target" -l \
    "type __fm_capped_on_exit >'$fn_out' 2>&1; trap >'$trap_live'; echo INSPECTED >'$home/inspected'" \
    2>/dev/null || true
  "$FM_TEST_REAL_TMUX" -L "$REAL_TMUX_SOCKET" send-keys -t "$target" Enter 2>/dev/null || true
  inspected=
  for i in $(seq 1 20); do
    [ -f "$home/inspected" ] && inspected=1 && break
    sleep 0.1
  done
  wait "$SPAWN_PID" || rc=$?
  SPAWN_PID=
  out=$(cat "$home/launch.log")
  "$FM_TEST_REAL_TMUX" -L "$REAL_TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  REAL_TMUX_SOCKET=
  [ "$rc" -ne 0 ] || fail "capped return 4 on $pane_shell reported success: $out"
  [ "$(cat "$exitf")" = 4 ] \
    || fail "capped return 4 on $pane_shell wrote exit $(cat "$exitf"), not 4"
  trapsf="$(dirname "$exitf")/.launch.$(basename "$exitf" .exit | sed 's/^launch.//').traps"
  [ ! -e "$trapsf" ] || fail "capped return 4 on $pane_shell left $trapsf"
  if [ -n "$inspected" ]; then
    grep -Eq 'is a (shell )?function' "$fn_out" 2>/dev/null \
      && fail "capped return 4 on $pane_shell left __fm_capped_on_exit: $(cat "$fn_out")"
    grep -q SURVIVED "$trap_live" 2>/dev/null \
      || fail "capped return 4 on $pane_shell did not restore the prior EXIT trap: $(cat "$trap_live" 2>/dev/null)"
  else
    [ "$(cat "$home/user-home/trap.fired" 2>/dev/null)" = SURVIVED ] \
      || fail "capped return 4 on $pane_shell did not fire the restored EXIT trap"
  fi
}

test_capped_raw_return_restores_trap() {
  local pane_shell
  command -v zsh >/dev/null 2>&1 \
    || fail "zsh is required to prove a raw return restores the pane EXIT trap"
  command -v dash >/dev/null 2>&1 \
    || fail "dash is required to prove a raw return restores the pane EXIT trap"
  for pane_shell in bash zsh dash; do
    capped_raw_return_restores_trap_with "$pane_shell"
  done
  pass "a capped raw return 4 restores the prior EXIT trap on bash, zsh, and dash"
}

capped_allowlist_signal_keeps_trap_with() {  # <pane-shell> <signal> <status>
  local pane_shell=$1 signal=$2 expect=$3 home proj wt id fakebin shim rc out
  local exitf staged inspected i target trap_live fired
  home="$TMP_ROOT/allowlist-$signal-$pane_shell/home"
  proj="$TMP_ROOT/allowlist-$signal-$pane_shell/project"
  wt="$TMP_ROOT/allowlist-$signal-$pane_shell/wt"
  id="allowlist-$signal-$pane_shell-$$"
  fakebin="$TMP_ROOT/allowlist-$signal-$pane_shell/fakebin"
  REAL_TMUX_SOCKET="fm-allowlist-$signal-$pane_shell-$$"
  capped_real_tmux_open "$pane_shell" "$home" "$proj" "$wt" "$id" "$fakebin" login
  shim=$(cat "$home/real-tmux-shim")
  : > "$home/config/launch-env-allowlist"
  rc=0
  FM_TEST_PANE_SHELL=$pane_shell FM_FAKE_PANE_SHELL=$pane_shell \
    capped_real_tmux_spawn_env "$home" "$shim" "$fakebin" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "kill -$signal \$\$" \
    --mode no-mistakes --yolo off >"$home/launch.log" 2>&1 &
  # shellcheck disable=SC2031 # $! is this background spawn, captured before any later command substitution.
  SPAWN_PID=$!
  exitf=
  for i in $(seq 1 80); do
    exitf=$(wait_capped_launch_artifact "$id" ".exit" 1) && break
    kill -0 "$SPAWN_PID" 2>/dev/null || break
  done
  [ -n "$exitf" ] || fail "capped allowlist $signal on $pane_shell wrote no exit file: $(cat "$home/launch.log")"
  staged=${exitf%.exit}
  [ -f "$staged" ] || fail "capped allowlist $signal on $pane_shell lost its staged launch file"
  case "$(cat "$staged")" in
    *"/bin/sh -c "*) ;;
    *) fail "capped allowlist $signal on $pane_shell did not wrap the frame in /bin/sh -c" ;;
  esac
  target="firstmate:fm-$id"
  trap_live=$home/trap.live
  # dash does not run EXIT on SIGHUP from tmux kill-window, so ask the pane
  # to dump its traps and then `exit` while it is still at the prompt.
  "$FM_TEST_REAL_TMUX" -L "$REAL_TMUX_SOCKET" send-keys -t "$target" -l \
    "trap >'$trap_live'; echo INSPECTED >'$home/inspected'; exit" 2>/dev/null || true
  "$FM_TEST_REAL_TMUX" -L "$REAL_TMUX_SOCKET" send-keys -t "$target" Enter 2>/dev/null || true
  inspected=
  for i in $(seq 1 20); do
    [ -f "$home/inspected" ] && inspected=1 && break
    sleep 0.1
  done
  for i in $(seq 1 20); do
    [ -f "$home/user-home/trap.fired" ] && break
    sleep 0.1
  done
  wait "$SPAWN_PID" || rc=$?
  SPAWN_PID=
  out=$(cat "$home/launch.log")
  "$FM_TEST_REAL_TMUX" -L "$REAL_TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  REAL_TMUX_SOCKET=
  [ "$rc" -ne 0 ] || fail "capped allowlist $signal on $pane_shell reported success: $out"
  [ "$(cat "$exitf")" = "$expect" ] \
    || fail "capped allowlist $signal on $pane_shell wrote exit $(cat "$exitf"), not $expect"
  [ -n "$inspected" ] \
    || fail "capped allowlist $signal on $pane_shell pane was gone before trap inspect"
  grep -q SURVIVED "$trap_live" 2>/dev/null \
    || fail "capped allowlist $signal on $pane_shell wiped the pane EXIT trap: $(cat "$trap_live" 2>/dev/null)"
  fired=$(grep -c SURVIVED "$home/user-home/trap.fired" 2>/dev/null || true)
  [ "$fired" = 1 ] \
    || fail "capped allowlist $signal on $pane_shell EXIT trap fired ${fired:-0} time(s), not once: $(cat "$home/user-home/trap.fired" 2>/dev/null)"
}

test_capped_allowlist_signal_keeps_pane_trap() {
  local pane_shell
  command -v zsh >/dev/null 2>&1 \
    || fail "zsh is required to prove an allowlisted signal keeps the pane EXIT trap"
  command -v dash >/dev/null 2>&1 \
    || fail "dash is required to prove an allowlisted signal keeps the pane EXIT trap"
  for pane_shell in bash zsh dash; do
    capped_allowlist_signal_keeps_trap_with "$pane_shell" KILL 137
    capped_allowlist_signal_keeps_trap_with "$pane_shell" TERM 143
  done
  pass "an allowlisted kill -KILL/\$\$ or kill -TERM/\$\$ keeps the pane EXIT trap on bash, zsh, and dash"
}

test_waiting_workers_require_proven_idle
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
test_recent_spawn_generation_skips_endpoint_probe
test_live_workers_total_budget_counts_unread_records
test_capped_raw_exit_127_rolls_back
test_capped_raw_exit_127_rolls_back_in_fish
test_capped_claude_doorbell_quotes_in_fish
test_capped_raw_quote_backslash_roundtrip
test_capped_raw_source_and_cmd_on_bash
test_capped_bad_git_config_fails_fast
test_spend_cap_forwards_truncation_note
test_capped_kill_pane_rolls_back
test_capped_posix_exit_trap_survives
test_capped_herdr_empty_process_info_uses_shell
test_capped_dash_missing_traps_still_disarms
test_capped_raw_return_restores_trap
test_capped_allowlist_signal_keeps_pane_trap
