#!/usr/bin/env bash
# Behavior tests for the host headroom gate (bin/fm-host-headroom.sh owns the
# measurements, thresholds, verdict, and footprint log; bin/fm-spawn.sh runs the
# check before a fresh worker launch).
#
# The verdict cases pin measurements through the FM_TEST_SEAM sample so every
# threshold edge is exact on any machine. The measurement cases drive the real
# darwin and linux parsers against fake sysctl, vm_stat, and /proc inputs, and
# against tools that are missing. The spawn cases drive the real
# bin/fm-spawn.sh against a real project clone with fake tmux and treehouse
# binaries, and judge a deferral by what it left behind.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

HEADROOM="$ROOT/bin/fm-host-headroom.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-headroom)
DEFER_EXIT=75
HEALTHY='total_mb=49152 avail_mb=40000 swap_used_mb=0 load1=1 cores=18 pressure=normal'

# A bare Firstmate home for the helper alone.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

# Run the helper in <home> with the FM_HOST_HEADROOM_SAMPLE given.
headroom() {  # <home> <sample> <args...>
  local home=$1 sample=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_HOST_HEADROOM_SAMPLE="$sample" "$HEADROOM" "$@" 2>&1
}

# Run the helper with real measurement on a forced platform: no sample.
measured() {  # <home> <platform> <path> <args...>
  local home=$1 platform=$2 path=$3
  shift 3
  ( unset FM_HOST_HEADROOM_SAMPLE
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
      FM_HOST_HEADROOM_PLATFORM="$platform" FM_HOST_HEADROOM_PROC="${PROC_DIR:-}" PATH="$path" \
      "$HEADROOM" "$@" 2>&1 )
}

# --- verdict ------------------------------------------------------------------

test_healthy_machine_is_ok() {
  local home out rc=0
  home=$(make_home healthy)
  out=$(headroom "$home" "$HEALTHY" check) || rc=$?
  expect_code 0 "$rc" "a healthy machine was not ok: $out"
  assert_contains "$out" "ok: available 81% (40000 of 49152 MB), swap used 0 MB, load 1 on 18 cores (0.06 per core), pressure normal" \
    "the ok line did not name every measured value"
  pass "a machine within every default threshold is ok and names its numbers"
}

# Each default threshold admits its exact edge and defers just past it.
test_default_threshold_edges() {
  local home out rc
  home=$(make_home edges)
  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=20 swap_used_mb=16384 load1=27 cores=18 pressure=warn' check) || rc=$?
  expect_code 0 "$rc" "a machine exactly at every default edge was deferred: $out"

  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=19 swap_used_mb=0 load1=1 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "available memory below min_avail_pct was not deferred: $out"
  assert_contains "$out" "defer: available memory 19% is below min_avail_pct=20" "the low-memory deferral did not name the threshold"

  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=50 swap_used_mb=16385 load1=1 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "swap past max_swap_used_mb was not deferred: $out"
  assert_contains "$out" "swap used 16385 MB exceeds max_swap_used_mb=16384" "the swap deferral did not name the threshold"

  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=50 swap_used_mb=0 load1=27.2 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "load past max_load_per_core was not deferred: $out"
  assert_contains "$out" "load 1.51 per core exceeds max_load_per_core=1.5" "the load deferral did not name the threshold"

  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=50 swap_used_mb=0 load1=1 cores=18 pressure=critical' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "critical pressure was not deferred: $out"
  assert_contains "$out" "memory pressure is critical (defer_pressure=critical)" "the pressure deferral did not name the threshold"

  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=5 swap_used_mb=20000 load1=1 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "two breached thresholds were not deferred: $out"
  assert_contains "$out" "available memory 5% is below min_avail_pct=20; swap used 20000 MB exceeds max_swap_used_mb=16384" \
    "a deferral did not name every breached threshold"
  pass "each default threshold admits its exact edge and defers just past it, naming every breach"
}

test_configured_thresholds_apply() {
  local home out rc
  home=$(make_home configured)
  printf '%s\n' '# tighter for this machine' 'min_avail_pct=40' 'max_swap_used_mb=off' \
    'max_load_per_core = 0.5' 'defer_pressure=warn' > "$home/config/host-headroom"
  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=40 swap_used_mb=99999 load1=9 cores=18 pressure=normal' check) || rc=$?
  expect_code 0 "$rc" "configured edges or a disabled threshold deferred: $out"
  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=40 swap_used_mb=0 load1=1 cores=18 pressure=warn' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "defer_pressure=warn did not defer at warn: $out"
  rc=0
  out=$(headroom "$home" 'total_mb=1000 avail_pct=39 swap_used_mb=0 load1=1 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a configured min_avail_pct did not apply: $out"
  assert_contains "$out" "below min_avail_pct=40" "the configured threshold was not named"
  pass "config/host-headroom overrides each default and off disables a threshold"
}

# A secondmate home judges the machine by its root home's thresholds.
test_secondmate_home_reads_root_thresholds() {
  local root mate out rc=0
  root=$(make_home root-home)
  mate=$(make_home root-home-mate)
  printf '%s\n' 'min_avail_pct=60' > "$root/config/host-headroom"
  printf '%s\n' 'min_avail_pct=off' > "$mate/config/host-headroom"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$mate/.fm-secondmate-parent"
  out=$(headroom "$mate" 'total_mb=1000 avail_pct=50' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a secondmate home did not apply its root home's thresholds: $out"
  assert_contains "$out" "below min_avail_pct=60" "the root home's threshold was not the one applied"
  pass "a local secondmate home judges the machine by the root home's thresholds"
}

test_unreadable_thresholds_refuse() {
  local home out rc line
  home=$(make_home unreadable)
  for line in 'min_avail_pct=abc' 'min_avail_pct=101' 'nonsense=1' 'defer_pressure=normal' \
    'max_load_per_core=1.2.3' 'just words'; do
    printf '%s\n' "$line" > "$home/config/host-headroom"
    rc=0
    out=$(headroom "$home" "$HEALTHY" check) || rc=$?
    expect_code 1 "$rc" "malformed line '$line' did not refuse: $out"
    assert_contains "$out" "error: host headroom thresholds are unreadable: $home/config/host-headroom line 1" \
      "malformed line '$line' did not name the file and line"
  done
  printf '%s\n' 'min_avail_pct=10' 'min_avail_pct=30' > "$home/config/host-headroom"
  rc=0
  out=$(headroom "$home" "$HEALTHY" check) || rc=$?
  expect_code 1 "$rc" "a duplicate key did not refuse: $out"
  assert_contains "$out" "sets min_avail_pct twice" "the duplicate key was not named"
  rm -f "$home/config/host-headroom"
  mkdir "$home/config/host-headroom"
  rc=0
  out=$(headroom "$home" "$HEALTHY" check) || rc=$?
  expect_code 1 "$rc" "a non-file threshold path did not refuse: $out"
  pass "a malformed, duplicated, or unreadable threshold file refuses rather than guessing"
}

# --- measurement --------------------------------------------------------------

# Fake darwin tools: sysctl answers from FAKE_SYSCTL_<key> variables and fails
# for an unset one; vm_stat prints FAKE_VM_STAT or fails when it is unset.
make_darwin_fakes() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
[ "$1" = -n ] || exit 1
var="FAKE_SYSCTL_$(printf '%s' "$2" | tr '.' '_')"
[ -n "${!var+x}" ] || exit 1
printf '%s\n' "${!var}"
SH
  cat > "$fakebin/vm_stat" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_VM_STAT+x}" ] || exit 127
printf '%s\n' "$FAKE_VM_STAT"
SH
  chmod +x "$fakebin/sysctl" "$fakebin/vm_stat"
  printf '%s\n' "$fakebin"
}

test_darwin_measurement() {
  local home fakebin out rc=0
  home=$(make_home darwin)
  fakebin=$(make_darwin_fakes "$TMP_ROOT/darwin-tools")
  out=$(FAKE_SYSCTL_hw_memsize=51539607552 FAKE_SYSCTL_kern_memorystatus_level=41 \
    FAKE_SYSCTL_vm_swapusage='total = 9216.00M  used = 8331.75M  free = 884.25M  (encrypted)' \
    FAKE_SYSCTL_kern_memorystatus_vm_pressure_level=2 FAKE_SYSCTL_vm_loadavg='{ 11.02 10.50 9.80 }' \
    FAKE_SYSCTL_hw_ncpu=18 measured "$home" darwin "$fakebin:$PATH" check) || rc=$?
  expect_code 0 "$rc" "a healthy darwin reading was not ok: $out"
  assert_contains "$out" "ok: available 41% (20152 of 49152 MB), swap used 8332 MB, load 11.02 on 18 cores (0.61 per core), pressure warn" \
    "the darwin readings were not parsed"

  # Without kern.memorystatus_level, free + inactive + speculative pages count.
  rc=0
  out=$(FAKE_SYSCTL_hw_memsize=51539607552 FAKE_VM_STAT='Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                    64000.
Pages active:                                 711460.
Pages inactive:                               192000.
Pages speculative:                              0.' \
    FAKE_SYSCTL_vm_swapusage='total = 2.00G  used = 1.50G  free = 0.50G' \
    measured "$home" darwin "$fakebin:$PATH" check) || rc=$?
  assert_contains "$out" "available 8% (4000 of 49152 MB), swap used 1536 MB" "the vm_stat fallback was not parsed"
  expect_code "$DEFER_EXIT" "$rc" "the vm_stat fallback's low memory did not defer: $out"
  pass "darwin headroom is read from sysctl, with vm_stat as the available-memory fallback"
}

test_linux_measurement() {
  local home out rc=0
  home=$(make_home linux)
  PROC_DIR="$TMP_ROOT/proc"
  mkdir -p "$PROC_DIR"
  printf '%s\n' 'MemTotal:       16384000 kB' 'MemFree:         1000000 kB' 'MemAvailable:    2048000 kB' \
    'SwapTotal:       4096000 kB' 'SwapFree:        3072000 kB' > "$PROC_DIR/meminfo"
  printf '%s\n' '3.50 2.00 1.00 2/300 12345' > "$PROC_DIR/loadavg"
  out=$(PROC_DIR=$PROC_DIR measured "$home" linux "$PATH" check) || rc=$?
  assert_contains "$out" "available 12% (2000 of 16000 MB), swap used 1000 MB, load 3.50 on" "the /proc readings were not parsed"
  expect_code "$DEFER_EXIT" "$rc" "low MemAvailable did not defer: $out"
  assert_contains "$out" "(unmeasured, not judged: pressure level)" "linux did not report its missing pressure level"
  PROC_DIR=
  pass "linux headroom is read from /proc/meminfo and /proc/loadavg"
}

test_missing_tools_never_block() {
  local home fakebin out rc=0
  home=$(make_home missing)
  fakebin=$(make_darwin_fakes "$TMP_ROOT/missing-tools")
  out=$(measured "$home" darwin "$fakebin:$PATH" check) || rc=$?
  expect_code 0 "$rc" "missing darwin tools blocked the verdict: $out"
  assert_contains "$out" "ok: available ?% (? of ? MB), swap used ? MB, load ? on ? cores (? per core), pressure ?" \
    "unmeasured values were not shown as unknown"
  assert_contains "$out" "(unmeasured, not judged: available memory, swap, load, pressure level)" \
    "the unmeasured values were not named"

  rc=0
  PROC_DIR="$TMP_ROOT/empty-proc"
  mkdir -p "$PROC_DIR"
  out=$(PROC_DIR=$PROC_DIR measured "$home" linux "$PATH" check) || rc=$?
  PROC_DIR=
  expect_code 0 "$rc" "an unreadable /proc blocked the verdict: $out"
  assert_contains "$out" "unmeasured, not judged: available memory, swap" "the unreadable /proc values were not named"

  rc=0
  out=$(measured "$home" plan9 "$PATH" check) || rc=$?
  expect_code 0 "$rc" "an unfamiliar platform blocked the verdict: $out"
  pass "a missing tool or unfamiliar platform is reported unmeasured and never blocks a spawn"
}

# --- footprint ----------------------------------------------------------------

test_record_measures_the_worktree_processes() {
  local home wt pid out line
  home=$(make_home record)
  wt="$TMP_ROOT/record-wt"
  mkdir -p "$wt/sub"
  ( cd "$wt/sub" && exec sleep 30 ) &
  pid=$!
  sleep 0.3
  out=$(headroom "$home" "$HEALTHY" record teardown task-r "$wt")
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  [ -z "$out" ] || fail "record printed output: $out"
  line=$(tail -1 "$home/state/host-footprint.log")
  assert_contains "$line" " event=teardown task=task-r worker_rss_mb=" "the record line was not written"
  assert_contains "$line" "avail_pct=81 avail_mb=40000 total_mb=49152 swap_used_mb=0 load1=1 cores=18 pressure=normal" \
    "the record line did not carry the machine's headroom"
  case "$line" in
    *" worker_rss_mb=-"* | *" worker_rss_mb=0 "*) fail "a process working in the worktree was not measured: $line" ;;
  esac

  out=$(headroom "$home" "$HEALTHY" record spawn task-s)
  line=$(tail -1 "$home/state/host-footprint.log")
  assert_contains "$line" " event=spawn task=task-s worker_rss_mb=- " "a spawn record without a worktree did not say so"
  pass "record sums the resident memory of processes working in the task worktree and the machine's headroom"
}

test_report_summarizes_worker_load() {
  local home out
  home=$(make_home report)
  printf '%s\n' \
    '100 event=spawn task=a worker_rss_mb=- avail_pct=50' \
    '200 event=sample task=a worker_rss_mb=600 avail_pct=50' \
    '300 event=teardown task=a worker_rss_mb=900 avail_pct=50' \
    '300 event=teardown task=b worker_rss_mb=400 avail_pct=50' \
    '300 event=teardown task=c worker_rss_mb=1000 avail_pct=50' \
    '300 event=teardown task=d worker_rss_mb=? avail_pct=?' > "$home/state/host-footprint.log"
  out=$(headroom "$home" 'total_mb=50000 avail_mb=20000 swap_used_mb=0 load1=1 cores=10 pressure=normal' report)
  assert_contains "$out" "Per-worker memory: largest seen per task across 3 task(s) - median 900 MB, largest 1000 MB" \
    "the report did not summarize per-worker memory from each task's largest sample"
  assert_contains "$out" "More workers that fit before available memory reaches 20% (10000 MB): 10 at 1000 MB each" \
    "the report did not compute the workers that still fit"
  assert_contains "$out" "Largest safe concurrent worker count implied: 10 (0 running + 10 more)" \
    "the report did not state the implied concurrent count"
  assert_contains "$out" "Verdict now: ok" "the report did not give the current verdict"

  rm -f "$home/state/host-footprint.log"
  out=$(headroom "$home" "$HEALTHY" report)
  assert_contains "$out" "Per-worker memory: no worker samples yet" "an empty log was not reported as empty"
  pass "report gives typical per-worker memory and the largest concurrent load the thresholds imply"
}

# --- spawn gate -----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the work for $2.

## Firstmate spec
Exercise the host headroom gate.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

make_case() {  # <name> <task-id>
  local case_dir="$TMP_ROOT/$1" fakebin home
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  home="$case_dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  write_brief "$home" "$2"
  printf '%s\n' "$case_dir"
}

run_spawn() {  # <case-dir> <sample> <id> [env...]
  local case_dir=$1 sample=$2 id=$3 wt
  shift 3
  wt="$case_dir/wt-$id"
  [ -d "$wt" ] || git -C "$case_dir/project" worktree add --quiet -b "wt-$id" "$wt"
  env "$@" FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux FM_HOST_HEADROOM_SAMPLE="$sample" \
    FM_FAKE_PANE_PATH="$wt" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off 2>&1
}

test_spawn_defers_on_a_short_machine() {
  local case_dir home out rc=0
  case_dir=$(make_case spawn-defer task-d)
  home="$case_dir/home"
  out=$(run_spawn "$case_dir" 'total_mb=49152 avail_pct=10 swap_used_mb=0 load1=1 cores=18 pressure=normal' task-d) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn on a machine short of memory was not deferred: $out"
  assert_contains "$out" "deferred: this machine is short of headroom for another worker (available memory 10% is below min_avail_pct=20 - available 10% (4915 of 49152 MB)" \
    "the deferral did not name the numbers and the threshold"
  assert_contains "$out" "task task-d was not launched and its backlog item stays queued" "the deferral did not say the task stays queued"
  assert_absent "$home/state/task-d.meta" "a deferred spawn published a task record"
  assert_absent "$home/data/task-d/launch-brief.md" "a deferred spawn rendered a launch brief"
  [ ! -s "$case_dir/calls.log" ] || fail "a deferred spawn touched the terminal or worktree pool: $(cat "$case_dir/calls.log")"
  assert_absent "$home/state/host-footprint.log" "a deferred spawn wrote a footprint record"
  pass "a fresh spawn on a machine short of headroom is deferred with exit 75 before anything is created"
}

test_spawn_launches_and_records_with_headroom() {
  local case_dir home out rc=0
  case_dir=$(make_case spawn-ok task-o)
  home="$case_dir/home"
  out=$(run_spawn "$case_dir" "$HEALTHY" task-o) || rc=$?
  expect_code 0 "$rc" "a spawn with headroom was refused: $out"
  assert_contains "$out" "spawned task-o" "a spawn with headroom did not launch"
  assert_grep " event=spawn task=task-o worker_rss_mb=- avail_pct=81 avail_mb=40000" "$home/state/host-footprint.log" \
    "a launched spawn did not append its footprint record"
  pass "a fresh spawn with headroom launches and records the machine's headroom"
}

test_spawn_override_skips_the_check() {
  local case_dir home out rc=0
  case_dir=$(make_case spawn-override task-v)
  home="$case_dir/home"
  out=$(run_spawn "$case_dir" 'total_mb=49152 avail_pct=1 pressure=critical' task-v FM_SPAWN_IGNORE_HEADROOM=1) || rc=$?
  expect_code 0 "$rc" "FM_SPAWN_IGNORE_HEADROOM=1 did not skip the check: $out"
  assert_contains "$out" "notice: FM_SPAWN_IGNORE_HEADROOM=1 - launching task-v without checking this machine's headroom" \
    "the override was not announced"
  assert_present "$home/state/task-v.meta" "the overridden spawn published no record"
  pass "FM_SPAWN_IGNORE_HEADROOM=1 launches one spawn without the check"
}

test_spawn_refuses_on_unreadable_thresholds() {
  local case_dir home out rc=0
  case_dir=$(make_case spawn-bad task-b)
  home="$case_dir/home"
  printf '%s\n' 'min_avail_pct=lots' > "$home/config/host-headroom"
  out=$(run_spawn "$case_dir" "$HEALTHY" task-b) || rc=$?
  expect_code 1 "$rc" "a spawn with unreadable thresholds was not refused: $out"
  assert_contains "$out" "error: spawn refused: this machine's headroom could not be judged" "the refusal was not explained"
  assert_absent "$home/state/task-b.meta" "a refused spawn published a task record"
  pass "a spawn refuses rather than guessing when the threshold file is unreadable"
}

test_healthy_machine_is_ok
test_default_threshold_edges
test_configured_thresholds_apply
test_secondmate_home_reads_root_thresholds
test_unreadable_thresholds_refuse
test_darwin_measurement
test_linux_measurement
test_missing_tools_never_block
test_record_measures_the_worktree_processes
test_report_summarizes_worker_load
test_spawn_defers_on_a_short_machine
test_spawn_launches_and_records_with_headroom
test_spawn_override_skips_the_check
test_spawn_refuses_on_unreadable_thresholds
