#!/usr/bin/env bash
# Behavior tests for the machine-capacity spawn guard: bin/fm-capacity-lib.sh,
# its bin/fm-capacity.sh report, and its refusal on every fm-spawn.sh path.
#
# The guard exists because firstmate drove a 24 GB machine to a standstill. Two
# things about that incident drive these tests, and both are counter-intuitive
# enough that they need pinning:
#
#   - MEMORY was the binding resource, not CPU. When measured, the machine had
#     155 MB of 24 GB unused with 20 GB of swap consumed, while CPU usage was
#     about 4.6 of 10 cores and no fleet agent appeared among the top consumers.
#     The 1m load average of 299 was processes frozen on paging, not CPU demand.
#     So test_load_alone_never_refuses pins that load cannot refuse by itself,
#     and test_each_memory_signal_can_refuse_alone pins that each memory signal
#     can - including on a machine whose load average looks completely fine.
#
#   - Pausing agents did not help, because a paused agent keeps its memory. So
#     the fleet signal is weighed by footprint rather than headcount, which
#     test_fleet_memory_is_weighed_by_footprint_not_headcount pins.
#
# The other trap is destructive: "restore headroom" reads as "stop some agents",
# which would destroy unlanded work. The guard only ever declines NEW work, and
# test_refusal_leaves_live_work_untouched is the regression for that.
#
# Machine measurements are injected (tests/capacity-pin.sh documents the hook),
# so these assertions describe the guard's decisions rather than the memory
# pressure on whatever machine happens to be running the suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CAPACITY="$ROOT/bin/fm-capacity.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-capacity)

# The incident machine, in the shape it was actually measured in: 24 GB with
# 155 MB unused, swap 93% consumed after 25.7 million swapouts, the kernel
# reclaiming, the fleet holding 6.7 GB across 35 agents and 389 processes, and a
# load average of 299 that reflects paging stalls rather than CPU demand.
SATURATED=(
  FM_CAPACITY_MEM_TOTAL_MB=24576
  FM_CAPACITY_MEM_FREE_MB=155
  FM_CAPACITY_SWAP_TOTAL_MB=21504
  FM_CAPACITY_SWAP_USED_MB=20023
  FM_CAPACITY_MEM_PRESSURE=warn
  FM_CAPACITY_SWAPOUTS=25702389
  FM_CAPACITY_FLEET_RSS_MB=6870
  FM_CAPACITY_FLEET_AGENTS=35
  FM_CAPACITY_FLEET_PROCS=389
  FM_CAPACITY_CORES=10
  FM_CAPACITY_LOAD1=299.00
)

# A machine with memory to spare, used as the base for single-signal cases.
HEALTHY=(
  FM_CAPACITY_MEM_TOTAL_MB=24576
  FM_CAPACITY_MEM_FREE_MB=12000
  FM_CAPACITY_SWAP_TOTAL_MB=21504
  FM_CAPACITY_SWAP_USED_MB=0
  FM_CAPACITY_MEM_PRESSURE=normal
  FM_CAPACITY_SWAPOUTS=0
  FM_CAPACITY_FLEET_RSS_MB=1024
  FM_CAPACITY_FLEET_AGENTS=2
  FM_CAPACITY_FLEET_PROCS=12
  FM_CAPACITY_CORES=10
  FM_CAPACITY_LOAD1=1.50
)

# --- fixtures ---------------------------------------------------------------

# A fake tmux and treehouse that record every invocation, so a test can prove
# the guard consulted neither before declining.
make_capacity_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_TMUX_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
fi
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 case_dir home proj wt fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_capacity_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

# run_spawn <home> <wt> <fakebin> [env assignments...] -- <spawn args...>
run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" = "--" ] && shift
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' GROK_HOME="$home/grok-home" \
    FM_FAKE_TMUX_LOG="$home/tmux.log" FM_FAKE_TREEHOUSE_LOG="$home/treehouse.log" \
    PATH="$fakebin:$PATH" \
    "${envs[@]+"${envs[@]}"}" \
    "$SPAWN" "$@" 2>&1
}

# --- every spawn path refuses under saturation ------------------------------

test_crewmate_spawn_refuses_when_saturated() {
  local rec id out status
  id=capacity-ship-a1
  rec=$(make_case crewmate "$id")
  read_case_record "$rec"

  # A ship spawn now requires an explicit --mode and --yolo; the capacity refusal
  # must fire regardless, so pass both rather than letting an arg check mask it.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${SATURATED[@]}" -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a crewmate spawn must be declined on a machine that is out of memory"
  assert_contains "$out" "refusing to start ship task $id" "refusal did not name the declined crewmate work"
  assert_absent "$HOME_DIR/state/$id.meta" "a declined crewmate spawn must leave no task record behind"
  pass "a crewmate spawn is declined when the machine has no headroom"
}

test_scout_spawn_refuses_when_saturated() {
  local rec id out status
  id=capacity-scout-a2
  rec=$(make_case scout "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${SATURATED[@]}" -- "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "a scout spawn must be declined on a machine that is out of memory"
  assert_contains "$out" "refusing to start scout task $id" "refusal did not name the declined scout work"
  assert_absent "$HOME_DIR/state/$id.meta" "a declined scout spawn must leave no task record behind"
  pass "a scout spawn is declined when the machine has no headroom"
}

test_secondmate_spawn_refuses_when_saturated() {
  local rec id out status subhome
  id=capacity-second-a3
  rec=$(make_case secondmate "$id")
  read_case_record "$rec"
  subhome="$CASE_DIR/subhome"
  make_seeded_secondmate_home "$subhome" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${SATURATED[@]}" -- "$id" "$subhome" --secondmate)
  status=$?
  expect_code 1 "$status" "a secondmate spawn must be declined on a machine that is out of memory"
  assert_contains "$out" "refusing to start secondmate task $id" "refusal did not name the declined secondmate work"
  assert_absent "$HOME_DIR/state/$id.meta" "a declined secondmate spawn must leave no task record behind"
  pass "a secondmate spawn is declined when the machine has no headroom"
}

test_spawn_proceeds_when_the_machine_has_headroom() {
  local rec id out status
  id=capacity-ok-a4
  rec=$(make_case headroom "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${HEALTHY[@]}" -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn on a machine with memory to spare must proceed"
  assert_contains "$out" "spawned $id harness=claude" "the healthy-machine spawn did not report success"
  assert_not_contains "$out" "refusing to start" "a healthy machine must produce no capacity refusal"
  assert_present "$HOME_DIR/state/$id.meta" "the admitted spawn did not record its task"
  pass "a spawn proceeds normally when the machine has headroom"
}

# --- the refusal is legible -------------------------------------------------

test_refusal_states_measured_and_wanted_values() {
  local rec id out
  id=capacity-legible-b1
  rec=$(make_case legible "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${SATURATED[@]}" -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off) || true

  # Every signal is named with both its real measurement and its limit, so the
  # operator can see the actual numbers and decide whether to override.
  assert_contains "$out" "free memory" "refusal omitted the free-memory signal"
  assert_contains "$out" "0.2 GB of 24.0 GB installed" "refusal omitted the measured free memory"
  assert_contains "$out" "wanted at least 1.0 GB free" "refusal omitted the free-memory floor it wanted"
  assert_contains "$out" "swap in use" "refusal omitted the swap signal"
  assert_contains "$out" "19.6 GB of 21.0 GB swap (93%)" "refusal omitted the measured swap usage"
  assert_contains "$out" "25702389 swapouts since boot" "refusal omitted the swapout evidence"
  assert_contains "$out" "at most 50% of swap used" "refusal omitted the swap limit it wanted"
  assert_contains "$out" "memory pressure" "refusal omitted the kernel memory-pressure signal"
  assert_contains "$out" "fleet memory" "refusal omitted what firstmate's own agents hold"
  assert_contains "$out" "across 35 agents and their 389 processes" \
    "refusal omitted the fleet process-tree measurement"
  assert_contains "$out" "load per core" "refusal omitted the corroborating load reading"
  assert_contains "$out" "1m load 299.00 over 10 cores" "refusal omitted the measured load average"
  assert_contains "$out" "Nothing already running was touched" \
    "refusal did not say that live work is unaffected"
  assert_contains "$out" "mode = off" "refusal did not tell the operator how to override it"
  pass "a refusal states every measured value against the value it wanted"
}

# --- the hard constraint: never touch live work -----------------------------

test_refusal_leaves_live_work_untouched() {
  local rec id live_id out status live_pid meta_before status_before
  id=capacity-untouched-c1
  live_id=capacity-live-c0
  rec=$(make_case untouched "$id")
  read_case_record "$rec"

  # A worker that is already running, with the durable records a live task has.
  sleep 120 &
  live_pid=$!
  fm_write_meta "$HOME_DIR/state/$live_id.meta" \
    "window=firstmate:fm-$live_id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "pid=$live_pid"
  printf 'working: mid-flight, nothing landed yet\n' > "$HOME_DIR/state/$live_id.status"
  printf 'uncommitted work\n' > "$WT_DIR/unlanded.txt"
  meta_before=$(cat "$HOME_DIR/state/$live_id.meta")
  status_before=$(cat "$HOME_DIR/state/$live_id.status")

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${SATURATED[@]}" -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "the out-of-memory spawn must be declined"

  kill -0 "$live_pid" 2>/dev/null || fail "the guard stopped a process that was already running"
  [ "$(cat "$HOME_DIR/state/$live_id.meta")" = "$meta_before" ] \
    || fail "the guard modified a live task's durable record"
  [ "$(cat "$HOME_DIR/state/$live_id.status")" = "$status_before" ] \
    || fail "the guard modified a live task's status log"
  assert_present "$WT_DIR/unlanded.txt" "the guard removed unlanded work from a live worktree"
  # Nothing was asked of the terminal or worktree providers at all: the guard
  # decides before any of them are consulted, so it cannot reap by accident.
  assert_absent "$HOME_DIR/tmux.log" "a declined spawn must issue no terminal commands"
  assert_absent "$HOME_DIR/treehouse.log" "a declined spawn must allocate no worktree"
  assert_absent "$HOME_DIR/state/.spawn-$id.lock" "a declined spawn must leave no lock behind"

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  pass "a refusal never stops, reaps, or edits work that is already running"
}

# --- memory is the binding resource -----------------------------------------

# spawn_under <name> <expected-exit> <env assignments...> - runs one spawn on a
# machine described entirely by the given measurements and echoes its output.
spawn_under() {
  local name=$1 want=$2
  shift 2
  local rec id out status
  id="capacity-signal-$name"
  rec=$(make_case "signal-$name" "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@" -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code "$want" "$status" "the $name case did not reach the expected decision"
  printf '%s\n' "$out"
}

test_each_memory_signal_can_refuse_alone() {
  local out

  # Each case below leaves the load average at a comfortable 1.50 over 10 cores,
  # so the refusal can only be coming from the memory-side instrument.
  out=$(spawn_under free-memory 1 "${HEALTHY[@]}" FM_CAPACITY_MEM_FREE_MB=155)
  assert_contains "$out" "no headroom left on memory" "free memory alone did not decline the spawn"
  assert_contains "$out" "0.15 per core" "the case did not keep the load average comfortable"

  out=$(spawn_under swap 1 "${HEALTHY[@]}" FM_CAPACITY_SWAP_USED_MB=20023)
  assert_contains "$out" "no headroom left on swap" "swap usage alone did not decline the spawn"

  out=$(spawn_under pressure 1 "${HEALTHY[@]}" FM_CAPACITY_MEM_PRESSURE=critical)
  assert_contains "$out" "no headroom left on pressure" "kernel memory pressure alone did not decline the spawn"

  out=$(spawn_under fleet 1 "${HEALTHY[@]}" FM_CAPACITY_FLEET_RSS_MB=12000)
  assert_contains "$out" "no headroom left on fleet" "the fleet's own memory alone did not decline the spawn"
  pass "free memory, swap, kernel pressure, and fleet memory each decline a spawn on their own"
}

test_load_alone_never_refuses() {
  local out

  # The measured incident: a load average of 299 on 10 cores while CPU usage was
  # about 4.6 cores, because the load was processes frozen on paging. A guard
  # that refused on load alone would be reading the wrong instrument, so this
  # machine - memory fine, load catastrophic - must be admitted.
  out=$(spawn_under load-only 0 "${HEALTHY[@]}" FM_CAPACITY_LOAD1=299.00)
  assert_contains "$out" "spawned capacity-signal-load-only" \
    "a high load average with memory to spare must not decline a spawn"

  # It is still measured and still shown, because it is real evidence.
  out=$(spawn_under load-shown 1 "${HEALTHY[@]}" FM_CAPACITY_LOAD1=299.00 FM_CAPACITY_MEM_FREE_MB=155)
  assert_contains "$out" "1m load 299.00 over 10 cores" "the load average was not reported at all"
  assert_contains "$out" "context only" "the load average was not labelled as corroborating context"
  assert_not_contains "$out" "no headroom left on memory and load" \
    "load must not be blamed for a refusal it did not cause"
  pass "a high load average is reported as context and never refuses on its own"
}

test_operator_can_opt_into_a_load_limit() {
  local rec id out status
  id=capacity-load-limit-b5
  rec=$(make_case load-limit "$id")
  read_case_record "$rec"
  printf 'load_per_core_max = 4\n' > "$HOME_DIR/config/spawn-capacity"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${HEALTHY[@]}" \
    FM_CAPACITY_LOAD1=299.00 -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "an explicit load ceiling must be able to decline a spawn"
  assert_contains "$out" "no headroom left on load" "the opted-in load ceiling did not decline the spawn"
  assert_contains "$out" "wanted at most 4" "the opted-in load ceiling was not reported"
  pass "an operator who wants a CPU-side ceiling can make load average a limit"
}

test_fleet_memory_is_weighed_by_footprint_not_headcount() {
  local out

  # Pausing three whole domains during the incident did not drain the machine,
  # because a paused agent keeps every page it allocated. So a small number of
  # large agents must refuse...
  out=$(spawn_under fleet-heavy 1 "${HEALTHY[@]}" \
    FM_CAPACITY_FLEET_AGENTS=4 FM_CAPACITY_FLEET_PROCS=40 FM_CAPACITY_FLEET_RSS_MB=12000)
  assert_contains "$out" "no headroom left on fleet" "a few memory-heavy agents were not declined"
  assert_contains "$out" "across 4 agents" "the refusal did not report the agent count alongside the footprint"

  # ...while many small ones must not, which a headcount limit could never tell
  # apart from the case above.
  out=$(spawn_under fleet-light 0 "${HEALTHY[@]}" \
    FM_CAPACITY_FLEET_AGENTS=40 FM_CAPACITY_FLEET_PROCS=400 FM_CAPACITY_FLEET_RSS_MB=2000)
  assert_contains "$out" "spawned capacity-signal-fleet-light" \
    "many small agents were declined by what should be a memory measurement"
  pass "the fleet limit is on memory held, not on how many agents are running"
}

# --- an unreadable signal is an explicit unknown ----------------------------

test_unreadable_signal_refuses_by_default() {
  local out
  out=$(spawn_under unknown-default 1 "${HEALTHY[@]}" FM_CAPACITY_SWAP_USED_MB=unknown)
  assert_contains "$out" "swap could not be measured" "the unknown signal was not named"
  assert_contains "$out" "headroom is unproven" "the refusal did not say headroom was unproven"
  assert_contains "$out" "[unknown]" "the unknown signal was not shown in the measurement table"
  pass "an unreadable signal is reported as unknown and declines rather than silently passing"
}

test_operator_can_opt_into_allowing_unknown_signals() {
  local rec id out status
  id=capacity-unknown-d2
  rec=$(make_case unknown-allow "$id")
  read_case_record "$rec"
  printf 'on_unknown = allow\n' > "$HOME_DIR/config/spawn-capacity"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${HEALTHY[@]}" \
    FM_CAPACITY_SWAP_USED_MB=unknown -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "on_unknown = allow must let an unmeasurable signal through"
  assert_contains "$out" "spawned $id" "the opted-in spawn did not proceed"
  pass "the operator can opt into proceeding when a signal cannot be measured"
}

test_absent_swap_is_an_answer_not_an_unknown() {
  local out
  out=$(spawn_under no-swap 0 "${HEALTHY[@]}" FM_CAPACITY_SWAP_TOTAL_MB=0 FM_CAPACITY_SWAP_USED_MB=0)
  assert_contains "$out" "spawned capacity-signal-no-swap" \
    "a machine with swap disabled must not be treated as unmeasurable"
  pass "a machine with no swap configured reads as a real answer, not an unreadable signal"
}

# --- the limits are operator-settable ---------------------------------------

test_operator_can_raise_the_limits() {
  local rec id out status
  id=capacity-raise-e1
  rec=$(make_case raise-limits "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/config/spawn-capacity" <<'EOF'
# The operator decides how hard he is willing to push his own machine.
min_free_memory_mb = 64
max_swap_used_pct = 99
max_memory_pressure = warn
max_fleet_memory_pct = 90
EOF

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${SATURATED[@]}" -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "raised limits must admit a spawn the defaults declined"
  assert_contains "$out" "spawned $id" "the spawn did not proceed under raised limits"
  pass "raising the limits in config/spawn-capacity admits work the defaults declined"
}

test_operator_can_switch_the_guard_off() {
  local rec id out status
  id=capacity-off-e2
  rec=$(make_case mode-off "$id")
  read_case_record "$rec"
  printf 'mode = off\n' > "$HOME_DIR/config/spawn-capacity"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${SATURATED[@]}" -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "mode = off must admit the spawn"
  assert_contains "$out" "spawned $id" "the spawn did not proceed with the guard switched off"
  pass "the operator can switch capacity checking off entirely"
}

test_malformed_settings_refuse_rather_than_silently_defaulting() {
  local rec id out status
  id=capacity-malformed-e3
  rec=$(make_case malformed "$id")
  read_case_record "$rec"
  printf 'max_swap_used_pct = plenty\n' > "$HOME_DIR/config/spawn-capacity"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "${HEALTHY[@]}" -- "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "malformed settings must refuse, not quietly fall back to defaults"
  assert_contains "$out" "max_swap_used_pct must be an integer 0-100 or off" \
    "the refusal did not name the malformed setting"
  pass "malformed capacity settings refuse loudly instead of reverting to defaults"
}

# --- what the fleet probe actually counts ------------------------------------
#
# Every case above injects the fleet measurement, so these two cover the reading
# itself: which live processes are counted as fleet, and what happens when they
# cannot be read at all.

# fleet_totals <comm-snapshot> <argv-snapshot>: the library's pure matcher, run
# in a subshell so sourcing it cannot disturb this suite's own environment.
fleet_totals() {
  ( . "$ROOT/bin/fm-capacity-lib.sh"; fm_capacity_fleet_totals "$1" "$2" )
}

test_fleet_probe_counts_interpreter_launched_harnesses() {
  local comm argv out
  # An npm-installed adapter's own command name is the interpreter, not the
  # adapter, so counting by command name alone would find no fleet here at all
  # and report a confident, silent zero.
  comm='1 0 4000 /sbin/launchd
100 1 300000 /opt/homebrew/bin/node
101 100 200000 /usr/bin/python3
200 1 150000 /Users/op/Library/Application Support/my tools/claude
300 1 90000 /usr/bin/pip'
  argv='100 node /Users/op/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js
101 python3 /usr/local/lib/agent/tool-server.py
300 pip install something'
  out=$(fleet_totals "$comm" "$argv")

  # 300000 + 200000 + 150000 KB of resident memory, across the node-launched
  # adapter and the directly-launched one, plus the tool server the first holds.
  # launchd is not fleet, and pip must never be read as the "pi" adapter.
  [ "$out" = "634 2 3" ] || fail "the fleet probe miscounted live processes: got '$out', wanted '634 2 3'"
  pass "the fleet probe counts interpreter-launched adapters and spaced paths, and not lookalikes"
}

test_fleet_probe_reports_unknown_when_processes_cannot_be_read() {
  local dir fakebin out
  dir="$TMP_ROOT/fleet-unreadable"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(env -u FM_CAPACITY_FLEET_RSS_MB -u FM_CAPACITY_FLEET_AGENTS -u FM_CAPACITY_FLEET_PROCS \
    PATH="$fakebin:$PATH" bash -c ". '$ROOT/bin/fm-capacity-lib.sh'; fm_capacity_probe_fleet")
  [ "$out" = "unknown unknown unknown" ] \
    || fail "an unreadable process table must be unknown, not a count: got '$out'"
  pass "a process table that cannot be read is an explicit unknown, never a fabricated zero"
}

# --- the operator-facing report ---------------------------------------------

test_capacity_report_shows_the_numbers_without_failing() {
  local out status
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$TMP_ROOT/no-such-config" \
    "${SATURATED[@]}" "$CAPACITY" 2>&1)
  status=$?
  expect_code 0 "$status" "the report is an inspection and must not fail on a busy machine"
  assert_contains "$out" "no headroom left" "the report did not state the verdict"
  assert_contains "$out" "19.6 GB of 21.0 GB swap" "the report did not show the measured swap usage"
  assert_contains "$out" "would be declined" "the report did not say what a spawn would do now"

  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$TMP_ROOT/no-such-config" \
    "${SATURATED[@]}" "$CAPACITY" check 2>&1)
  status=$?
  expect_code 1 "$status" "check must exit non-zero when there is no headroom"
  pass "the capacity report shows live numbers, and check exits non-zero without headroom"
}

test_crewmate_spawn_refuses_when_saturated
test_scout_spawn_refuses_when_saturated
test_secondmate_spawn_refuses_when_saturated
test_spawn_proceeds_when_the_machine_has_headroom
test_refusal_states_measured_and_wanted_values
test_refusal_leaves_live_work_untouched
test_each_memory_signal_can_refuse_alone
test_load_alone_never_refuses
test_operator_can_opt_into_a_load_limit
test_fleet_memory_is_weighed_by_footprint_not_headcount
test_unreadable_signal_refuses_by_default
test_operator_can_opt_into_allowing_unknown_signals
test_absent_swap_is_an_answer_not_an_unknown
test_operator_can_raise_the_limits
test_operator_can_switch_the_guard_off
test_malformed_settings_refuse_rather_than_silently_defaulting
test_fleet_probe_counts_interpreter_launched_harnesses
test_fleet_probe_reports_unknown_when_processes_cannot_be_read
test_capacity_report_shows_the_numbers_without_failing
