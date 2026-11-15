#!/usr/bin/env bash
# tests/fm-watchdog-worker.test.sh - the watchdog must bring a killed worker
# back inside one pass with no firstmate turn, rebuild the fleet after a reboot
# without waiting on the chair, walk a stalled worker ring -> relaunch ->
# reassign -> escalate once, and restart failed fleet units without ever
# restarting itself.
#
# The two definitions of done it pins come from
# data/factory-autonomy-fable-a1/bob-architecture.md section 8 step 7: a killed
# worker is back inside 5 minutes with no firstmate turn, and a reboot needs
# zero hand relaunches.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-watchdog-worker.sh"
TMP_ROOT=$(fm_test_tmproot fm-watchdog-worker)

# assert_eq <expected> <actual> <msg>
assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

# age_file <path> <seconds>: back-date (-) or post-date a file against the real
# clock. The watchdog's freeze clock runs on a frozen FM_WATCHDOG_NOW near real
# time, so a back-dated status log reads as quiet and a post-dated one reads as
# "written after the last rung".
age_file() {  # <path> <seconds>
  python3 - "$1" "$2" <<'PY'
import os, sys, time
when = time.time() - int(sys.argv[2])
os.utime(sys.argv[1], (when, when))
PY
}

# make_home <name>: a private FM home for one test.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/fakebin" "$home/fix" "$home/crew" "$home/units"
  printf '%s\n' "$home"
}

# fake_tools <home>: every external command the watchdog can reach, recorded in
# <home>/calls so a test can assert both what ran and in what order.
fake_tools() {  # <home>
  local home=$1
  # Every test starts from the working control stand-in; a test that needs a
  # refusing backend names its own afterwards.
  CONTROL_OVERRIDE=''
  cat > "$home/fakebin/fake-control" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$home/calls"
printf 'relaunched %s harness=pi backend=tmux endpoint=firstmate:%s worktree=w\n' "\$1" "\$1"
SH
  cat > "$home/fakebin/fake-send" <<SH
#!/usr/bin/env bash
printf 'send %s\n' "\$1" >> "$home/calls"
if [ -f "$home/units/send-fails" ]; then
  printf 'error: fire-and-forget delivery unconfirmed\n' >&2
  exit 3
fi
printf '%s\n' "\$*" >> "$home/steers"
SH
  # A relaunch transaction the backend refuses structurally, exactly as
  # bin/fm-control.sh refuses an Orca in-place relaunch.
  cat > "$home/fakebin/fake-control-refuses" <<SH
#!/usr/bin/env bash
printf 'control %s\n' "\$*" >> "$home/calls"
if [ -f "$home/units/control-transient" ]; then
  exit 124
fi
if [ -f "$home/units/control-lock-contended" ]; then
  printf 'error: another lifecycle action is already running for task %s\n' "\$1" >&2
  exit 1
fi
if [ -f "$home/units/control-kind-refusal" ]; then
  printf "error: task %s records kind 'fix', which has no defined relaunch shape\n" "\$1" >&2
  exit 1
fi
printf 'error: task %s runs on the orca backend, whose in-place relaunch is not proven end to end; exit the agent with'\''exit'\'' and respawn the task instead\n' "\$1" >&2
exit 1
SH
  # bin/fm-spawn.sh --relaunch stand-in: the Orca replacement path.
  cat > "$home/fakebin/fake-spawn" <<SH
#!/usr/bin/env bash
printf 'spawn %s\n' "\$*" >> "$home/calls"
if [ -f "$home/units/spawn-transient" ]; then
  printf 'error: backend=orca selected but orca status --json failed; start Orca and wait for the runtime\n' >&2
  exit 1
fi
if [ -f "$home/units/spawn-refuses" ]; then
  printf 'error: task %s recorded worktree is missing; refusing to relaunch\n' "\$1" >&2
  exit 2
fi
printf 'relaunched true task=%s\n' "\$1"
SH
  cat > "$home/fakebin/fake-lane-switch" <<SH
#!/usr/bin/env bash
printf 'model-switch %s\n' "\$*" >> "$home/calls"
if [ -f "$home/units/lane-switch-refuses" ]; then
  printf 'refused: this lane owns scheduled ticks\n'
  exit 2
fi
exit 0
SH
  cat > "$home/fakebin/fake-crew-state" <<SH
#!/usr/bin/env bash
if [ -f "$home/crew/\$1" ]; then cat "$home/crew/\$1"; else printf 'state: unknown · source: none · no record\n'; fi
SH
  cat > "$home/fakebin/systemctl" <<SH
#!/usr/bin/env bash
printf 'systemctl %s\n' "\$*" >> "$home/calls"
case "\$*" in
  *list-units*)
    for u in \$(cat "$home/units/failed" 2>/dev/null); do printf '%s loaded failed failed  fleet unit\n' "\$u"; done
    ;;
  *--user\ restart*)
    case "\$*" in
      *fm-chair.service*) [ -f "$home/units/chair-broken" ] && exit 1 ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$home/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf 'tmux %s\n' "\$*" >> "$home/calls"
exit 1
SH
  chmod +x "$home/fakebin"/*
}

# worker <home> <id> <state> [kind] [harness] [backend]: one recorded task and
# its endpoint state.
worker() {  # <home> <id> <state> [kind] [harness] [backend]
  local home=$1 id=$2 state=$3 kind=${4:-ship} harness=${5:-pi} backend=${6-}
  local -a backend_fields=()
  if [ -n "$backend" ]; then
    backend_fields=("backend=$backend" "terminal=term-$id" "orca_worktree_id=wt-$id")
  fi
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:$id" "endpoint_task_id=$id" "worktree=$home/wt-$id" \
    "project=p" "harness=$harness" "kind=$kind" "mode=no-mistakes" "yolo=off" \
    ${backend_fields[@]+"${backend_fields[@]}"}
  printf '%s\n' "$state" > "$home/fix/$id.state"
}

# pane <home> <id> <busy> <text>: the pane the watchdog would capture.
pane() {  # <home> <id> <busy> <text>
  printf '%s\n' "$4" > "$1/fix/$2.cap"
  printf '%s\n' "$3" > "$1/fix/$2.busy"
}

# tick <home> <now> [key=value ...]: one watchdog pass on the frozen clock. No
# boot identity by default, so only the tests that are about a reboot run the
# boot pass. WD_ARGS carries script arguments (--dry-run) for the one test that
# needs them, because `env` assignments and script arguments cannot share a
# position.
tick() {  # <home> <now> [env...]
  local home=$1 now=$2
  shift 2
  local -a script_args=()
  [ -z "${WD_ARGS:-}" ] || script_args=("$WD_ARGS")
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_WATCHDOG_NOW="$now" \
    FM_WATCHDOG_BOOT_ID="${BOOT:-off}" \
    FM_WATCHDOG_CONTROL_BIN="${CONTROL_OVERRIDE:-$home/fakebin/fake-control}" \
    FM_WATCHDOG_SPAWN_BIN="$home/fakebin/fake-spawn" \
    FM_WATCHDOG_SEND_BIN="$home/fakebin/fake-send" \
    FM_WATCHDOG_CREW_STATE_BIN="$home/fakebin/fake-crew-state" \
    FM_WATCHDOG_SYSTEMCTL_BIN="$home/fakebin/systemctl" \
    FM_WATCHDOG_LANE_SWITCH_BIN="$home/fakebin/fake-lane-switch" \
    FM_WATCHDOG_AGENT_STATE_DIR="$home/fix" \
    FM_WATCHDOG_CAPTURE_DIR="$home/fix" \
    FM_WATCHDOG_CHAIR_TARGET=firstmate:chair \
    FM_WATCHDOG_BACKLOG="${BACKLOG:-off}" \
    "$@" "$CHECK" ${script_args[@]+"${script_args[@]}"} 2>&1
}

# wakes <home>: the durable check wakes the watchdog queued.
wakes() {  # <home>
  awk -F'\t' '$3 == "check" { print $4 " " $5 }' "$1/state/.wake-queue" 2>/dev/null
}

# assert_delivery_ids <home>: every fire-and-forget the watchdog sent carried
# the 16-lowercase-hex id bin/fm-send.sh requires, so the rung actually landed.
assert_delivery_ids() {  # <home>
  local id
  while read -r id; do
    [ -n "$id" ] || continue
    [[ "$id" =~ ^[0-9a-f]{16}$ ]] \
      || fail "watchdog sent an invalid fire-and-forget id '$id': $(cat "$1/steers")"
  done < <(awk '/--fire-and-forget/ {
      for (i = 1; i <= NF; i++) if ($i == "--fire-and-forget") print $(i + 1)
    }' "$1/steers" 2>/dev/null)
}

# counter <home> <pattern>: how many recorded lines match.
counter() {  # <home> <pattern>
  local n
  n=$(grep -c "$2" "$1/calls" 2>/dev/null)
  printf '%s\n' "${n:-0}"
}

# steer <home> <id> <seconds-ago>: one durable, unacknowledged steering record
# in the shape bin/fm-task-inbox-lib.sh writes.
steer() {  # <home> <id> <seconds-ago>
  local dir="$1/state/$2.inbox"
  mkdir -p "$dir/handled"
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\nship it\n' > "$dir/001.msg"
  age_file "$dir/001.msg" "$3"
}

# backlog_bin <home> <id...>: a stand-in for tasks-axi that reports exactly the
# given ids as in flight, in its own list shape.
backlog_bin() {  # <home> <id...>
  local home=$1
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "count: 2\\ntasks[2]{id,state,kind,repo,title}:\\n"\n'
    local id
    for id in "$@"; do
      printf 'printf "  %s,in_flight,ship,p,t\\n"\n' "$id"
    done
  } > "$home/fakebin/tasks-axi"
  chmod +x "$home/fakebin/tasks-axi"
}

held_backlog_bin() {  # <home> <id...>: a tasks-axi stand-in that reports held ids.
  local home=$1
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "count: 2\\ntasks[2]{id,state,kind,repo,title}:\\n"\n'
    local id
    for id in "$@"; do
      printf 'printf "  %s,held,ship,p,t\\n"\n' "$id"
    done
  } > "$home/fakebin/tasks-axi"
  chmod +x "$home/fakebin/tasks-axi"
}

start_clock() { date +%s; }

test_a_structural_refusal_outside_the_old_phrase_list_spends_no_budget() {
  local home now out
  home=$(make_home kind-refusal); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-kind-refusal"
  worker "$home" w1 dead
  now=$(start_clock)
  out=$(tick "$home" "$now")
  assert_contains "$out" "has no defined relaunch shape" \
    "a structural refusal was not reported with the backend's own reason"
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "1" \
    "a structural refusal phrased outside the old list was not escalated"
  assert_eq "$(counter "$home" '^control .* relaunch')" "1" \
    "a structural refusal phrased outside the old list was retried"
  pass "a structural refusal is classified by the control command's own error contract"
}

test_a_boot_transient_failure_keeps_the_lane_relaunch_history() {
  local home now
  home=$(make_home boot-transient); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-transient"
  worker "$home" w1 dead
  now=$(start_clock)
  jq -n --argjson now "$now" \
    '{schema: 1, boot_identity: "boot-old", units: {}, backlog: {},
      tasks: { w1: { sig: "abc", since: $now, stage: 2, stage_at: $now,
        rings: [$now, $now], relaunches: [$now, $now], steers: [$now], woke: false,
        istage: 1, istage_at: $now, ibase: "001.msg", strikes: [$now],
        refusal: "", refusal_at: 0 } }}' \
    > "$home/state/.watchdog-worker.json"
  BOOT=boot-new tick "$home" "$now" >/dev/null
  assert_eq "$(jq -r '.tasks.w1.relaunches | length' "$home/state/.watchdog-worker.json")" "2" \
    "a transient boot relaunch failure reset the lane's relaunch budget"
  assert_eq "$(jq -r '.tasks.w1.strikes | length' "$home/state/.watchdog-worker.json")" "1" \
    "a transient boot relaunch failure reset the lane's strike history"
  pass "a transient boot relaunch failure preserves the lane's persisted counters"
}

test_a_boot_refusal_keeps_the_lane_relaunch_history() {
  local home now relaunches
  home=$(make_home boot-refusal); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  worker "$home" w1 dead
  now=$(start_clock)
  jq -n --argjson now "$now" \
    '{schema: 1, boot_identity: "boot-old", units: {}, backlog: {},
      tasks: { w1: { sig: "abc", since: $now, stage: 2, stage_at: $now,
        rings: [$now, $now], relaunches: [$now, $now], steers: [$now], woke: false,
        istage: 1, istage_at: $now, ibase: "001.msg", strikes: [$now],
        refusal: "", refusal_at: 0 } }}' \
    > "$home/state/.watchdog-worker.json"
  BOOT=boot-new tick "$home" "$now" >/dev/null
  relaunches=$(jq -r '.tasks.w1.relaunches | length' "$home/state/.watchdog-worker.json")
  assert_eq "$relaunches" "2" \
    "a boot-pass refusal reset the lane's persisted relaunch budget"
  assert_eq "$(jq -r '.tasks.w1.strikes | length' "$home/state/.watchdog-worker.json")" "1" \
    "a boot-pass refusal reset the lane's persisted strike history"
  assert_eq "$(jq -r '.tasks.w1.refusal' "$home/state/.watchdog-worker.json")" \
    "error: task w1 runs on the orca backend, whose in-place relaunch is not proven end to end; exit the agent with'exit' and respawn the task instead" \
    "the boot-pass refusal was not recorded"
  pass "a boot-pass refusal preserves the lane's persisted counters"
}

test_an_orca_replacement_names_a_note_it_could_not_deliver() {
  local home now out
  home=$(make_home orca-note-fails); fake_tools "$home"
  : > "$home/units/send-fails"
  worker "$home" w1 missing ship pi orca
  now=$(start_clock)
  out=$(tick "$home" "$now")
  assert_contains "$out" "could not deliver w1 its carry-over note" \
    "a replacement started without its carry-over note was reported relaunched silently"
  grep -q 'could not deliver its carry-over note' <<< "$(wakes "$home")" \
    || fail "a lost carry-over note never reached firstmate: $(wakes "$home")"
  pass "an Orca replacement whose carry-over note cannot be delivered is escalated"
}

test_a_spawn_preflight_refusal_spends_no_budget_and_retries_once() {
  local home now
  home=$(make_home orca-spawn-refuses); fake_tools "$home"
  : > "$home/units/spawn-refuses"
  worker "$home" w1 missing ship pi orca
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 600))" >/dev/null
  assert_eq "$(counter "$home" '^spawn w1 --relaunch')" "1" \
    "a structural spawn refusal was retried before its window closed"
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "1" \
    "a structural spawn refusal did not escalate exactly once"
  assert_eq "$(wakes "$home" | grep -c 'hourly relaunch budget')" "0" \
    "a structural spawn refusal spent the lane's relaunch budget"
  pass "a structural spawn refusal is not retried inside its window"
}

test_a_transient_spawn_failure_is_not_a_refusal() {
  local home now
  home=$(make_home orca-spawn-transient); fake_tools "$home"
  : > "$home/units/spawn-transient"
  worker "$home" w1 missing ship pi orca
  now=$(start_clock)
  jq -n --argjson now "$now" \
    '{schema: 1, boot_identity: "", units: {}, backlog: {},
      tasks: { w1: { sig: "abc", since: $now, stage: 0, stage_at: 0,
        rings: [], relaunches: [], steers: [], woke: false,
        istage: 0, istage_at: 0, ibase: "", strikes: [$now],
        refusal: "", refusal_at: 0 } }}' \
    > "$home/state/.watchdog-worker.json"
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 600))" >/dev/null
  assert_eq "$(counter "$home" '^spawn w1 --relaunch')" "2" \
    "a transient spawn failure was treated as a structural refusal"
  assert_eq "$(jq -r '.tasks.w1.strikes | length' "$home/state/.watchdog-worker.json")" "1" \
    "a transient spawn failure was recorded as a completed relaunch"
  if wakes "$home" | grep -q 'cannot relaunch w1'; then
    fail "a transient spawn failure escalated as a refusal: $(wakes "$home")"
  fi
  pass "a transient spawn failure is retried on the ordinary budget"
}

test_lifecycle_lock_contention_is_retried_not_recorded() {
  local home now
  home=$(make_home lock-contended); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-lock-contended"
  worker "$home" w1 dead
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 600))" >/dev/null
  assert_eq "$(counter "$home" '^control w1 relaunch')" "2" \
    "a lifecycle lock hold was not retried on the next pass"
  if wakes "$home" | grep -q 'cannot relaunch w1'; then
    fail "a lifecycle lock hold was recorded as a permanent refusal: $(wakes "$home")"
  fi
  pass "lifecycle lock contention stays retryable instead of becoming a 6h refusal"
}

test_a_task_left_stopped_is_never_relaunched_or_paged() {
  local home now out
  home=$(make_home left-stopped); fake_tools "$home"
  worker "$home" w1 dead
  worker "$home" w2 dead
  # The captain's own order, written by bin/fm-leave-stopped.sh.
  printf 'schema=fm-leave-stopped.v1\nat=2026-11-15T00:37:55Z\nreason=left stopped\n' \
    > "$home/state/w1.stopped"
  now=$(start_clock)
  out=$(tick "$home" "$now")
  assert_eq "$(counter "$home" '^control w1 .* relaunch')" "0" \
    "a task the captain left stopped was relaunched"
  assert_eq "$(counter "$home" '^control w2 .* relaunch')" "1" \
    "an ordinary dead task stopped being relaunched alongside a stopped one"
  [ -z "$(wakes "$home")" ] || fail "a stopped task woke firstmate: $(wakes "$home")"
  out=$(tick "$home" "$((now + 300))" FM_WATCHDOG_BOOT_ID=boot-a)
  assert_contains "$out" "relaunched 1 of 1 task(s)" "the boot pass counted a task the captain left stopped"
  assert_eq "$(counter "$home" '^control w1 .* relaunch')" "0" \
    "the boot pass relaunched a task the captain left stopped"
  assert_eq "$(wakes "$home" | grep -c 'w1 endpoint')" "0" \
    "a stopped task was paged about its endpoint"
  pass "a task the captain left stopped is skipped by every pass, exactly like a held one"
}

test_a_dead_worker_comes_back_in_one_pass_with_no_wake() {
  local home now out
  home=$(make_home dead); fake_tools "$home"
  worker "$home" w1 dead
  now=$(start_clock)
  out=$(tick "$home" "$now")
  assert_contains "$out" "watchdog: relaunched w1 after endpoint dead" "a dead endpoint was not relaunched"
  assert_eq "$(counter "$home" '^control .* relaunch')" "1" "the dead worker was relaunched more or less than once"
  [ -z "$(wakes "$home")" ] || fail "a plain dead-endpoint relaunch woke firstmate: $(wakes "$home")"
  pass "a killed worker is relaunched inside one pass with no firstmate turn and no wake"
}

test_a_reboot_rebuilds_the_fleet_and_starts_the_chair_last() {
  local home now out chair_line relaunch_line
  home=$(make_home boot); fake_tools "$home"
  worker "$home" w1 dead
  worker "$home" w2 missing
  worker "$home" w3 alive
  pane "$home" w3 idle 'finished, waiting for a merge'
  printf 'dead\n' > "$home/fix/chair.state"
  now=$(start_clock)
  out=$(tick "$home" "$now" FM_WATCHDOG_BOOT_ID=boot-a)
  assert_contains "$out" "watchdog: boot recovery: relaunched 2 of 3 task(s), chair started" \
    "the boot pass did not relaunch exactly the two dead endpoints and start the chair"
  assert_eq "$(counter "$home" '^control .* relaunch')" "2" "a boot relaunched the wrong number of tasks"
  chair_line=$(grep -n 'systemctl --user restart fm-chair.service' "$home/calls" | head -1 | cut -d: -f1)
  relaunch_line=$(grep -n '^control .* relaunch' "$home/calls" | tail -1 | cut -d: -f1)
  [ -n "$chair_line" ] || fail "the boot pass never started the chair"
  [ "$relaunch_line" -lt "$chair_line" ] \
    || fail "the chair was started before the fleet was relaunched (relaunch $relaunch_line, chair $chair_line)"
  assert_contains "$(wakes "$home")" "watchdog boot recovery: relaunched 2 of 3 task(s), chair started" \
    "the boot pass did not queue its one boot wake"
  pass "a reboot relaunches the dead fleet, then starts the chair last, and says so in one wake"
}

test_the_same_boot_is_not_a_boot_twice() {
  local home now out
  home=$(make_home boot-once); fake_tools "$home"
  worker "$home" w1 dead
  printf 'dead\n' > "$home/fix/chair.state"
  now=$(start_clock)
  tick "$home" "$now" FM_WATCHDOG_BOOT_ID=boot-a >/dev/null
  assert_eq "$(counter "$home" 'fm-chair.service')" "1" "the first pass on a fresh boot did not start the chair"
  rm -f "$home/calls"
  printf 'alive\n' > "$home/fix/w1.state"
  printf 'alive\n' > "$home/fix/chair.state"
  out=$(tick "$home" "$((now + 300))" FM_WATCHDOG_BOOT_ID=boot-a)
  assert_not_contains "$out" "boot recovery" "a second pass on the same boot ran the boot pass again"
  assert_eq "$(counter "$home" 'fm-chair.service')" "0" "a second pass on the same boot started the chair again"
  pass "the boot pass runs once per boot identity, not once per pass"
}

test_a_new_boot_identity_runs_the_boot_pass_again() {
  local home now out
  home=$(make_home boot-again); fake_tools "$home"
  worker "$home" w1 alive
  pane "$home" w1 idle 'finished'
  now=$(start_clock)
  tick "$home" "$now" FM_WATCHDOG_BOOT_ID=boot-a >/dev/null
  printf 'dead\n' > "$home/fix/w1.state"
  out=$(tick "$home" "$((now + 300))" FM_WATCHDOG_BOOT_ID=boot-b)
  assert_contains "$out" "boot recovery: relaunched 1 of 1 task(s)" "a new boot identity did not run the boot pass"
  pass "a new boot identity runs the boot pass again, so a second reboot is recovered too"
}

test_a_transient_stall_relaunch_failure_does_not_climb_the_ladder() {
  local home now out
  home=$(make_home ladder-transient); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-transient"
  worker "$home" w1 alive
  pane "$home" w1 busy 'a tool call that never returns'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 1900))" >/dev/null
  out=$(tick "$home" "$((now + 2600))")
  assert_contains "$out" "relaunch failed w1" \
    "a transient relaunch failure was not reported as a failure"
  assert_not_contains "$out" "relaunched w1" \
    "a transient relaunch failure was announced as a relaunch"
  out=$(tick "$home" "$((now + 2700))")
  assert_eq "$(counter "$home" '^control w1 relaunch')" "2" \
    "a transient relaunch failure did not retry on the next pass"
  assert_eq "$(jq -r '.tasks.w1.stage' "$home/state/.watchdog-worker.json")" "1" \
    "a transient relaunch failure advanced the stall ladder"
  out=$(tick "$home" "$((now + 4000))")
  assert_not_contains "$out" "still stalled after every rung" \
    "the ladder escalated after relaunches that never happened"
  pass "a transient stall relaunch failure leaves the ladder where it was"
}

test_a_transient_inbox_relaunch_failure_is_not_announced_as_done() {
  local home now out
  home=$(make_home inbox-transient); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-transient"
  worker "$home" w1 alive
  pane "$home" w1 idle 'waiting'
  steer "$home" w1 2800
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  steer "$home" w1 5500
  out=$(tick "$home" "$now")
  assert_contains "$out" "relaunch failed w1" \
    "a transient inbox relaunch failure was not reported as a failure"
  out=$(tick "$home" "$now")
  assert_eq "$(counter "$home" '^control w1 relaunch')" "2" \
    "a transient inbox relaunch failure was not retried"
  assert_eq "$(wakes "$home" | grep -c 'steering inbox went unread')" "0" \
    "a transient inbox relaunch failure was announced as a relaunch"
  assert_eq "$(jq -r '.tasks.w1.istage' "$home/state/.watchdog-worker.json")" "2" \
    "a transient inbox relaunch failure consumed the last rung"
  pass "a transient inbox relaunch failure neither announces nor consumes the rung"
}

test_a_spent_inbox_relaunch_budget_stops_retrying_and_escalates_once() {
  local home now
  home=$(make_home inbox-budget); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-transient"
  worker "$home" w1 alive
  pane "$home" w1 idle 'waiting'
  steer "$home" w1 5500
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$now" >/dev/null
  tick "$home" "$now" >/dev/null
  assert_eq "3" "$(jq -r '.tasks.w1.relaunches | length' "$home/state/.watchdog-worker.json")" \
    "a failed inbox relaunch attempt was not charged against the hourly budget"
  tick "$home" "$now" >/dev/null
  tick "$home" "$now" >/dev/null
  assert_eq "3" "$(counter "$home" '^control w1 relaunch')" \
    "a spent relaunch budget still retried the unread inbox's relaunch"
  assert_eq "1" "$(wakes "$home" | grep -c 'hourly relaunch budget')" \
    "an unread inbox whose relaunches all failed never reached firstmate"
  assert_eq "0" "$(jq -r '.tasks.w1.istage' "$home/state/.watchdog-worker.json")" \
    "a failed inbox relaunch claimed the rung"
  pass "an unread inbox retries its failed relaunch on the budget, then escalates once"
}

test_a_stalled_worker_climbs_the_ladder_and_escalates_once() {
  local home now out
  home=$(make_home ladder); fake_tools "$home"
  worker "$home" w1 alive
  pane "$home" w1 busy 'a tool call that never returns'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  out=$(tick "$home" "$((now + 600))")
  [ -z "$out" ] || fail "ten minutes of a frozen pane already acted at the 30-minute default: $out"
  out=$(tick "$home" "$((now + 1900))")
  assert_contains "$out" "watchdog: re-rang w1" "a pane frozen for 31 minutes was not re-rung"
  assert_contains "$(cat "$home/steers")" "Continue the task from where you left off" \
    "the re-ring did not carry the bounded continue"
  assert_contains "$(cat "$home/steers")" "--fire-and-forget" \
    "the re-ring was not fire-and-forget, so the steering ladder would escalate it back to firstmate"
  assert_delivery_ids "$home"
  out=$(tick "$home" "$((now + 2000))")
  [ -z "$out" ] || fail "the ladder climbed before the rung had its grace: $out"
  out=$(tick "$home" "$((now + 2600))")
  assert_contains "$out" "watchdog: relaunched w1 after no pane progress for 43 minutes" \
    "the ladder did not relaunch on the second rung"
  out=$(tick "$home" "$((now + 3300))")
  assert_contains "$out" "reassigning" "the ladder did not reach the reassign rung"
  out=$(tick "$home" "$((now + 4000))")
  assert_contains "$out" "watchdog: w1 still stalled after every rung; asking firstmate" \
    "the ladder did not escalate after every rung"
  out=$(tick "$home" "$((now + 4700))")
  [ -z "$out" ] || fail "the ladder escalated twice for one stall: $out"
  assert_eq "$(wakes "$home" | grep -c 'still stalled')" "1" "one stall produced more than one escalation"
  pass "a stalled worker is re-rung, relaunched, reassigned, then escalated exactly once"
}

test_progress_and_status_lines_reset_the_ladder() {
  local home now out
  home=$(make_home reset); fake_tools "$home"
  worker "$home" w1 alive
  pane "$home" w1 busy 'first shape'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 1900))" >/dev/null
  assert_eq "$(counter "$home" '^send ')" "1" "the first freeze was not re-rung"
  pane "$home" w1 busy 'a brand new line of output'
  out=$(tick "$home" "$((now + 2000))")
  [ -z "$out" ] || fail "a worker producing new output was acted on: $out"
  # A status line written after the rung restarts the ladder. The frozen clock
  # cannot advance, so the fixture stands in for "written after the rung" with a
  # post-dated mtime.
  pane "$home" w1 busy 'first shape again'
  printf 'working: back after a long step\n' > "$home/state/w1.status"
  age_file "$home/state/w1.status" -3000
  out=$(tick "$home" "$((now + 3900))")
  [ -z "$out" ] || fail "a status line after the rung did not reset the episode: $out"
  out=$(tick "$home" "$((now + 5900))")
  assert_contains "$out" "watchdog: re-rang w1" "a reset ladder did not start again at the first rung"
  assert_not_contains "$out" "relaunched" "a worker that spoke on its status log was relaunched anyway"
  pass "new pane output and a new status line both restart the stall ladder"
}

test_the_relaunch_cap_escalates_once_instead_of_looping() {
  local home now out i capped=''
  home=$(make_home cap); fake_tools "$home"
  worker "$home" w1 dead
  now=$(start_clock)
  for i in 0 1 2 3 4 5; do
    out=$(tick "$home" "$((now + i * 60))")
    [ "$i" = 3 ] && capped=$out
  done
  assert_eq "$(counter "$home" '^control .* relaunch')" "3" "a crash loop was relaunched more or less than the hourly cap"
  assert_eq "$(wakes "$home" | grep -c 'hourly relaunch budget')" "1" \
    "spending the relaunch cap did not escalate exactly once"
  assert_contains "$capped" "watchdog: w1 endpoint dead and out of relaunches; asking firstmate" \
    "the capped worker did not report its escalation"
  pass "a crash-looping worker is relaunched at most three times an hour and escalated once"
}

test_an_idle_worker_is_nudged_once_and_run_steps_are_left_alone() {
  local home now out
  home=$(make_home idle); fake_tools "$home"
  worker "$home" w1 alive
  pane "$home" w1 idle 'waiting at the prompt'
  worker "$home" w2 alive
  pane "$home" w2 idle 'waiting at the prompt'
  worker "$home" w3 alive
  pane "$home" w3 idle 'waiting at the prompt'
  printf 'state: working · source: own-status · last event working\n' > "$home/crew/w1"
  printf 'state: working · source: run-step · validating\n' > "$home/crew/w2"
  printf 'state: done · source: own-status · finished\n' > "$home/crew/w3"
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  out=$(tick "$home" "$((now + 600))")
  [ -z "$out" ] || fail "ten idle minutes already acted at the 30-minute default: $out"
  out=$(tick "$home" "$((now + 1900))")
  assert_contains "$out" "watchdog: nudged idle w1" "an idle worker that still reads working was not nudged"
  assert_delivery_ids "$home"
  assert_not_contains "$out" "w2" "a pipeline run-step was nudged as an idle agent"
  assert_not_contains "$out" "w3" "a finished worker was nudged"
  out=$(tick "$home" "$((now + 2000))")
  [ -z "$out" ] || fail "the idle nudge repeated before its grace elapsed: $out"
  out=$(tick "$home" "$((now + 3800))")
  assert_contains "$out" "watchdog: w1 idle for" "an idle worker that ignored its nudge was not escalated"
  assert_eq "$(wakes "$home" | grep -c 'idle with no status event')" "1" \
    "one idle episode produced more than one escalation"
  pass "an idle working worker gets one nudge an hour, then escalates; run-steps and finished work are left alone"
}

test_failed_units_restart_but_never_the_watchdog_itself() {
  local home now out
  home=$(make_home units); fake_tools "$home"
  printf 'fm-lane-tick-a.service\nfm-watchdog-worker.service\nfm-watchdog-worker.timer\n' > "$home/units/failed"
  now=$(start_clock)
  out=$(tick "$home" "$now")
  assert_contains "$out" "watchdog: restarted failed unit fm-lane-tick-a.service" "a failed fleet unit was not restarted"
  assert_not_contains "$out" "restarted failed unit fm-watchdog-worker.service" "the watchdog restarted itself"
  assert_not_contains "$out" "restarted failed unit fm-watchdog-worker.timer" "the watchdog restarted its own timer"
  assert_eq "$(counter "$home" 'start fm-watchdog-worker')" "0" "the deny list did not stop a self-restart"
  assert_eq "$(counter "$home" 'start fm-lane-tick-a.service')" "1" "a failed unit was restarted more than once in a pass"
  pass "failed fleet units are restarted, and the watchdog never restarts itself"
}

test_a_unit_that_keeps_failing_escalates_once() {
  local home now out i capped=''
  home=$(make_home unit-cap); fake_tools "$home"
  printf 'fm-lane-tick-a.service\n' > "$home/units/failed"
  now=$(start_clock)
  for i in 0 1 2 3 4; do
    out=$(tick "$home" "$((now + i * 60))")
    [ "$i" = 3 ] && capped=$out
  done
  assert_eq "$(counter "$home" 'start fm-lane-tick-a.service')" "3" \
    "a failing unit was restarted more or less than the hourly cap"
  assert_contains "$capped" "spent its hourly restart budget" "a spent unit budget did not report itself"
  assert_eq "$(wakes "$home" | grep -c 'fm-lane-tick-a.service')" "1" \
    "a spent unit budget escalated more than once"
  pass "a unit that keeps failing stops at the hourly cap and escalates once"
}

test_an_unclassifiable_endpoint_is_never_relaunched() {
  local home now out
  home=$(make_home ambiguous); fake_tools "$home"
  worker "$home" w1 ambiguous
  worker "$home" w2 unreadable
  now=$(start_clock)
  out=$(tick "$home" "$now")
  [ -z "$out" ] || fail "an endpoint the classifier could not read was acted on: $out"
  assert_eq "$(counter "$home" '^control .* relaunch')" "0" "an ambiguous endpoint was relaunched"
  pass "ambiguous and unreadable endpoints record their shape and are never relaunched"
}

test_secondmates_are_not_the_watchdogs_to_relaunch() {
  local home now out
  home=$(make_home secondmate); fake_tools "$home"
  worker "$home" sm1 dead secondmate
  now=$(start_clock)
  out=$(tick "$home" "$now")
  [ -z "$out" ] || fail "the watchdog acted on a secondmate: $out"
  assert_eq "$(counter "$home" '^control .* relaunch')" "0" "a secondmate was relaunched by the watchdog"
  pass "secondmates stay with their own home"
}

test_a_chair_that_will_not_start_reports_itself() {
  local home now out
  home=$(make_home chair-broken); fake_tools "$home"
  printf 'dead\n' > "$home/fix/chair.state"
  : > "$home/units/chair-broken"
  now=$(start_clock)
  out=$(tick "$home" "$now" FM_WATCHDOG_BOOT_ID=boot-a)
  assert_contains "$out" "chair could not be started" "a chair that refused to start was reported as started"
  pass "a chair unit that will not start is reported instead of silently assumed"
}

test_status_prints_the_record_and_a_foreign_schema_is_ignored() {
  local home now out
  home=$(make_home status); fake_tools "$home"
  worker "$home" w1 dead
  now=$(start_clock)
  out=$(env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "no record yet" "status invented a record before the first pass"
  tick "$home" "$now" >/dev/null
  out=$(env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" status)
  assert_contains "$out" "watchdog record schema 1 boot" "status did not print the record header"
  assert_contains "$out" "w1: stage=0" "status did not print the task history"
  printf '{"schema":99,"tasks":{"w9":{"stage":7}}}\n' > "$home/state/.watchdog-worker.json"
  rm -f "$home/calls"
  worker "$home" w2 dead
  out=$(tick "$home" "$((now + 60))")
  assert_contains "$out" "relaunched w2" "a record from a future schema changed what the pass did"
  assert_not_contains "$(cat "$home/state/.watchdog-worker.json")" '"w9"' \
    "a foreign-schema record's task history survived into the new record"
  pass "status prints the record, and a foreign schema is treated as no record at all"
}

test_a_concurrent_pass_is_skipped_not_doubled() {
  local home now out
  home=$(make_home lock); fake_tools "$home"
  worker "$home" w1 dead
  now=$(start_clock)
  mkdir -p "$home/state/.watchdog-worker.lock"
  printf '%s\n' "$$" > "$home/state/.watchdog-worker.lock/pid"
  out=$(tick "$home" "$now")
  assert_contains "$out" "another pass is running; skipping this one" "a held lock did not skip the pass"
  assert_eq "$(counter "$home" '^control .* relaunch')" "0" "a pass that could not take the lock still acted"
  pass "a concurrent pass is skipped rather than doubling every relaunch"
}

test_an_unread_steer_is_interrupted_then_relaunched_once_each() {
  local home now out
  home=$(make_home inbox); fake_tools "$home"
  worker "$home" w1 alive
  pane "$home" w1 idle 'waiting'
  steer "$home" w1 2800
  now=$(start_clock)
  out=$(tick "$home" "$now")
  assert_contains "$out" "watchdog: interrupted w1" \
    "a steer unread for 45 minutes did not interrupt the lane"
  assert_eq "$(counter "$home" 'interrupt')" "1" "the interrupt rung did not fire exactly once"
  assert_contains "$(cat "$home/steers" 2>/dev/null)" 'waiting unread' \
    "the continue did not tell the worker why it was interrupted"
  assert_delivery_ids "$home"
  assert_eq "$(counter "$home" '^control .* relaunch')" "0" "the interrupt rung relaunched the lane"

  out=$(tick "$home" "$now")
  assert_eq "$(counter "$home" 'interrupt')" "1" "the interrupt rung fired twice for one message"

  steer "$home" w1 5500
  out=$(tick "$home" "$now")
  assert_contains "$out" "watchdog: relaunched w1 after steering inbox unread" \
    "a steer unread for 90 minutes did not relaunch the lane"
  assert_eq "$(wakes "$home" | grep -c 'steering inbox went unread')" "1" \
    "the last inbox rung did not report itself exactly once"
  out=$(tick "$home" "$now")
  assert_eq "$(counter "$home" '^control .* relaunch')" "1" "the relaunch rung fired twice for one message"
  pass "an unread steer is re-rung, interrupted, then relaunched once per message"
}

test_a_connection_error_lane_is_continued_then_relaunched_on_the_fallback_model() {
  local home now out
  home=$(make_home conn); fake_tools "$home"
  # A Claude Code lane is the ONLY harness where the fallback-model repoint is
  # reachable, so this fixture is what makes the model assertion meaningful.
  worker "$home" w1 alive ship claude
  pane "$home" w1 idle 'Error: Connection error. Retrying...'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  # Frozen with no new output for the connection window: one bounded continue.
  out=$(tick "$home" "$((now + 700))")
  assert_contains "$out" "watchdog: continued w1 after a connection error" \
    "a frozen connection error did not get a continue"
  assert_delivery_ids "$home"
  assert_eq "$(counter "$home" 'interrupt')" "0" "a connection error interrupted the lane instead of continuing it"
  out=$(tick "$home" "$((now + 710))")
  out=$(tick "$home" "$((now + 720))")
  # Three continues strike the lane out; the fourth action is the relaunch.
  out=$(tick "$home" "$((now + 730))")
  assert_contains "$out" "3 connection errors" \
    "three strikes did not relaunch the lane"
  assert_contains "$(cat "$home/calls")" '--model openrouter-named/deepseek/deepseek-v4.1-flash-1017' \
    "a worker lane was not relaunched onto the fallback model"
  assert_eq "$(wakes "$home" | grep -c 'connection errors')" "1" \
    "the connection relaunch did not report itself exactly once"
  assert_contains "$(cat "$home/calls")" 'model-switch w1 gateway' \
    "the worker lane was moved to the fallback model without the repoint that model needs"

  # A lane that owns scheduled ticks refuses the gateway repoint; it still comes
  # back, on its own model, and the refusal is reported rather than swallowed.
  home=$(make_home conn-refuse); fake_tools "$home"
  worker "$home" w9 alive ship claude
  pane "$home" w9 idle 'Error: Connection reset by peer'
  : > "$home/units/lane-switch-refuses"
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 700))" >/dev/null
  tick "$home" "$((now + 710))" >/dev/null
  tick "$home" "$((now + 720))" >/dev/null
  tick "$home" "$((now + 730))" >/dev/null
  assert_contains "$(cat "$home/calls")" 'control w9 relaunch' \
    "a lane that refused the repoint was never relaunched at all"
  grep -q -- '--model' "$home/calls" && fail "a lane that refused the repoint was relaunched onto a model it cannot reach"
  assert_contains "$(wakes "$home")" 'could not move w9' \
    "a refused repoint was not reported to firstmate"
  pass "a lane frozen on a connection error is continued, then relaunched onto the fallback worker model"
}

test_a_pi_lane_is_never_asked_to_move_to_a_model_it_cannot_reach() {
  local home now out
  home=$(make_home conn-pi); fake_tools "$home"
  worker "$home" w1 alive ship pi
  pane "$home" w1 idle 'Error: Connection error. Retrying...'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 700))" >/dev/null
  tick "$home" "$((now + 710))" >/dev/null
  tick "$home" "$((now + 720))" >/dev/null
  out=$(tick "$home" "$((now + 730))")
  # The lane still comes back - restoring it matters more than the model.
  assert_contains "$(cat "$home/calls")" 'control w1 relaunch' \
    "a pi lane stuck on a connection error was never relaunched"
  # ...but it is never asked for a repoint it cannot perform, and firstmate is
  # never woken for an impossible action it cannot take.
  grep -q -- 'model-switch' "$home/calls" \
    && fail "a pi lane was asked for a /model repoint its harness cannot perform"
  grep -q -- '--model' "$home/calls" \
    && fail "a pi lane was relaunched onto the fallback model instead of its own"
  ! wakes "$home" | grep -q 'could not move w1' \
    || fail "an impossible /model switch on a pi lane was reported to firstmate as a failure"
  # The connection ladder's relaunch rung is budgeted like the stall ladder's.
  # Seven lanes were relaunched twelve times each in fifty-five minutes because
  # this rung had no cap: every pass past the strike count relaunched again.
  local t
  for t in 740 750 760 770 780 790 800 810; do
    tick "$home" "$((now + t))" >/dev/null 2>&1
  done
  assert_eq "$(counter "$home" '^control .* relaunch')" "3" \
    "the connection relaunch rung ignored its hourly budget"
  assert_eq "$(wakes "$home" | grep -c 'relaunch budget')" "1" \
    "a spent connection relaunch budget was not reported exactly once"
  pass "a pi lane is relaunched on its own model, never asked for a repoint it cannot perform"
}

test_a_review_seat_keeps_its_model_and_a_permanent_error_is_never_retried() {
  local home now
  home=$(make_home conn-review); fake_tools "$home"
  worker "$home" w1 alive review
  pane "$home" w1 idle 'Error: Connection reset by peer'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 700))" >/dev/null
  tick "$home" "$((now + 710))" >/dev/null
  tick "$home" "$((now + 720))" >/dev/null
  tick "$home" "$((now + 730))" >/dev/null
  assert_contains "$(cat "$home/calls")" 'control w1 relaunch' \
    "a review seat frozen on a connection error was never relaunched"
  grep -q -- '--model' "$home/calls" && fail "a review seat was moved off the model the captain chose for it"

  # A permanent failure is never retried at all, however long it sits there.
  home=$(make_home conn-permanent); fake_tools "$home"
  worker "$home" w2 alive ship
  pane "$home" w2 idle 'Connection error: usage limit reached for this account'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 900))" >/dev/null
  assert_eq "$(counter "$home" 'w2')" "0" "a permanent failure was retried by the connection ladder"
  pass "a review seat keeps its model and a permanent failure is never retried"
}

test_in_flight_backlog_items_without_a_record_are_reported_once() {
  local home now out
  home=$(make_home backlog); fake_tools "$home"
  worker "$home" w1 alive
  pane "$home" w1 idle 'fine'
  backlog_bin "$home" w1 ghost-lane
  now=$(start_clock)
  out=$(tick "$home" "$now" FM_WATCHDOG_BACKLOG=on FM_WATCHDOG_BACKLOG_BIN="$home/fakebin/tasks-axi")
  assert_contains "$out" "1 in-flight backlog item(s) with no task record" \
    "an unservable in-flight backlog item was not reported"
  assert_contains "$out" "ghost-lane" "the report did not name the unservable item"
  assert_contains "$(wakes "$home")" "ghost-lane" "the report never reached firstmate"
  assert_eq "$(wakes "$home" | grep -c 'no task record')" "1" "the report was made more than once for one change"

  out=$(tick "$home" "$((now + 300))" FM_WATCHDOG_BACKLOG=on FM_WATCHDOG_BACKLOG_BIN="$home/fakebin/tasks-axi")
  assert_eq "$(wakes "$home" | grep -c 'no task record')" "1" \
    "an unchanged unservable set reported itself again"

  backlog_bin "$home" w1
  tick "$home" "$((now + 600))" FM_WATCHDOG_BACKLOG=on FM_WATCHDOG_BACKLOG_BIN="$home/fakebin/tasks-axi" >/dev/null
  backlog_bin "$home" w1 ghost-lane ghost-two
  out=$(tick "$home" "$((now + 900))" FM_WATCHDOG_BACKLOG=on FM_WATCHDOG_BACKLOG_BIN="$home/fakebin/tasks-axi")
  assert_eq "$(wakes "$home" | grep -c 'no task record')" "2" \
    "a changed unservable set did not report itself again"
  assert_contains "$out" "ghost-two" "the second report did not name the new item"
  pass "in-flight backlog items with no task record are reported once per change, never silently"
}

test_a_dry_run_reports_every_lane_and_changes_nothing() {
  local home now out
  home=$(make_home dry); fake_tools "$home"
  worker "$home" w1 dead
  worker "$home" w2 alive
  pane "$home" w2 idle 'working'
  steer "$home" w2 5500
  now=$(start_clock)
  out=$(WD_ARGS=--dry-run tick "$home" "$now")
  assert_contains "$out" "dry run - no lane, unit, record, or wake is touched" \
    "the dry run did not say it changes nothing"
  assert_contains "$out" "$(printf 'w1\tdead')" "the dry-run table omitted a dead lane"
  assert_contains "$out" "$(printf 'w2\talive')" "the dry-run table omitted a live lane"
  assert_contains "$out" "would relaunch w1" "the dry run did not plan the dead lane's relaunch"
  assert_contains "$out" "would relaunch w2 to drain an unread steering inbox" \
    "the dry run did not plan the unread inbox's relaunch"
  # A read-only listing is allowed; a lifecycle command is not.
  grep -qE '^control |^send |^model-switch |--user (start|restart|reset-failed)' "$home/calls" 2>/dev/null \
    && fail "a dry run ran a lifecycle command: $(cat "$home/calls")"
  [ -e "$home/state/.wake-queue" ] && fail "a dry run queued a wake"
  [ -e "$home/state/.watchdog-worker.json" ] && fail "a dry run wrote the durable record"
  pass "a dry run reports every lane's plan and touches nothing"
}

test_a_held_task_is_never_relaunched_or_paged() {
  local home now out
  home=$(make_home held); fake_tools "$home"
  worker "$home" w1 dead
  worker "$home" w2 alive
  pane "$home" w2 busy 'a tool call that never returns'
  steer "$home" w2 5500
  held_backlog_bin "$home" w1 w2
  now=$(start_clock)
  out=$(tick "$home" "$now" FM_WATCHDOG_BACKLOG=on FM_WATCHDOG_BACKLOG_BIN="$home/fakebin/tasks-axi")
  [ -z "$out" ] || fail "a held task was acted on: $out"
  assert_eq "$(counter "$home" '^control .* relaunch')" "0" "a held task was relaunched"
  assert_eq "$(counter "$home" '^send ')" "0" "a held task was steered"
  [ -z "$(wakes "$home")" ] || fail "a held task woke firstmate: $(wakes "$home")"
  out=$(tick "$home" "$((now + 300))" FM_WATCHDOG_BOOT_ID=boot-a FM_WATCHDOG_BACKLOG=on FM_WATCHDOG_BACKLOG_BIN="$home/fakebin/tasks-axi")
  assert_contains "$out" "relaunched 0 of 0 task(s)" "the boot pass counted or relaunched a held task"
  assert_eq "$(counter "$home" '^control .* relaunch')" "0" "the boot pass relaunched a held task"
  pass "a held task is never relaunched or paged, in the boot pass or the task pass"
}

test_a_dry_run_plan_matches_the_connection_relaunch_model() {
  local home now out
  home=$(make_home dry-conn); fake_tools "$home"
  worker "$home" w1 alive review claude
  pane "$home" w1 idle 'Error: Connection reset by peer'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 700))" >/dev/null
  tick "$home" "$((now + 710))" >/dev/null
  tick "$home" "$((now + 720))" >/dev/null
  out=$(WD_ARGS=--dry-run tick "$home" "$((now + 730))")
  assert_contains "$out" "would relaunch on its own model" \
    "the dry-run plan promised a fallback model the pass refuses for a review seat"
  assert_not_contains "$out" "would relaunch on fallback model" \
    "the dry-run plan disagreed with the pass about the review seat's model"
  pass "the dry-run plan agrees with the connection relaunch's fallback-kind rule"
}

test_a_refused_relaunch_spends_no_budget_and_escalates_once() {
  local home now out i refused=''
  home=$(make_home refused); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  worker "$home" w1 dead
  now=$(start_clock)
  for i in 0 1 2 3 4 5; do
    out=$(tick "$home" "$((now + i * 60))")
    [ "$i" = 0 ] && refused=$out
  done
  assert_contains "$refused" "in-place relaunch is not proven end to end" \
    "the refusal was not reported with the backend's own reason"
  assert_eq "$(counter "$home" '^control .* relaunch')" "1" \
    "a structurally refused relaunch was retried instead of recorded once"
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "1" \
    "a refused relaunch did not escalate exactly once"
  assert_eq "$(wakes "$home" | grep -c 'hourly relaunch budget')" "0" \
    "a refused relaunch was charged against the hourly budget"
  pass "a relaunch the backend cannot perform is recorded once, escalated once, and spends no budget"
}

test_a_refused_relaunch_is_retried_only_after_its_window() {
  local home now
  home=$(make_home refused-window); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  worker "$home" w1 dead
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 600))" >/dev/null
  assert_eq "$(counter "$home" '^control .* relaunch')" "1" \
    "a recorded refusal was retried inside its window"
  tick "$home" "$((now + 21600 + 60))" >/dev/null
  assert_eq "$(counter "$home" '^control .* relaunch')" "2" \
    "a refusal was never retried again, so a fixed backend wait would be lost"
  pass "a recorded refusal is retried only once its retry window closes"
}

test_a_refusal_does_not_outlive_the_endpoint_that_earned_it() {
  local home now
  home=$(make_home refused-recovered); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  worker "$home" w1 dead
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "1" \
    "a structural refusal was not escalated once"
  worker "$home" w1 alive
  tick "$home" "$((now + 120))" >/dev/null
  assert_eq "" "$(jq -r '.tasks.w1.refusal' "$home/state/.watchdog-worker.json")" \
    "a refusal survived the endpoint coming back"
  worker "$home" w1 dead
  tick "$home" "$((now + 240))" >/dev/null
  assert_eq "$(counter "$home" '^control .* relaunch')" "2" \
    "a later death inside the refusal window was never retried"
  pass "a refusal only suppresses relaunches while its own endpoint is unrecovered"
}

test_a_live_lane_keeps_the_refusal_its_stall_earned() {
  local home now
  home=$(make_home ladder-refused); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  worker "$home" w1 alive
  pane "$home" w1 busy 'a tool call that never returns'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 1900))" >/dev/null
  tick "$home" "$((now + 2600))" >/dev/null
  assert_eq "$(counter "$home" '^control w1 relaunch')" "1" \
    "a live stalled lane never earned a refusal"
  tick "$home" "$((now + 2700))" >/dev/null
  tick "$home" "$((now + 2800))" >/dev/null
  assert_eq "$(counter "$home" '^control w1 relaunch')" "1" \
    "a live lane re-attempted a refused relaunch on every pass"
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "1" \
    "a live lane re-escalated a refusal it had already reported"
  pass "a refusal survives the pass that earned it while the lane stays alive"
}

test_a_flapping_unreadable_read_keeps_the_refusal() {
  local home now
  home=$(make_home refused-flap); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  worker "$home" w1 dead
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  assert_eq "$(counter "$home" '^control w1 relaunch')" "1" \
    "a structural refusal was never earned"
  worker "$home" w1 unreadable
  tick "$home" "$((now + 120))" >/dev/null
  worker "$home" w1 dead
  tick "$home" "$((now + 240))" >/dev/null
  tick "$home" "$((now + 360))" >/dev/null
  assert_eq "$(counter "$home" '^control w1 relaunch')" "1" \
    "an unmeasurable read cleared a refusal, so the refused relaunch was retried"
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "1" \
    "a flapping endpoint re-escalated a refusal it had already reported"
  pass "a refusal survives a flapping unmeasurable read of the same endpoint"
}

test_a_dry_run_reports_a_suppressed_relaunch() {
  local home now out
  home=$(make_home dry-refused); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  worker "$home" w1 dead
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  out=$(WD_ARGS=--dry-run tick "$home" "$((now + 120))")
  assert_contains "$out" "would escalate (relaunch refused" \
    "the dry run promised a relaunch the pass would refuse"
  assert_eq "$(counter "$home" '^control w1 relaunch')" "1" \
    "the dry run ran a lifecycle command"
  pass "a dry run plans no relaunch while a refusal suppresses it"
}

test_a_connection_relaunch_failure_is_charged_against_the_budget() {
  local home now
  home=$(make_home conn-transient); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-transient"
  worker "$home" w1 alive ship pi
  pane "$home" w1 idle 'Error: Connection reset by peer'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 700))" >/dev/null
  tick "$home" "$((now + 710))" >/dev/null
  tick "$home" "$((now + 720))" >/dev/null
  tick "$home" "$((now + 730))" >/dev/null
  assert_eq "1" "$(jq -r '.tasks.w1.relaunches | length' "$home/state/.watchdog-worker.json")" \
    "a connection relaunch attempt that failed was not charged against the hourly budget"
  tick "$home" "$((now + 740))" >/dev/null
  assert_eq "2" "$(counter "$home" '^control w1 relaunch')" \
    "a transient connection relaunch failure was not retried"
  tick "$home" "$((now + 830))" >/dev/null
  assert_eq "3" "$(jq -r '.tasks.w1.relaunches | length' "$home/state/.watchdog-worker.json")" \
    "the connection ladder did not charge every attempt against the budget"
  tick "$home" "$((now + 930))" >/dev/null
  tick "$home" "$((now + 1030))" >/dev/null
  assert_eq "3" "$(counter "$home" '^control w1 relaunch')" \
    "a spent relaunch budget still retried the connection relaunch"
  assert_eq "1" "$(wakes "$home" | grep -c 'hourly relaunch budget')" \
    "a spent connection relaunch budget did not escalate exactly once"
  pass "a connection relaunch failure is charged, retried, then escalated once the budget is spent"
}

test_a_stall_ladder_escalates_once_its_relaunch_budget_is_spent() {
  local home now
  home=$(make_home ladder-budget); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-transient"
  worker "$home" w1 alive
  pane "$home" w1 busy 'a tool call that never returns'
  now=$(start_clock)
  tick "$home" "$now" >/dev/null
  tick "$home" "$((now + 1900))" >/dev/null
  tick "$home" "$((now + 2600))" >/dev/null
  tick "$home" "$((now + 3200))" >/dev/null
  tick "$home" "$((now + 3800))" >/dev/null
  tick "$home" "$((now + 4400))" >/dev/null
  tick "$home" "$((now + 5000))" >/dev/null
  assert_eq "3" "$(counter "$home" '^control w1 relaunch')" \
    "a spent relaunch budget still retried the stalled lane's relaunch"
  assert_eq "1" "$(wakes "$home" | grep -c 'hourly relaunch budget')" \
    "a stalled lane whose relaunches all failed never reached firstmate"
  assert_eq "1" "$(jq -r '.tasks.w1.stage' "$home/state/.watchdog-worker.json")" \
    "a failed relaunch claimed the stall rung"
  pass "a stall ladder retries its failed relaunch on the budget, then escalates once"
}

test_a_transient_relaunch_failure_is_not_a_refusal() {
  local home now i
  home=$(make_home transient); fake_tools "$home"
  CONTROL_OVERRIDE="$home/fakebin/fake-control-refuses"
  : > "$home/units/control-transient"
  worker "$home" w1 dead
  now=$(start_clock)
  for i in 0 1 2 3 4 5; do
    tick "$home" "$((now + i * 60))" >/dev/null
  done
  assert_eq "$(counter "$home" '^control .* relaunch')" "3" \
    "a transient relaunch failure was not retried on the ordinary budget"
  assert_eq "$(wakes "$home" | grep -c 'cannot relaunch w1')" "0" \
    "a transient launch failure was escalated as a structural refusal"
  pass "a timeout is retried on the ordinary budget, never treated as a structural refusal"
}

test_an_orca_terminal_that_is_gone_is_replaced_by_a_spawn() {
  local home now out
  home=$(make_home orca-missing); fake_tools "$home"
  worker "$home" w1 missing ship pi orca
  now=$(start_clock)
  out=$(tick "$home" "$now")
  assert_contains "$out" "watchdog: relaunched w1 after endpoint missing" \
    "a gone Orca terminal was not replaced"
  assert_eq "$(counter "$home" '^spawn w1 --relaunch')" "1" \
    "the Orca replacement did not go through fm-spawn --relaunch"
  assert_eq "$(counter "$home" '^control .* relaunch')" "0" \
    "a gone Orca terminal was still handed to fm-control's unproven in-place relaunch"
  [ -s "$home/steers" ] || fail "the replacement agent got no carry-over note"
  grep -q 'worktree and commits are intact' "$home/steers" \
    || fail "the carry-over note did not tell the new agent what survived: $(cat "$home/steers")"
  [ -z "$(wakes "$home")" ] || fail "a successful Orca replacement still woke firstmate: $(wakes "$home")"
  pass "an Orca terminal Orca itself reports gone is replaced by fm-spawn --relaunch and carries its note"
}

test_a_refused_relaunch_spends_no_budget_and_escalates_once
test_a_refused_relaunch_is_retried_only_after_its_window
test_a_refusal_does_not_outlive_the_endpoint_that_earned_it
test_a_live_lane_keeps_the_refusal_its_stall_earned
test_a_flapping_unreadable_read_keeps_the_refusal
test_a_dry_run_reports_a_suppressed_relaunch
test_a_transient_relaunch_failure_is_not_a_refusal
test_a_structural_refusal_outside_the_old_phrase_list_spends_no_budget
test_a_boot_transient_failure_keeps_the_lane_relaunch_history
test_a_boot_refusal_keeps_the_lane_relaunch_history
test_lifecycle_lock_contention_is_retried_not_recorded
test_an_orca_replacement_names_a_note_it_could_not_deliver
test_a_spawn_preflight_refusal_spends_no_budget_and_retries_once
test_a_transient_spawn_failure_is_not_a_refusal
test_an_orca_terminal_that_is_gone_is_replaced_by_a_spawn
test_a_task_left_stopped_is_never_relaunched_or_paged
test_a_dead_worker_comes_back_in_one_pass_with_no_wake
test_an_unread_steer_is_interrupted_then_relaunched_once_each
test_a_transient_inbox_relaunch_failure_is_not_announced_as_done
test_a_spent_inbox_relaunch_budget_stops_retrying_and_escalates_once
test_a_connection_error_lane_is_continued_then_relaunched_on_the_fallback_model
test_a_connection_relaunch_failure_is_charged_against_the_budget
test_a_pi_lane_is_never_asked_to_move_to_a_model_it_cannot_reach
test_a_review_seat_keeps_its_model_and_a_permanent_error_is_never_retried
test_in_flight_backlog_items_without_a_record_are_reported_once
test_a_dry_run_reports_every_lane_and_changes_nothing
test_a_held_task_is_never_relaunched_or_paged
test_a_dry_run_plan_matches_the_connection_relaunch_model
test_a_reboot_rebuilds_the_fleet_and_starts_the_chair_last
test_the_same_boot_is_not_a_boot_twice
test_a_new_boot_identity_runs_the_boot_pass_again
test_a_transient_stall_relaunch_failure_does_not_climb_the_ladder
test_a_stall_ladder_escalates_once_its_relaunch_budget_is_spent
test_a_stalled_worker_climbs_the_ladder_and_escalates_once
test_progress_and_status_lines_reset_the_ladder
test_the_relaunch_cap_escalates_once_instead_of_looping
test_an_idle_worker_is_nudged_once_and_run_steps_are_left_alone
test_failed_units_restart_but_never_the_watchdog_itself
test_a_unit_that_keeps_failing_escalates_once
test_an_unclassifiable_endpoint_is_never_relaunched
test_secondmates_are_not_the_watchdogs_to_relaunch
test_a_chair_that_will_not_start_reports_itself
test_status_prints_the_record_and_a_foreign_schema_is_ignored
test_a_concurrent_pass_is_skipped_not_doubled
