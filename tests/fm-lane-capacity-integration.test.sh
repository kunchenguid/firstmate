#!/usr/bin/env bash
# End-to-end integration coverage for the auto lane budget through the real
# firstmate paths: bin/fm-spawn.sh admitting and deferring real spawns on the
# verdict of bin/fm-capacity.sh (admit-spawns), the real bin/fm-watch.sh publish
# cycle feeding the next spawn with damped growth, idle-lane reclaim judged from
# real worker processes, and the fixed-cap path compared byte for byte against
# a baseline revision.
#
# Deterministic cases read this host's real memory and set the room they need
# through min-avail-gb relative to it, drive power through a fake pmset and a
# fixture /sys power_supply, and fake only getconf (64 cores, so this host's
# own load never binds) and df (a fixed free disk); every other probe, the
# spawn path, the watcher, the lock, the backlog, and the process table are
# real. Because that memory keeps moving, the cases assert the rules against
# the raw budget each publish actually reported (free = min(raw, previous + 2),
# the burst admits exactly the published damped value) and an exact zero only
# where the floor sits 5 GB above the live reading.
#
# Opt-in live cases (FM_TEST_LANE_LIVE_LOAD=1, or FM_LIVE=1) use only real
# probes: they load this host's CPU with niced busy loops (and optionally a
# memory hog, FM_TEST_LANE_LIVE_MEM_GB) and record the verdict before, during,
# and after the load with timestamps in FM_TEST_LANE_LIVE_LOG when set.
#
# FM_LANE_CAPACITY_BASELINE_REF names the git revision whose bin/ the fixed-cap
# comparison runs against (default: 5c935cfb, the last fixed-cap-only
# revision); when the history lacks it that one comparison reports a skip line
# and the rest runs.
# shellcheck disable=SC2016 # fake commands are written as single-quoted scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
CAPACITY="$ROOT/bin/fm-capacity.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-capacity-integration)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1
BG_PIDS=

cleanup_workers() {
  local p
  for p in $BG_PIDS; do kill "$p" 2>/dev/null || true; done
  BG_PIDS=
}
trap 'cleanup_workers; fm_test_cleanup' EXIT

# --- fixtures ---------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task

## Captain's intent

Run a short task for $2.

## Firstmate spec

Exercise lane capacity admission.

Delivery contract: mode=no-mistakes
EOF
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

# make_case <name> <task-id...>: a home with a git project, a fake terminal
# (tmux) and worktree tool, and the lane probes this suite controls.
make_case() {
  local name=$1 case_dir home fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  mkdir -p "$case_dir/v" "$home/state" "$home/config" "$home/data" "$home/projects"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  new-window)
    name= previous=
    for arg in "$@"; do [ "$previous" = -n ] && name=$arg; previous=$arg; done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
esac
exit 0
SH
  printf 'printf "treehouse %%s\\n" "$*" >> "$FM_FAKE_CALL_LOG"\nexit 0\n' > "$fakebin/treehouse"
  # Lane probes: 64 cores, a fixed free disk, AC power.
  printf '#!/usr/bin/env bash\n[ "${1:-}" = _NPROCESSORS_ONLN ] && { echo 64; exit 0; }\nexit 1\n' > "$fakebin/getconf"
  cat > "$fakebin/df" <<SH
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 999999999 1 \$(cat "$case_dir/v/disk_kb" 2>/dev/null || echo 104857600) 1% /fake"
SH
  cat > "$fakebin/pmset" <<SH
#!/usr/bin/env bash
[ "\${2:-}" = batt ] && printf "Now drawing from '%s'\n" "\$(cat "$case_dir/v/power")"
exit 0
SH
  chmod +x "$fakebin"/*
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
    printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
  set_power "$case_dir" ac
  printf '%s\n' "$case_dir"
}


# set_power <case-dir> ac|battery: the power source both platforms' probes read.
set_power() {
  local ps="$1/sys/class/power_supply"
  mkdir -p "$ps/AC0" "$ps/BAT0"
  printf 'Mains\n' > "$ps/AC0/type"
  printf 'Battery\n' > "$ps/BAT0/type"
  printf '80\n' > "$ps/BAT0/capacity"
  if [ "$2" = ac ]; then
    printf '1\n' > "$ps/AC0/online"; printf 'Charging\n' > "$ps/BAT0/status"; printf 'AC Power\n' > "$1/v/power"
  else
    printf '0\n' > "$ps/AC0/online"; printf 'Discharging\n' > "$ps/BAT0/status"; printf 'Battery Power\n' > "$1/v/power"
  fi
}

# set_room <case-dir> <lanes>: write config/lane-capacity so memory, the
# binding resource here, has room for about <lanes> default 2 GB lanes (a 1 GB
# margin, so at least 1 while this host's memory moves between calls), or for
# none with the floor 5 GB above the reading. Fails the case when this host has
# too little memory for the room asked.
set_room() {
  local case_dir=$1 lanes=$2 avail kept
  avail=$(cat "$case_dir/avail")
  if [ "$lanes" -eq 0 ]; then kept=$((avail + 5)); else kept=$((avail - lanes * 2 - 1)); fi
  [ "$kept" -ge 0 ] || fail "this host has $avail GB available, too little for $lanes lanes of 2 GB"
  printf 'auto\nadmit-spawns\nmin-avail-gb %s\nmin-disk-gb 1\n' "$kept" > "$case_dir/home/config/lane-capacity"
}

# auto_config <case-dir> <lanes>: measure this host once, then set the room.
auto_config() {
  local avail
  mkdir -p "$1/probe-config-dir"
  printf 'auto\n' > "$1/probe-config-dir/lane-capacity"
  avail=$(probe_env "$1" env FM_HOME="$1/home" FM_CONFIG_OVERRIDE="$1/probe-config-dir" "$CAPACITY" --json 2>/dev/null |
    jq -r '.pressure.avail_gb // empty | floor')
  [ -n "$avail" ] || fail "this host's available memory cannot be read"
  printf '%s\n' "$avail" > "$1/avail"
  set_room "$1" "$2"
}

probe_env() {  # <case-dir> <command...>: run with this case's probes
  local case_dir=$1
  shift
  PATH="$case_dir/fakebin:$PATH" FM_SYS_ROOT_OVERRIDE="$case_dir/sys" "$@"
}

publish() {  # <case-dir>
  probe_env "$1" env FM_HOME="$1/home" FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 "$CAPACITY" --publish >/dev/null 2>&1
}

# assert_damped_publish <case-dir> <previous-free> <label>: the published
# verdict must be min(raw, previous + 2) with the raw budget at least 1, and
# the published free count is printed.
assert_damped_publish() {
  local raw free want
  raw=$(doc "$1" '.budget.raw')
  free=$(doc "$1" '.verdict.free_lanes')
  [ "$raw" -ge 1 ] || fail "$3: room was set but the raw budget is $raw: $(doc "$1" '[.budget, .verdict]')"
  want=$(( $2 + 2 ))
  [ "$raw" -lt "$want" ] && want=$raw
  assert_equals "$want" "$free" "$3: free lanes must be min(raw $raw, previous $2 + 2)"
  assert_equals "$([ "$free" -lt "$raw" ] && echo true || echo false)" "$(doc "$1" '.budget.damped')" "$3: damped must say whether growth was held back"
  printf '%s\n' "$free"
}

doc() {  # <case-dir> <jq-filter>: the published document
  jq -c "$2" "$1/home/state/lane-capacity.json"
}

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

spawn_ship() {  # <case-dir> <id> [pane-path]
  local case_dir=$1 id=$2 pane=${3:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  probe_env "$case_dir" env FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off 2>&1
}

assert_admitted() {  # <case-dir> <id> <rc> <out> <label>
  expect_code 0 "$3" "$5: $4"
  assert_contains "$4" "spawned $2" "$5 did not launch the worker"
  assert_present "$1/home/state/$2.meta" "$5 published no task record"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$1/home" "$2")" = in_flight ] || fail "$5 did not move $2 In flight"
  fi
}

assert_deferred() {  # <case-dir> <id> <rc> <out> <label>
  expect_code "$DEFER_EXIT" "$3" "$5: $4"
  assert_contains "$4" "deferred: lane capacity of this home" "$5 did not name the lane verdict"
  assert_contains "$4" "task $2 was not launched and its backlog item stays queued" "$5 did not keep the task queued"
  assert_absent "$1/home/state/$2.meta" "$5 published a task record"
  assert_absent "$1/home/state/.lane-admission.lock" "$5 left the admission lock held"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$1/home" "$2")" = queued ] || fail "$5 moved $2 out of Queued: $(row_state "$1/home" "$2")"
  fi
}

# --- A: spawn gate end to end -------------------------------------------------

# Admitted with room, deferred with exit 75 and the item still queued while a
# gate is closed, deferred again while the gate is clearing, and admitted
# once three clean publishes reopen it.
test_spawn_gate_end_to_end() {
  local c out rc i
  c=$(make_case gate task-a task-b)
  auto_config "$c" 3
  publish "$c"
  assert_equals '[true,true,"memory"]' "$(doc "$c" '[.verdict.admit, (.budget.raw >= 1), .budget.binding]')" \
    "room above the memory floor must publish an admitting budget bound by memory: $(doc "$c" '[.verdict, .budget.by]')"
  rc=0; out=$(spawn_ship "$c" task-a) || rc=$?
  assert_admitted "$c" task-a "$rc" "$out" "a spawn with room in the budget"
  set_power "$c" battery
  publish "$c"
  assert_equals '[false,["battery"]]' "$(doc "$c" '[.verdict.admit, [.gates[] | select(.state == "closed") | .name]]')" \
    "a host on battery must close the battery gate"
  rc=0; out=$(spawn_ship "$c" task-b "$c/unused") || rc=$?
  assert_deferred "$c" task-b "$rc" "$out" "a spawn while the battery gate is closed"
  assert_contains "$out" "battery" "the deferral must name the closed gate"
  set_power "$c" ac
  for i in 1 2; do
    publish "$c"
    assert_contains "$(doc "$c" '.verdict.reasons')" "clearing $i of 3" "the gate must count clean publishes"
    rc=0; out=$(spawn_ship "$c" task-b "$c/unused") || rc=$?
    assert_deferred "$c" task-b "$rc" "$out" "a spawn while the gate is clearing ($i of 3)"
  done
  publish "$c"
  assert_equals '[true,[]]' "$(doc "$c" '[.verdict.admit, [.gates[] | select(.state == "closed") | .name]]')" \
    "the third clean publish must reopen the gate"
  rc=0; out=$(spawn_ship "$c" task-b) || rc=$?
  assert_admitted "$c" task-b "$rc" "$out" "a spawn after the gate reopened"
  pass "a real spawn is admitted with room, deferred with exit 75 and its item queued while a gate is closed or clearing, and admitted after it reopens"
}

# Eight spawn requests inside one publish interval never exceed the damped
# budget, however much room the raw budget shows.
test_burst_of_spawns_never_exceeds_the_damped_budget() {
  local c out rc i admitted=0 deferred=0 published
  c=$(make_case burst t1 t2 t3 t4 t5 t6 t7 t8)
  auto_config "$c" 0
  publish "$c"
  assert_equals '[0,0]' "$(doc "$c" '[.verdict.free_lanes, .budget.raw]')" "a floor 5 GB above the live reading must publish no open lanes"
  set_room "$c" 3
  publish "$c"
  published=$(assert_damped_publish "$c" 0 "a recovery from 0 open")
  for i in 1 2 3 4 5 6 7 8; do
    rc=0; out=$(spawn_ship "$c" "t$i") || rc=$?
    case "$rc" in
      0) admitted=$((admitted + 1)) ;;
      "$DEFER_EXIT") deferred=$((deferred + 1))
        # Live memory may drift under the floor mid-burst, in which case memory, not damping, is what refuses.
        case "$out" in
          *"damped: $published lanes started since the last publish against a published budget of $published"*|*"memory: "*) ;;
          *) fail "a burst deferral must name the damped budget or memory: $out" ;;
        esac ;;
      *) fail "spawn t$i exited $rc: $out" ;;
    esac
  done
  assert_equals "$published $((8 - published))" "$admitted $deferred" "eight spawns in one interval must admit exactly the published damped $published"
  pass "eight spawns inside one publish interval admit exactly the damped budget ($published) and defer the rest"
}

# --- B: watcher publish cycle -------------------------------------------------

# wait_for_publish <case-dir> <after-epoch>: wait for a document newer than
# <after-epoch>, print its epoch, and age its file past the watcher's 30 s
# publish cadence so the next watcher poll publishes again.
wait_for_publish() {
  local i=0 e
  while [ "$i" -lt 200 ]; do
    e=$(jq -r '.generated_epoch // 0' "$1/home/state/lane-capacity.json" 2>/dev/null) || e=0
    if [ "${e:-0}" -gt "$2" ]; then
      # Age the document past the watcher's 30 s cadence so its next poll publishes again.
      fm_touch_epoch "$(( $(date +%s) - 31 ))" "$1/home/state/lane-capacity.json"
      printf '%s\n' "$e"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The real watcher publishes the verdict, growth after a recovery is damped
# across two of its publishes, and the next spawn reads what it published.
test_watcher_publish_cycle_feeds_the_next_spawn() {
  local c h e1 e2 e3 rc out f2 f3
  c=$(make_case watch task-w task-x task-y task-z)
  h="$c/home"
  auto_config "$c" 0
  fm_test_track_watcher_state "$h/state"
  probe_env "$c" env FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_CONFIG_OVERRIDE="$h/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_LANE_CAPACITY_PUBLISH_INTERVAL=1 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1 &
  e1=$(wait_for_publish "$c" 0) || fail "the watcher never published the lane verdict"
  assert_equals '[0,0,"memory"]' "$(doc "$c" '[.verdict.free_lanes, .budget.raw, .budget.binding]')" \
    "a floor 5 GB above the live reading must publish no open lanes"
  set_room "$c" 4
  e2=$(wait_for_publish "$c" "$e1") || fail "the watcher did not publish again"
  # One more publish may land at the old config before the change is seen.
  if [ "$(doc "$c" '.budget.raw')" = 0 ]; then e2=$(wait_for_publish "$c" "$e2") || fail "no publish after the change"; fi
  f2=$(assert_damped_publish "$c" 0 "the first watcher publish after recovery")
  e3=$(wait_for_publish "$c" "$e2") || fail "the watcher did not publish a third time"
  f3=$(assert_damped_publish "$c" "$f2" "the next watcher publish")
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  rc=0; out=$(spawn_ship "$c" task-w) || rc=$?
  assert_admitted "$c" task-w "$rc" "$out" "a spawn after the watcher published $f3 open lanes"
  pass "the real watcher publishes the verdict, damps growth by 2 per publish ($f2 then $f3 open), and the next spawn is admitted on it ($e1 -> $e2 -> $e3)"
}

# --- C: idle reclaim from real workers ----------------------------------------

# A real idle worker (sleep) and a busy one (a CPU loop) in their own
# worktrees: the idle one is ranked for reclaim with its age, the busy one is
# not, and nothing is stopped.
test_idle_reclaim_from_real_workers() {
  local c h now idle_pid busy_pid out report
  c=$(make_case reclaim)
  h="$c/home"
  auto_config "$c" 2
  mkdir -p "$c/wt-idle" "$c/wt-busy"
  now=$(date +%s)
  for id in idle busy; do
    fm_write_meta "$h/state/$id.meta" "kind=ship" "harness=codex" "worktree=$c/wt-$id" "spawn_gen=s$((now - 7200)).1.1"
    printf 'done [at=%s]: finished its task\n' "$((now - 3600))" > "$h/state/$id.status"
  done
  ( cd "$c/wt-idle" && exec sleep 300 ) &
  idle_pid=$!
  ( cd "$c/wt-busy" && exec bash -c 'while :; do :; done' ) &
  busy_pid=$!
  BG_PIDS="$idle_pid $busy_pid"
  # A ledger last sampled 30 s ago that has seen both lanes quiet for an hour.
  jq -n --argjson now "$now" '{schema: "fm-lane-footprint.v1", history: [],
    lanes: ({} | .idle = {first_seen: ($now - 7200), last_seen: ($now - 30), samples: 5, procs: 1, peak_procs: 1,
      mem_gb: 0.1, peak_mem_gb: 0.1, mem_sum_gb: 0.5, cpu_cores: 0, peak_cpu_cores: 0, cpu_sum: 0, cpu_n: 5,
      quiet_since: ($now - 3600), noagent_since: null, disk_gb: null, disk_epoch: null, pids: {}}
      | .busy = .idle)}' > "$h/state/lane-footprint.json"
  sleep 2
  publish "$c"
  assert_equals '[{"id":"idle","class":"finished","next":"cleanup"}]' \
    "$(doc "$c" '[.reclaim[] | {id, class, next}]')" "only the idle worker's lane may be ranked for reclaim"
  assert_equals true "$(doc "$c" '.reclaim[0].idle_s >= 3600')" "the reclaim entry must carry the idle age"
  assert_equals '[1,1]' "$(jq -c '[.lanes.idle.procs, .lanes.busy.procs]' "$h/state/lane-footprint.json")" \
    "each real worker must be attributed to its own lane"
  report=$(probe_env "$c" env FM_HOME="$h" "$CAPACITY" 2>&1)
  assert_contains "$report" "  - idle: finished, idle 1h, next cleanup (status:done 1h, procs:1" "the report must name the idle lane with its age"
  assert_not_contains "$report" "  - busy:" "the report must not list the busy lane"
  kill -0 "$idle_pid" 2>/dev/null || fail "reclaim stopped the idle worker"
  kill -0 "$busy_pid" 2>/dev/null || fail "reclaim stopped the busy worker"
  out=$(printf '%s\n' "$report" | grep -- '  - idle:' | head -1)
  cleanup_workers
  pass "a real idle worker is ranked finished -> cleanup with its age, a busy one is not, and neither is stopped (${out:-reclaim line})"
}

# --- E: the fixed-cap path is byte-identical to the baseline ------------------

BASELINE_REF_DEFAULT=5c935cfbaf8a649ccc3656c1cdabd23fe1fcc0b9

baseline_bin() {  # -> a directory holding the baseline revision's bin/
  local ref=${FM_LANE_CAPACITY_BASELINE_REF:-$BASELINE_REF_DEFAULT} dir="$TMP_ROOT/baseline"
  git -C "$ROOT" cat-file -e "$ref^{commit}" 2>/dev/null || return 1
  mkdir -p "$dir"
  git -C "$ROOT" archive "$ref" bin 2>/dev/null | tar -C "$dir" -xf - 2>/dev/null || return 1
  [ -x "$dir/bin/fm-capacity.sh" ] || return 1
  printf '%s\t%s\n' "$dir/bin" "$ref"
}

# Darwin-shaped fake probes, so both revisions read exactly the same host.
static_probes() {  # <dir> -> fakebin
  local fakebin
  fakebin=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$fakebin/uname"
  cat > "$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
case "$2" in
  vm.loadavg) echo "{ 6.50 5.00 4.00 }" ;;
  kern.memorystatus_level) echo 41 ;;
  hw.logicalcpu) echo 18 ;;
  hw.memsize) echo 51539607552 ;;
  kern.memorystatus_vm_pressure_level) echo 1 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/getconf"
  printf '#!/usr/bin/env bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/fake 999999999 1 209715200 1%% /fake"\n' > "$fakebin/df"
  printf '#!/usr/bin/env bash\n[ "${2:-}" = batt ] && echo "Now drawing from '"'"'AC Power'"'"'"\nexit 0\n' > "$fakebin/pmset"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/ioreg"
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

test_fixed_cap_output_matches_the_baseline() {
  local base ref home fakebin now mode a b
  if ! base=$(baseline_bin); then
    printf 'skip: fixed-cap baseline: revision %s is not in this history (set FM_LANE_CAPACITY_BASELINE_REF)\n' "${FM_LANE_CAPACITY_BASELINE_REF:-$BASELINE_REF_DEFAULT}"
    return 0
  fi
  ref=${base#*	} base=${base%%	*}
  home="$TMP_ROOT/static/home"
  mkdir -p "$home/state" "$home/config"
  now=$(date +%s)
  for id in s1 s2 s3; do
    fm_write_meta "$home/state/$id.meta" "kind=ship" "harness=codex" "worktree=$home/wt-$id" "spawn_gen=s$((now - 4000)).1.1"
  done
  fakebin=$(static_probes "$TMP_ROOT/static")
  # A cap with room under its floors, then a full cap whose memory floor is also breached.
  for cfg in '14\nmin-avail-gb 4\nmin-disk-gb 20\nmax-load1 24\n' '2\nmin-avail-gb 30\nmin-disk-gb 250\nmax-load1 6\n'; do
    printf '%b' "$cfg" > "$home/config/lane-capacity"
    for mode in report --json --admit; do
      if [ "$mode" = report ]; then set --; else set -- "$mode"; fi
      a=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$base/fm-capacity.sh" "$@" 2>&1; echo "exit=$?")
      b=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CAPACITY" "$@" 2>&1; echo "exit=$?")
      a=$(printf '%s\n' "$a" | sed -E 's/"generated_epoch": ?[0-9]+/"generated_epoch":0/')
      b=$(printf '%s\n' "$b" | sed -E 's/"generated_epoch": ?[0-9]+/"generated_epoch":0/')
      [ "$a" = "$b" ] || fail "fixed-cap $mode output differs from $ref: $(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -20)"
    done
  done
  assert_contains "$b" "exit=75" "the breached fixed cap must still refuse admission"
  pass "fixed caps with room and over their floors print byte-identical report, document, and admission output to ${ref:0:12}"
}

# --- F: live load on this host (opt-in) ---------------------------------------

live_line() {  # <phase> <case-dir>
  local line
  line=$(jq -c --arg phase "$1" --argjson t "$(date +%s)" '{t: $t, phase: $phase, admit: .verdict.admit,
    free: .verdict.free_lanes, reasons: .verdict.reasons, by: .budget.by, raw: .budget.raw, damped: .budget.damped,
    gates: [.gates[] | select(.state != "open") | "\(.name)=\(.state)"], load5: .vitals.load5}' "$2/home/state/lane-capacity.json")
  printf '%s\n' "$line"
  [ -z "${FM_TEST_LANE_LIVE_LOG:-}" ] || printf '%s\n' "$line" >> "$FM_TEST_LANE_LIVE_LOG"
}

live_publish() {  # <case-dir>: real probes, no fakes
  FM_HOME="$1/home" FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 "$CAPACITY" --publish >/dev/null 2>&1
}

live_spawn() {  # <case-dir> <id> [pane]
  local case_dir=$1 id=$2 pane=${3:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  PATH="$case_dir/fakebin-spawn:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off 2>&1
}

# Real CPU load closes admission through the real probes, a real spawn is
# deferred, and admission returns after the load stops and the gate clears.
test_live_load_shrinks_and_recovers() {
  local c h cores n i rc out t0 t_stop rest_cpu t_shrink='' t_closed='' t_gate='' t_clear='' t_open='' hog=
  c=$(make_case live live-a live-b live-c)
  h="$c/home"
  # Only the terminal and worktree tool are faked for the spawn; every probe is real.
  mkdir -p "$c/fakebin-spawn"
  cp "$c/fakebin/tmux" "$c/fakebin/treehouse" "$c/fakebin/gh" "$c/fakebin/gh-axi" "$c/fakebin/no-mistakes" "$c/fakebin-spawn/"
  printf 'auto\nadmit-spawns\nmin-avail-gb 2\nmin-disk-gb 1\n' > "$h/config/lane-capacity"
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu)
  n=$((cores * 2 + 2))
  t0=$(date +%s)
  live_publish "$c"; live_line rest "$c"
  rest_cpu=$(doc "$c" '.budget.by.cpu // 0')
  rc=0; out=$(live_spawn "$c" live-a) || rc=$?
  assert_admitted "$c" live-a "$rc" "$out" "a live spawn at rest"
  i=0
  while [ "$i" -lt "$n" ]; do nice -n 19 bash -c 'while :; do :; done' & BG_PIDS="$BG_PIDS $!"; i=$((i + 1)); done
  if [ "${FM_TEST_LANE_LIVE_MEM_GB:-0}" != 0 ] && command -v python3 >/dev/null 2>&1; then
    python3 -c "import time; b = bytearray(int(${FM_TEST_LANE_LIVE_MEM_GB} * (1 << 30))); b[::4096] = b'x' * len(b[::4096]); time.sleep(900)" &
    hog=$!; BG_PIDS="$BG_PIDS $hog"
  fi
  i=0
  while [ "$i" -lt 60 ]; do
    sleep 5; live_publish "$c"; live_line load "$c"
    [ -n "$t_shrink" ] || [ "$(doc "$c" '.budget.by.cpu // 0')" -ge "$rest_cpu" ] || t_shrink=$(date +%s)
    [ -n "$t_closed" ] || [ "$(doc "$c" '.verdict.admit')" = true ] || t_closed=$(date +%s)
    if [ "$(doc "$c" '[.gates[] | select(.name == "cpu" and .state == "closed")] | length')" = 1 ]; then t_gate=$(date +%s); break; fi
    i=$((i + 1))
  done
  [ -n "$t_closed" ] || fail "five minutes of load on $cores cores never closed admission"
  [ -n "$t_gate" ] || fail "five minutes of load on $cores cores never closed the cpu gate"
  rc=0; out=$(live_spawn "$c" live-b "$c/unused") || rc=$?
  assert_deferred "$c" live-b "$rc" "$out" "a live spawn under load"
  cleanup_workers
  t_stop=$(date +%s)
  i=0
  while [ "$i" -lt 90 ]; do
    sleep 5; live_publish "$c"; live_line recovery "$c"
    [ -n "$t_clear" ] || ! doc "$c" '.verdict.reasons' | grep -q 'clearing 1 of 3' || t_clear=$(date +%s)
    if [ "$(doc "$c" '.verdict.admit')" = true ]; then t_open=$(date +%s); break; fi
    i=$((i + 1))
  done
  [ -n "$t_open" ] || fail "admission did not return within 7.5 minutes of the load stopping"
  [ -n "$t_clear" ] || fail "the cpu gate reopened without counting clean publishes"
  rc=0; out=$(live_spawn "$c" live-b) || rc=$?
  assert_admitted "$c" live-b "$rc" "$out" "a live spawn after recovery"
  pass "live load on $cores cores ($n busy loops${hog:+, memory hog}): cpu budget shrank at +$(( ${t_shrink:-$t_closed} - t0 )) s, admission closed at +$((t_closed - t0)) s, the cpu gate closed at +$((t_gate - t0)) s and a real spawn was deferred; after the load stopped the gate began clearing at +$((t_clear - t_stop)) s and admission returned at +$((t_open - t_stop)) s"
}

test_spawn_gate_end_to_end
test_burst_of_spawns_never_exceeds_the_damped_budget
test_watcher_publish_cycle_feeds_the_next_spawn
test_idle_reclaim_from_real_workers
test_fixed_cap_output_matches_the_baseline
if [ "${FM_TEST_LANE_LIVE_LOAD:-${FM_LIVE:-0}}" = 1 ]; then
  test_live_load_shrinks_and_recovers
else
  printf 'skip: live load: opt-in; set FM_TEST_LANE_LIVE_LOAD=1 to run\n'
fi
