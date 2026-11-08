#!/usr/bin/env bash
# Behavioral coverage for bin/fm-capacity.sh's auto budget (first line `auto`
# in config/lane-capacity), driven through the CLI with faked probes: fixed
# mode left byte-for-byte alone, the budget bound by the scarcest of memory,
# cpu, disk, and the optional max-lanes ceiling, young lanes reserving a full
# per-lane cost, gates that close at once and reopen only after three clean
# publishes with damped growth, pressure, thermal, and battery gates, the
# unmeasurable fallback, learned and pinned footprints, the published ledger
# and its history, the ranked reclaim list, the WSL Windows host view and its
# cache, the opt-in spawn gate, config validation, and a real-host smoke.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-capacity-auto)
CAPACITY="$ROOT/bin/fm-capacity.sh"
GIB=1073741824

make_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# make_probes <dir>: fake Darwin probes whose values live in <dir>/v/<name>
# files, so a case can change one reading between calls. A missing value file
# makes that probe print nothing, which the script reads as unknown.
make_probes() {
  local dir=$1 fakebin v
  fakebin=$(fm_fakebin "$dir")
  v="$dir/v"
  mkdir -p "$v"
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$fakebin/uname"
  cat > "$fakebin/sysctl" <<SH
#!/usr/bin/env bash
r() { [ -f "$v/\$1" ] && cat "$v/\$1"; }
case "\$2" in
  vm.loadavg) [ -f "$v/load1" ] && echo "{ \$(r load1) \$(r load5) 1.00 }" ;;
  kern.memorystatus_level) r memlevel ;;
  hw.logicalcpu) r cores ;;
  hw.memsize) r memsize ;;
  kern.memorystatus_vm_pressure_level) r vmpress ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/getconf"
  cat > "$fakebin/df" <<SH
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 999999999 1 \$(cat "$v/disk_kb") 1% /fake"
SH
  cat > "$fakebin/vm_stat" <<SH
#!/usr/bin/env bash
[ -f "$v/swapins" ] && printf 'Swapins: %s.\n' "\$(cat "$v/swapins")"
exit 0
SH
  cat > "$fakebin/pmset" <<SH
#!/usr/bin/env bash
case "\$2" in
  batt) [ -f "$v/power" ] && printf "Now drawing from '%s'\n" "\$(cat "$v/power")" ;;
  therm) printf 'Note: No thermal warning level has been recorded\n'
    [ -f "$v/speed" ] && printf 'CPU_Speed_Limit = %s\n' "\$(cat "$v/speed")" ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/ioreg"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
[ -f "$v/ps" ] && cat "$v/ps"
exit 0
SH
  cat > "$fakebin/lsof" <<SH
#!/usr/bin/env bash
[ -f "$v/lsof" ] && cat "$v/lsof"
exit 0
SH
  cat > "$fakebin/du" <<SH
#!/usr/bin/env bash
printf '%s\t%s\n' "\$(cat "$v/du_kb" 2>/dev/null || echo 1048576)" "\$2"
SH
  chmod +x "$fakebin"/*
  # A healthy 16 GB, 8-core laptop on AC with 100 GB free.
  printf '1.00\n' > "$v/load1"
  printf '1.00\n' > "$v/load5"
  printf '50\n' > "$v/memlevel"
  printf '8\n' > "$v/cores"
  printf '%s\n' $((16 * GIB)) > "$v/memsize"
  printf '1\n' > "$v/vmpress"
  printf '104857600\n' > "$v/disk_kb"
  printf 'AC Power\n' > "$v/power"
  printf '%s\n' "$fakebin"
}

set_v() {  # <probe-dir> <name> <value>
  printf '%s\n' "$3" > "$1/v/$2"
}

run_cap() {  # <home> <fakebin> [args...]
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 "$CAPACITY" "$@" 2>&1
}

json() {  # <home> <fakebin> <jq-filter>
  PATH="$2:$BASE_PATH" FM_HOME="$1" "$CAPACITY" --json 2>/dev/null | jq -c "$3"
}

iso_at() {  # <epoch> -> YYYY-MM-DDTHH:MMZ
  date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ
}

write_lane() {  # <home> <id> <worktree> [extra-line...]
  local home=$1 id=$2 wt=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" "kind=ship" "harness=codex" "worktree=$wt" \
    "spawn_gen=s$(( $(date +%s) - 3600 )).1.1" "$@"
}

test_fixed_mode_is_unchanged() {
  local home fakebin out
  home=$(make_home fixed)
  fakebin=$(make_probes "$TMP_ROOT/p-fixed")
  printf '4\n' > "$home/config/lane-capacity"
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$(printf '%s\n' "$out" | head -1)" 'capacity: free_lanes=4 reason=ok lanes=0 target=4 ' "fixed mode must keep its verdict"
  assert_not_contains "$out" 'mode=' "fixed mode must not print the auto keys"
  assert_equals '[false,false,false,false]' "$(json "$home" "$fakebin" '[has("budget"), (.cap | has("mode")), has("gates"), has("reclaim")]')" \
    "the fixed-mode document must not gain auto fields"
  pass "an integer first line keeps fixed mode and its document unchanged"
}

test_budget_binds_the_scarcest_resource() {
  local home fakebin p out rc
  home=$(make_home budget)
  p="$TMP_ROOT/p-budget"
  fakebin=$(make_probes "$p")
  printf 'auto\n' > "$home/config/lane-capacity"
  out=$(run_cap "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "an auto report"
  assert_contains "$(printf '%s\n' "$out" | head -1)" 'capacity: free_lanes=3 reason=ok lanes=0 target=none ' "memory must bind at 3"
  assert_contains "$(printf '%s\n' "$out" | head -1)" ' mode=auto budget=3' "the report line must end with the auto keys"
  assert_contains "$out" 'auto budget 3 (3 open, bound by memory)' "the summary must name the binding resource"
  assert_contains "$out" 'Per lane: 2 GB, 1 core, 3 GB disk (default until 5 lanes are measured).' "the default footprint must be stated"
  assert_equals '{"memory":3,"cpu":5,"disk":30,"ceiling":null}' "$(json "$home" "$fakebin" '.budget.by')" "every resource must be computed"
  assert_equals '["none","auto"]' "$(json "$home" "$fakebin" '[.cap.status, .cap.mode]')" "auto without a ceiling has no cap target"
  set_v "$p" load1 6.50
  set_v "$p" load5 6.00
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=cpu ' "cpu must bind when the run queue fills"
  set_v "$p" load1 1.00
  set_v "$p" load5 1.00
  set_v "$p" disk_kb 12582912
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=disk ' "disk must bind under its floor"
  printf 'auto\nmin-disk-gb 20\n' > "$home/config/lane-capacity"
  assert_equals 1 "$(json "$home" "$fakebin" '[.verdict.reasons[] | select(startswith("disk"))] | length')" "the budget must state a disk shortfall once, not also as a fixed-mode floor"
  set_v "$p" disk_kb 104857600
  printf 'auto\nmin-avail-gb 7\n' > "$home/config/lane-capacity"
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=memory ' "min-avail-gb must be the memory floor"
  assert_contains "$out" 'Constrained: memory - hold new dispatch until it clears.' "a closed budget must print the hold line"
  rc=0
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$CAPACITY" --admit 2>&1) || rc=$?
  expect_code 75 "$rc" "--admit on a full budget"
  assert_contains "$out" 'memory: 8 GB available, 7 GB kept, 0 starting, a lane needs 2 GB' "the deferral must explain the memory arithmetic"
  pass "the auto budget is the smallest of memory, cpu, and disk, each after its floor"
}

test_ceiling_and_young_lanes() {
  local home fakebin out now
  home=$(make_home young)
  fakebin=$(make_probes "$TMP_ROOT/p-young")
  now=$(date +%s)
  printf 'auto\nmax-lanes 2\n' > "$home/config/lane-capacity"
  write_lane "$home" old-lane "$home/none"
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=1 reason=ok lanes=1 target=2 ' "the ceiling must bind at one open lane"
  fm_write_meta "$home/state/new-lane.meta" "kind=scout" "harness=claude" "spawn_gen=s$now.1.1"
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=ceiling lanes=2 target=2 ' "a full ceiling must close admission"
  assert_equals '["ceiling: 2 of 2 lanes on this machine (max-lanes)"]' "$(json "$home" "$fakebin" '.verdict.reasons')" \
    "the ceiling reason must count this machine's lanes"
  assert_equals '[1,2,4]' "$(json "$home" "$fakebin" '[.budget.young, .budget.by.memory, .budget.by.cpu]')" \
    "a young lane must reserve a full memory and cpu cost"
  pass "max-lanes is an optional ceiling and a young lane reserves a full lane"
}

test_gates_reopen_after_three_publishes() {
  local home fakebin p i
  home=$(make_home gates)
  p="$TMP_ROOT/p-gates"
  fakebin=$(make_probes "$p")
  printf 'auto\n' > "$home/config/lane-capacity"
  set_v "$p" memlevel 90
  set_v "$p" load1 9.00
  run_cap "$home" "$fakebin" --publish >/dev/null
  assert_equals '["closed",0,false]' "$(jq -c '[(.gates[] | select(.name == "cpu") | .state), .verdict.free_lanes, .verdict.admit]' "$home/state/lane-capacity.json")" \
    "an overloaded run queue must close the cpu gate at once"
  set_v "$p" load1 1.00
  for i in 1 2; do
    run_cap "$home" "$fakebin" --publish >/dev/null
    assert_equals "[\"closed\",$i]" "$(jq -c '[.gates[] | select(.name == "cpu") | .state, .clear_count]' "$home/state/lane-capacity.json")" \
      "the cpu gate must stay closed through clean publish $i"
    assert_contains "$(jq -r '.verdict.reasons[]' "$home/state/lane-capacity.json")" "(clearing $i of 3)" "the reason must show the reopen count"
  done
  run_cap "$home" "$fakebin" --publish >/dev/null
  assert_equals '["open",2,5,true]' "$(jq -c '[(.gates[] | select(.name == "cpu") | .state), .verdict.free_lanes, .budget.raw, .budget.damped]' "$home/state/lane-capacity.json")" \
    "the third clean publish must reopen with growth damped to 2"
  run_cap "$home" "$fakebin" --publish >/dev/null
  assert_equals '[4,true]' "$(jq -c '[.verdict.free_lanes, .budget.damped]' "$home/state/lane-capacity.json")" "growth must stay damped to 2 per publish"
  run_cap "$home" "$fakebin" --publish >/dev/null
  assert_equals '[5,false]' "$(jq -c '[.verdict.free_lanes, .budget.damped]' "$home/state/lane-capacity.json")" "damping must end at the raw budget"
  set_v "$p" load1 9.00
  run_cap "$home" "$fakebin" --publish >/dev/null
  assert_equals '0' "$(jq -c '.verdict.free_lanes' "$home/state/lane-capacity.json")" "a gate must close again at once"
  pass "gates close at once, reopen after three clean publishes, and growth is damped"
}

test_pressure_thermal_and_battery_gates() {
  local home fakebin p out
  home=$(make_home pressure)
  p="$TMP_ROOT/p-pressure"
  fakebin=$(make_probes "$p")
  printf 'auto\n' > "$home/config/lane-capacity"
  set_v "$p" vmpress 2
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=memory-pressure ' "macOS vm pressure warn must close admission"
  set_v "$p" vmpress 1
  set_v "$p" speed 70
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'reason=thermal ' "a CPU speed limit must close admission"
  rm -f "$p/v/speed"
  set_v "$p" power 'Battery Power'
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'reason=battery ' "running on battery must close admission"
  printf 'auto\nallow-battery\n' > "$home/config/lane-capacity"
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=3 reason=ok ' "allow-battery must admit on battery"
  assert_equals 'false' "$(json "$home" "$fakebin" '[.gates[].name] | index("battery") != null')" "allow-battery must drop the battery gate"
  pass "memory-pressure, thermal, and battery gates close admission, and allow-battery opts out"
}

test_unmeasurable_vitals() {
  local home fakebin p out
  home=$(make_home unmeasurable)
  p="$TMP_ROOT/p-unmeasurable"
  fakebin=$(make_probes "$p")
  rm -f "$p/v/load1" "$p/v/memlevel" "$p/v/cores" "$p/v/vmpress" "$p/v/power"
  printf 'auto\n' > "$home/config/lane-capacity"
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=unmeasurable ' "auto mode must not guess without memory or cpu"
  printf 'auto\nmax-lanes 3\n' > "$home/config/lane-capacity"
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=3 reason=ok ' "an unmeasurable host must fall back to the ceiling"
  assert_equals '"ceiling"' "$(json "$home" "$fakebin" '.budget.binding')" "the fallback must be bound by the ceiling"
  pass "unmeasurable vitals admit only up to max-lanes, and nothing without it"
}

test_learned_and_pinned_footprint() {
  local home fakebin out
  home=$(make_home learned)
  fakebin=$(make_probes "$TMP_ROOT/p-learned")
  printf 'auto\n' > "$home/config/lane-capacity"
  jq -n '{schema: "fm-lane-footprint.v1", generated_epoch: 1, lanes: {},
    history: ([4, 4, 3, 5, 6] | map({harness: "codex", kind: "ship", peak_mem_gb: ., mean_mem_gb: 1,
      mean_cpu_cores: 0.4, disk_gb: 2, lifetime_s: 100, ended_epoch: 1}))}' > "$home/state/lane-footprint.json"
  assert_equals '[6,0.4,2,"learned",5,1]' \
    "$(json "$home" "$fakebin" '[.footprint.mem_gb, .footprint.cpu_cores, .footprint.disk_gb, .footprint.source, .footprint.samples, .budget.by.memory]')" \
    "five recorded lanes must give the p90 footprint"
  printf 'auto\nlane-footprint-gb 1.5\nlane-disk-gb 9\n' > "$home/config/lane-capacity"
  out=$(json "$home" "$fakebin" '[.footprint.mem_gb, .footprint.disk_gb, .footprint.source, .budget.by.memory, .budget.by.disk]')
  assert_equals '[1.5,9,"pinned",4,10]' "$out" "pinned costs must override the learned ones"
  pass "the per-lane footprint is learned at p90 after five lanes, and pins override it"
}

test_publish_writes_ledger_and_history() {
  local home fakebin p wt now
  home=$(make_home ledger)
  p="$TMP_ROOT/p-ledger"
  fakebin=$(make_probes "$p")
  wt="$home/wt-a"
  mkdir -p "$wt"
  printf 'auto\n' > "$home/config/lane-capacity"
  write_lane "$home" lane-a "$wt"
  printf '  500     1 1048576   0:10.00\n' > "$p/v/ps"
  printf 'p500\nfcwd\nn%s\n' "$wt" > "$p/v/lsof"
  set_v "$p" du_kb 2097152
  run_cap "$home" "$fakebin" --publish >/dev/null
  assert_present "$home/state/lane-footprint.json" "auto --publish must write the footprint ledger"
  case "$(ls -l "$home/state/lane-footprint.json")" in -rw-------*) ;; *) fail "the ledger must be mode 0600" ;; esac
  assert_equals '[1,1,1,2,null]' "$(jq -c '.lanes["lane-a"] | [.samples, .procs, .mem_gb, .disk_gb, .cpu_cores]' "$home/state/lane-footprint.json")" \
    "the first sample must record memory, processes, and disk"
  now=$(date +%s)
  jq --argjson t $((now - 10)) '.lanes["lane-a"].last_seen = $t' "$home/state/lane-footprint.json" > "$home/l.tmp" && mv "$home/l.tmp" "$home/state/lane-footprint.json"
  printf '  500     1 2097152   0:20.00\n' > "$p/v/ps"
  run_cap "$home" "$fakebin" --publish >/dev/null
  # Ten CPU seconds over the ten-to-twelve wall seconds since the backdated sample.
  assert_equals '[2,2,2,true]' "$(jq -c '.lanes["lane-a"] | [.samples, .mem_gb, .peak_mem_gb, (.cpu_cores >= 0.8 and .cpu_cores <= 1)]' "$home/state/lane-footprint.json")" \
    "the second sample must record CPU from the pid's time delta"
  printf '' > "$p/v/lsof"
  run_cap "$home" "$fakebin" --publish >/dev/null
  assert_equals '[2,1,2]' "$(jq -c '.lanes["lane-a"] | [.samples, .procs, .mem_gb]' "$home/state/lane-footprint.json")" \
    "an unreadable process table must keep the last sample, not record a lane with no processes"
  assert_contains "$(jq -r '.budget.notes[]' "$home/state/lane-capacity.json")" 'process attribution unavailable' "the gap must be noted"
  rm -f "$home/state/lane-a.meta"
  run_cap "$home" "$fakebin" --publish >/dev/null
  assert_equals '[{},1,2,2]' "$(jq -c '[.lanes, (.history | length), .history[0].peak_mem_gb, .history[0].disk_gb]' "$home/state/lane-footprint.json")" \
    "a lane that left state/ must move into the history"
  pass "auto --publish keeps a 0600 footprint ledger and moves finished lanes into its history"
}

test_reclaim_ranks_idle_lanes() {
  local home fakebin p now out
  home=$(make_home reclaim)
  p="$TMP_ROOT/p-reclaim"
  fakebin=$(make_probes "$p")
  now=$(date +%s)
  printf 'auto\n' > "$home/config/lane-capacity"
  mkdir -p "$home/wt-fin" "$home/wt-gone" "$home/wt-pr" "$home/wt-park" "$home/wt-busy"
  write_lane "$home" fin "$home/wt-fin"
  write_lane "$home" gone "$home/wt-gone"
  write_lane "$home" pr "$home/wt-pr" "pr=https://example.invalid/pull/1"
  write_lane "$home" park "$home/wt-park"
  write_lane "$home" busy "$home/wt-busy"
  printf 'done [at=%s]: finished\n' $((now - 3600)) > "$home/state/fin.status"
  printf 'paused [at=%s]: waiting until %s for review\n' $((now - 60)) "$(iso_at $((now + 10800)))" > "$home/state/park.status"
  printf '  600     1 409600   0:05.00\n  700     1 204800   0:05.00\n  800     1 102400   0:50.00\n' > "$p/v/ps"
  printf 'p600\nfcwd\nn%s\np700\nfcwd\nn%s\np800\nfcwd\nn%s\n' "$home/wt-pr" "$home/wt-park" "$home/wt-busy" > "$p/v/lsof"
  jq -n --argjson now "$now" '
    def lane($extra): {harness: "codex", kind: "ship", first_seen: ($now - 7200), last_seen: ($now - 30), samples: 50,
      procs: 1, mem_gb: 0.1, peak_mem_gb: 0.4, mem_sum_gb: 5, cpu_cores: 0, peak_cpu_cores: 0, cpu_sum: 0, cpu_n: 49,
      quiet_since: null, noagent_since: null, disk_gb: null, disk_epoch: null, pids: {}} + $extra;
    {schema: "fm-lane-footprint.v1", generated_epoch: ($now - 30), history: [], lanes: {
      fin: lane({procs: 0, mem_gb: 0, noagent_since: ($now - 1200)}),
      gone: lane({procs: 0, mem_gb: 0, noagent_since: ($now - 1200)}),
      pr: lane({quiet_since: ($now - 2400), pids: {"600": 5}}),
      park: lane({quiet_since: ($now - 2400), pids: {"700": 5}}),
      busy: lane({pids: {"800": 20}})}}' > "$home/state/lane-footprint.json"
  out=$(json "$home" "$fakebin" '.reclaim | map([.id, .class, .next])')
  assert_equals '[["fin","finished","cleanup"],["gone","no-agent","recover"],["pr","handed-off","retire-pane"],["park","parked","review"]]' "$out" \
    "the reclaim list must rank finished, no-agent, handed-off, and parked lanes, and skip a busy one"
  assert_contains "$(json "$home" "$fakebin" '.reclaim[2].evidence | join(" ")')" 'pr:recorded' "a handed-off lane must cite its recorded PR"
  out=$(run_cap "$home" "$fakebin")
  assert_contains "$out" 'Reclaim: 4 (finished 1, handed-off 1, no-agent 1, parked 1), 0.59 GB held.' "the report must summarize the reclaim list"
  assert_present "$home/state/fin.meta" "the reclaim list must never remove a lane"
  pass "idle lanes are ranked for reclaim with their evidence, and nothing is removed"
}

test_wsl_host_view_closes_admission() {
  local home fakebin proc out
  home=$(make_home wsl)
  fakebin=$(fm_fakebin "$TMP_ROOT/p-wsl")
  proc="$TMP_ROOT/p-wsl/proc"
  mkdir -p "$proc"
  printf '0.50 0.60 0.70 1/100 9\n' > "$proc/loadavg"
  printf 'MemTotal: 25165824 kB\nMemAvailable: 15728640 kB\n' > "$proc/meminfo"
  printf 'Linux version 6.18.54.1-microsoft-standard-WSL2\n' > "$proc/version"
  printf '#!/usr/bin/env bash\necho Linux\n' > "$fakebin/uname"
  cat > "$fakebin/getconf" <<'SH'
#!/usr/bin/env bash
case "$1" in _NPROCESSORS_ONLN) echo 16 ;; CLK_TCK) echo 100 ;; PAGESIZE) echo 4096 ;; *) exit 1 ;; esac
SH
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sdc 999999999 1 104857600 1% /"
SH
  printf '#!/usr/bin/env bash\nprintf "2135 32614400 88 51\\r\\n"\n' > "$fakebin/powershell.exe"
  chmod +x "$fakebin"/*
  printf 'auto\n' > "$home/config/lane-capacity"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$proc" "$CAPACITY" 2>&1)
  assert_contains "$out" 'free_lanes=0 reason=host-memory ' "a starved Windows host must close admission while WSL has room"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$proc" "$CAPACITY" --json 2>/dev/null |
    jq -c '[.vitals.wsl.avail_gb, .vitals.wsl.commit_pct, .budget.by.memory, .budget.by.cpu]')
  assert_equals '[2.08,88,6,5]' "$out" "WSL memory must decide the budget, with the Windows CPU share in the load"
  printf '#!/usr/bin/env bash\nprintf "20480 32614400 60 10\\r\\n"\n' > "$fakebin/powershell.exe"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$proc" FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 "$CAPACITY" --publish >/dev/null 2>&1
  assert_present "$home/state/.lane-vitals-host" "--publish must cache the Windows host view"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/powershell.exe"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$proc" "$CAPACITY" --json 2>/dev/null | jq -c '[.vitals.wsl.avail_gb, .verdict.admit]')
  assert_equals '[20,true]' "$out" "a fresh cached host view must stand in for a failed query"
  rm -f "$home/state/.lane-vitals-host" "$home/state/lane-capacity.json"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_PROC_ROOT_OVERRIDE="$proc" "$CAPACITY" --json 2>/dev/null |
    jq -c '[(.gates[] | select(.name == "host-memory") | .state), .budget.notes, .verdict.admit]')
  assert_equals '["unknown",["Windows host view unavailable"],true]' "$out" "an unreadable host must be unknown, noted, and not judged"
  pass "inside WSL the Windows host view can only close admission, and it is cached and degrades"
}

test_spawn_gate_is_opt_in() {
  local home fakebin rc
  home=$(make_home gate)
  fakebin=$(make_probes "$TMP_ROOT/p-gate")
  while IFS='|' read -r body want label; do
    [ -n "$label" ] || continue
    printf '%b' "$body" > "$home/config/lane-capacity"
    rc=0
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$CAPACITY" --spawn-gate >/dev/null 2>&1 || rc=$?
    expect_code "$want" "$rc" "$label"
  done <<'ROWS'
0\n|0|a full fixed cap without admit-spawns must not gate spawns
0\nadmit-spawns\n|75|a full fixed cap with admit-spawns must defer
auto\nadmit-spawns\nmax-lanes 0\n|75|a full auto ceiling with admit-spawns must defer
auto\nadmit-spawns\n|0|an open auto budget must admit
bogus\n|0|an invalid file without admit-spawns must not gate spawns
bogus\nadmit-spawns\n|1|an invalid file that asks for the gate must refuse
ROWS
  while IFS='|' read -r body want label; do
    [ -n "$label" ] || continue
    printf '%b' "$body" > "$home/config/lane-capacity"
    rc=0
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$CAPACITY" --spawn-gate-enabled >/dev/null 2>&1 || rc=$?
    expect_code "$want" "$rc" "$label"
  done <<'ROWS'
0\n|1|--spawn-gate-enabled without admit-spawns
auto\nadmit-spawns\n|0|--spawn-gate-enabled with admit-spawns
bogus\nadmit-spawns\n|0|--spawn-gate-enabled on an invalid opted-in file
ROWS
  rm -f "$home/config/lane-capacity"
  rc=0
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$CAPACITY" --spawn-gate >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "an absent file must not gate spawns"
  rc=0
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$CAPACITY" --spawn-gate-enabled >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an absent file must report the gate disabled"
  pass "--spawn-gate applies the verdict only when config/lane-capacity declares admit-spawns"
}

test_auto_config_validation() {
  local home fakebin out rc body
  home=$(make_home config)
  fakebin=$(make_probes "$TMP_ROOT/p-config")
  for body in '5\nmax-lanes 3\n' '5\nlane-footprint-gb 2\n' 'auto\nallow-battery yes\n' 'auto\nlane-footprint-gb 0.05\n' \
    'auto\nmax-lanes 2\nmax-lanes 3\n' 'auto\nmax-lanes two\n' 'auto\nhost-min-avail-gb\n'; do
    printf '%b' "$body" > "$home/config/lane-capacity"
    rc=0
    out=$(run_cap "$home" "$fakebin") || rc=$?
    expect_code 1 "$rc" "config '$body' must be invalid"
    assert_contains "$out" 'reason=invalid-target lanes=0 target=invalid' "config '$body' must report invalid"
  done
  printf 'auto # measured\nmax-lanes 6 # ceiling\nallow-battery\nadmit-spawns\nlane-disk-gb 4\nhost-min-avail-gb 3\nmin-gpu-free-gb 2\n' > "$home/config/lane-capacity"
  rc=0
  out=$(run_cap "$home" "$fakebin") || rc=$?
  expect_code 0 "$rc" "a full valid auto config: $out"
  assert_contains "$out" 'target=6 ' "max-lanes must be the published target"
  pass "auto-only keys need auto, flags take no value, and malformed values are refused"
}

test_real_host_auto_smoke() {
  local home out rc=0
  home=$(make_home real)
  printf 'auto\n' > "$home/config/lane-capacity"
  out=$(FM_HOME="$home" "$CAPACITY" 2>&1) || rc=$?
  expect_code 0 "$rc" "the real-host auto report: $out"
  assert_contains "$(printf '%s\n' "$out" | head -1)" ' mode=auto budget=' "the real host must produce an auto budget"
  pass "auto mode runs against this real host"
}

test_fixed_mode_is_unchanged
test_budget_binds_the_scarcest_resource
test_ceiling_and_young_lanes
test_gates_reopen_after_three_publishes
test_pressure_thermal_and_battery_gates
test_unmeasurable_vitals
test_learned_and_pinned_footprint
test_publish_writes_ledger_and_history
test_reclaim_ranks_idle_lanes
test_wsl_host_view_closes_admission
test_spawn_gate_is_opt_in
test_auto_config_validation
test_real_host_auto_smoke

echo '# all fm-capacity-auto tests passed'
