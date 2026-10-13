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

# Footprint log spawn lines at epoch 1 for each task id, so a sample taken
# 600 or more seconds later is a mid-work reading.
spawned() {  # <task-id...>
  local id
  for id in "$@"; do printf '1 event=spawn task=%s\n' "$id"; done
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
  assert_contains "$out" "ok: available 81% (40000 of 49152 MB), swap used 0 MB, load 1 on 18 cores (0.06 per core), pressure normal; expected worker 1536 MB (default_worker_mb, fewer than 3 measured workers); 0 running worker(s) reserve 0 MB" \
    "the ok line did not name every measured value and the expected footprint"
  pass "a machine within every default threshold is ok and names its numbers and the expected footprint"
}

# Each default threshold admits its exact edge and defers just past it. With no
# footprint log the new worker is expected at default_worker_mb (1536 MB), and
# the memory floor is 20% of 10000 MB.
test_default_threshold_edges() {
  local home out rc
  home=$(make_home edges)
  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=3536 swap_used_mb=16384 load1=27 cores=18 pressure=warn' check) || rc=$?
  expect_code 0 "$rc" "a machine exactly at every default edge was deferred: $out"

  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=3535 swap_used_mb=0 load1=1 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a worker that would take memory below the floor was not deferred: $out"
  assert_contains "$out" "defer: available memory 3535 MB less 0 MB reserved for running workers and this worker's expected 1536 MB leaves 1999 MB, below min_avail_pct=20 (2000 MB)" \
    "the memory deferral did not name the numbers and threshold"

  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=8000 swap_used_mb=16385 load1=1 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "swap past max_swap_used_mb was not deferred: $out"
  assert_contains "$out" "swap used 16385 MB exceeds max_swap_used_mb=16384" "the swap deferral did not name the threshold"

  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=8000 swap_used_mb=0 load1=27.2 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "load past max_load_per_core was not deferred: $out"
  assert_contains "$out" "load 1.51 per core exceeds max_load_per_core=1.5" "the load deferral did not name the threshold"

  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=8000 swap_used_mb=0 load1=1 cores=18 pressure=critical' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "critical pressure was not deferred: $out"
  assert_contains "$out" "memory pressure is critical (defer_pressure=critical)" "the pressure deferral did not name the threshold"

  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=1000 swap_used_mb=20000 load1=1 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "two breached thresholds were not deferred: $out"
  assert_contains "$out" "below min_avail_pct=20 (2000 MB); swap used 20000 MB exceeds max_swap_used_mb=16384" \
    "a deferral did not name every breached threshold"
  pass "each default threshold admits its exact edge and defers just past it, naming every breach"
}

test_configured_thresholds_apply() {
  local home out rc
  home=$(make_home configured)
  printf '%s\n' '# tighter for this machine' 'min_avail_pct=40' 'max_swap_used_mb=off' \
    'max_load_per_core = 0.5' 'defer_pressure=warn' 'default_worker_mb=500' > "$home/config/host-headroom"
  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=4500 swap_used_mb=99999 load1=9 cores=18 pressure=normal' check) || rc=$?
  expect_code 0 "$rc" "configured edges or a disabled threshold deferred: $out"
  assert_contains "$out" "expected worker 500 MB (default_worker_mb" "a configured default_worker_mb was not used"
  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=9000 swap_used_mb=0 load1=1 cores=18 pressure=warn' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "defer_pressure=warn did not defer at warn: $out"
  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=4499 swap_used_mb=0 load1=1 cores=18 pressure=normal' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a configured min_avail_pct did not apply: $out"
  assert_contains "$out" "below min_avail_pct=40 (4000 MB)" "the configured threshold was not named"
  pass "config/host-headroom overrides each default and off disables a threshold"
}

# The footprint log, not the project, decides what a new worker is expected to
# use: its kind and harness when at least 3 such tasks were measured, else its
# kind, else every worker, else default_worker_mb.
test_expected_footprint_falls_back_by_group() {
  local home out
  home=$(make_home expected)
  { spawned s1 s2 s3 s4 c1
    printf '%s\n' \
      '1000 event=sample task=s1 project=alpha kind=ship harness=claude model=- worker_rss_mb=500' \
      '1000 event=sample task=s2 project=beta kind=ship harness=claude model=- worker_rss_mb=400' \
      '2000 event=teardown task=s2 project=beta kind=ship harness=claude model=- worker_rss_mb=600' \
      '1000 event=sample task=s3 project=gamma kind=ship harness=claude model=- worker_rss_mb=700' \
      '1000 event=sample task=s4 project=alpha kind=ship harness=codex model=- worker_rss_mb=900' \
      '1000 event=sample task=c1 project=alpha kind=scout harness=codex model=- worker_rss_mb=3000' \
      '1 event=spawn task=n1 project=alpha kind=ship harness=claude model=- worker_rss_mb=-'
  } > "$home/state/host-footprint.log"
  out=$(headroom "$home" "$HEALTHY" check --kind ship --harness claude --model opus --project delta)
  assert_contains "$out" "expected worker 700 MB (90th percentile of 3 ship claude workers)" \
    "a kind and harness with 3 measured tasks did not set the expected footprint"
  out=$(headroom "$home" "$HEALTHY" check --kind ship --harness codex)
  assert_contains "$out" "expected worker 900 MB (90th percentile of 4 ship workers)" \
    "a sparse harness did not fall back to its kind"
  out=$(headroom "$home" "$HEALTHY" check --kind scout --harness codex)
  assert_contains "$out" "expected worker 3000 MB (90th percentile of 5 workers)" \
    "a sparse kind did not fall back to every worker"
  pass "a new worker's expected footprint comes from its kind and harness, then its kind, then every worker"
}

# Workers from different projects share one budget: the same machine admits a
# small expected worker and defers a large one.
test_mixed_workers_share_one_budget() {
  local home out rc
  home=$(make_home budget)
  { spawned a b c d e f
    printf '%s\n' \
      '1000 event=sample task=a project=alpha kind=ship harness=claude worker_rss_mb=500' \
      '1000 event=sample task=b project=beta kind=ship harness=claude worker_rss_mb=500' \
      '1000 event=sample task=c project=gamma kind=ship harness=claude worker_rss_mb=500' \
      '1000 event=sample task=d project=alpha kind=scout harness=codex worker_rss_mb=4000' \
      '1000 event=sample task=e project=beta kind=scout harness=codex worker_rss_mb=4000' \
      '1000 event=sample task=f project=gamma kind=scout harness=codex worker_rss_mb=4000'
  } > "$home/state/host-footprint.log"
  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=4000 swap_used_mb=0 load1=1 cores=18 pressure=normal' \
    check --kind ship --harness claude --project beta) || rc=$?
  expect_code 0 "$rc" "a small expected worker did not fit the shared budget: $out"
  rc=0
  out=$(headroom "$home" 'total_mb=10000 avail_mb=4000 swap_used_mb=0 load1=1 cores=18 pressure=normal' \
    check --kind scout --harness codex --project beta) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a large expected worker was admitted beyond the shared budget: $out"
  assert_contains "$out" "less 0 MB reserved for running workers and this worker's expected 4000 MB leaves 0 MB, below min_avail_pct=20 (2000 MB)" \
    "the deferral did not name the large worker's expected footprint"
  pass "workers from any project share one machine budget and are admitted by their expected size"
}

# Readings taken at cleanup, after the work finished, or while a worker is
# still starting up never lower the expected footprint below
# default_worker_mb; mid-work samples of 3 tasks do.
test_startup_and_teardown_readings_never_lower_the_default() {
  local home out
  home=$(make_home floor)
  { spawned t1 t2 t3 t4
    printf '%s\n' \
      '5000 event=teardown task=t1 project=alpha kind=ship harness=claude worker_rss_mb=300' \
      '5000 event=teardown task=t2 project=alpha kind=ship harness=claude worker_rss_mb=300' \
      '5000 event=teardown task=t3 project=alpha kind=ship harness=claude worker_rss_mb=300' \
      '5000 event=teardown task=t4 project=alpha kind=ship harness=claude worker_rss_mb=300' \
      '100 event=sample task=t1 project=alpha kind=ship harness=claude worker_rss_mb=250' \
      '100 event=sample task=t2 project=alpha kind=ship harness=claude worker_rss_mb=250' \
      '100 event=sample task=t3 project=alpha kind=ship harness=claude worker_rss_mb=250' \
      '5000 event=sample task=u1 project=alpha kind=ship harness=claude worker_rss_mb=250' \
      '5000 event=sample task=u2 project=alpha kind=ship harness=claude worker_rss_mb=250' \
      '5000 event=sample task=u3 project=alpha kind=ship harness=claude worker_rss_mb=250'
  } > "$home/state/host-footprint.log"
  out=$(headroom "$home" "$HEALTHY" check --kind ship --harness claude)
  assert_contains "$out" "expected worker 1536 MB (default_worker_mb, fewer than 3 measured workers of kind ship)" \
    "teardown, startup, or spawn-less readings lowered the expected footprint below default_worker_mb"
  printf '%s\n' \
    '2000 event=sample task=t1 project=alpha kind=ship harness=claude worker_rss_mb=200' \
    '2000 event=sample task=t2 project=alpha kind=ship harness=claude worker_rss_mb=200' \
    >> "$home/state/host-footprint.log"
  out=$(headroom "$home" "$HEALTHY" check --kind ship --harness claude)
  assert_contains "$out" "expected worker 1536 MB (default_worker_mb" \
    "mid-work samples of fewer than 3 tasks lowered the expected footprint"
  printf '%s\n' '2000 event=sample task=t3 project=alpha kind=ship harness=claude worker_rss_mb=200' \
    >> "$home/state/host-footprint.log"
  out=$(headroom "$home" "$HEALTHY" check --kind ship --harness claude)
  assert_contains "$out" "expected worker 300 MB (90th percentile of 3 ship claude workers)" \
    "mid-work samples of 3 tasks did not set the expected footprint from their largest readings"
  pass "startup and teardown readings alone never lower the expected footprint below default_worker_mb"
}

# When registered local homes are malformed or missing, only those are
# skipped: the root home's workers and those of a live home registered after
# them still reserve their footprint.
test_unreadable_home_keeps_the_other_homes_workers() {
  local root mate live wt out rc=0
  root=$(make_home reserve-root)
  mate=$(make_home reserve-root-mate)
  live=$(make_home reserve-root-live)
  wt="$TMP_ROOT/reserve-root-wt"
  mkdir -p "$wt"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$mate/.fm-secondmate-parent"
  printf '%s\n' '- broken registry entry' \
    "- sm-a - retired (home: $TMP_ROOT/reserve-root-gone; scope: x; projects: p; added 2026-01-01)" \
    "- sm-b - live (home: $live; scope: x; projects: p; added 2026-01-01)" > "$root/data/secondmates.md"
  fm_write_meta "$root/state/root-ship.meta" kind=ship harness=claude "worktree=$wt"
  fm_write_meta "$live/state/live-ship.meta" kind=ship harness=claude "worktree=$wt"
  out=$(headroom "$mate" "$HEALTHY" check --kind ship --harness claude) || rc=$?
  expect_code 0 "$rc" "a healthy machine was not ok: $out"
  assert_contains "$out" "warning: skipping a malformed local Firstmate registry entry" \
    "the malformed registry entry was not reported"
  assert_contains "$out" "warning: skipping unavailable local Firstmate home $TMP_ROOT/reserve-root-gone" \
    "the missing home was not reported"
  assert_contains "$out" "; 2 running worker(s) reserve 3072 MB" \
    "a home that could not be read hid the workers of the root home or of a home registered after it"
  pass "a home that cannot be read never hides the workers of the homes that can"
}

# A secondmate home judges the machine by its root home's thresholds and log.
test_secondmate_home_reads_root_thresholds() {
  local root mate out rc=0
  root=$(make_home root-home)
  mate=$(make_home root-home-mate)
  printf '%s\n' 'min_avail_pct=60' > "$root/config/host-headroom"
  printf '%s\n' 'min_avail_pct=off' > "$mate/config/host-headroom"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$mate/.fm-secondmate-parent"
  out=$(headroom "$mate" 'total_mb=10000 avail_mb=7000' check) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a secondmate home did not apply its root home's thresholds: $out"
  assert_contains "$out" "below min_avail_pct=60" "the root home's threshold was not the one applied"
  headroom "$mate" "$HEALTHY" record spawn task-m >/dev/null
  assert_present "$root/state/host-footprint.log" "a secondmate home did not record into the root home's footprint log"
  assert_absent "$mate/state/host-footprint.log" "a secondmate home kept its own footprint log"
  pass "a local secondmate home shares the root home's thresholds and footprint log"
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
  fm_write_meta "$home/state/task-r.meta" "project=$TMP_ROOT/my project" kind=ship harness=claude model=opus "worktree=$wt"
  ( cd "$wt/sub" && exec sleep 30 ) &
  pid=$!
  sleep 0.3
  out=$(headroom "$home" "$HEALTHY" record teardown task-r "$wt")
  kill "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  [ -z "$out" ] || fail "record printed output: $out"
  line=$(tail -1 "$home/state/host-footprint.log")
  assert_contains "$line" " event=teardown task=task-r project=my_project kind=ship harness=claude model=opus worker_rss_mb=" \
    "the record line did not carry the task's identity"
  assert_contains "$line" "avail_pct=81 avail_mb=40000 total_mb=49152 swap_used_mb=0 load1=1 cores=18 pressure=normal" \
    "the record line did not carry the machine's headroom"
  case "$line" in
    *" worker_rss_mb=-"* | *" worker_rss_mb=0 "*) fail "a process working in the worktree was not measured: $line" ;;
  esac

  out=$(headroom "$home" "$HEALTHY" record spawn task-s)
  line=$(tail -1 "$home/state/host-footprint.log")
  assert_contains "$line" " event=spawn task=task-s project=- kind=- harness=- model=- worker_rss_mb=- " \
    "a record with no task record or worktree did not say so"
  pass "record tags the worker's project, kind, harness, and model and sums the memory of its worktree's processes"
}

test_report_summarizes_the_machine_budget() {
  local home out
  home=$(make_home report)
  mkdir -p "$home/projects/small-pool" "$home/projects/default-pool"
  printf '%s\n' 'max_trees = 3' > "$home/projects/small-pool/treehouse.toml"
  printf '%s\n' \
    '100 event=spawn task=a project=alpha kind=ship harness=claude worker_rss_mb=-' \
    '100 event=spawn task=b' '100 event=spawn task=c' \
    '800 event=sample task=a project=alpha kind=ship harness=claude worker_rss_mb=600' \
    '900 event=teardown task=a project=alpha kind=ship harness=claude worker_rss_mb=900' \
    '900 event=sample task=b project=beta kind=ship harness=claude worker_rss_mb=400' \
    '900 event=sample task=c project=alpha kind=scout harness=codex worker_rss_mb=1000' \
    '300 event=teardown task=d project=beta kind=ship harness=claude worker_rss_mb=?' > "$home/state/host-footprint.log"
  out=$(headroom "$home" 'total_mb=50000 avail_mb=20000 swap_used_mb=0 load1=1 cores=10 pressure=normal' report)
  assert_contains "$out" "Machine budget: 10000 MB available above the 20% floor (10000 MB) after 0 MB reserved for 0 running worker(s) to reach their expected footprint, shared by every project" \
    "the report did not state the machine budget"
  assert_contains "$out" "  ship/claude: 2 task(s), median 400 MB, p90 900 MB, largest 900 MB; 11 more fit in the budget" \
    "the report did not summarize ship/claude workers"
  assert_contains "$out" "  scout/codex: 1 task(s), median 1000 MB, p90 1000 MB, largest 1000 MB; 10 more fit in the budget" \
    "the report did not summarize scout/codex workers"
  assert_contains "$out" "  alpha: 2 task(s), median 900 MB, p90 1000 MB, largest 1000 MB" \
    "the report did not summarize by project"
  assert_contains "$out" "Largest safe concurrent worker count implied: 10 (0 running + 10 more at 1000 MB each, 90th percentile of 3 workers)" \
    "the report did not state the implied concurrent count"
  assert_contains "$out" "  small-pool: pool cap 3 binds before the machine budget (10 workers)" \
    "a project pool smaller than the budget was not named as binding"
  assert_contains "$out" "  default-pool: pool cap 16; the machine budget (10 workers) binds first" \
    "a default project pool was not compared with the budget"

  rm -f "$home/state/host-footprint.log"
  out=$(headroom "$home" "$HEALTHY" report)
  assert_contains "$out" "Per-worker memory: no worker samples yet" "an empty log was not reported as empty"
  pass "report gives per-worker memory by kind, harness, and project, the machine budget, and which project pools bind first"
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
  assert_contains "$out" "deferred: this machine is short of headroom for another worker (available memory 4915 MB less 0 MB reserved for running workers and this worker's expected 1536 MB leaves 3379 MB, below min_avail_pct=20 (9830 MB) - available 10% (4915 of 49152 MB)" \
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
  assert_grep " event=spawn task=task-o project=project kind=ship harness=codex model=default worker_rss_mb=- avail_pct=81 avail_mb=40000" "$home/state/host-footprint.log" \
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

# A rapid sequential fan-out: every spawn sees the same available memory,
# because a freshly launched worker has barely grown, yet the workers already
# admitted reserve their expected footprint, so the fan-out stops at the budget.
# Each worker runs a real process of about 48 MB in its worktree, so the samples
# every check takes are real startup readings, which must not lower the
# expected footprint. 19660 MB available over a 9830 MB floor leaves 9830 MB,
# room for 6 workers of 1536 MB.
test_spawn_fan_out_stops_at_the_budget() {
  local case_dir home out rc i sample pids=''
  case_dir=$(make_case spawn-fan-out fan-1)
  home="$case_dir/home"
  sample='total_mb=49152 avail_mb=19660 swap_used_mb=0 load1=1 cores=18 pressure=normal'
  for i in 1 2 3 4 5 6; do
    write_brief "$home" "fan-$i"
    rc=0
    out=$(run_spawn "$case_dir" "$sample" "fan-$i") || rc=$?
    expect_code 0 "$rc" "fan-out worker $i of 6 that fits the budget was refused: $out"
    ( cd "$case_dir/wt-fan-$i" && exec perl -e '$x = "a" x (48 << 20); sleep 600' ) &
    pids="$pids $!"
  done
  sleep 1
  write_brief "$home" fan-7
  rc=0
  out=$(run_spawn "$case_dir" "$sample" fan-7) || rc=$?
  # shellcheck disable=SC2086 # word-split the worker pids.
  kill $pids 2>/dev/null || :
  # shellcheck disable=SC2086 # word-split the worker pids.
  wait $pids 2>/dev/null || :
  expect_code "$DEFER_EXIT" "$rc" "a seventh fan-out worker beyond the budget was admitted: $out"
  assert_contains "$out" "MB reserved for running workers and this worker's expected 1536 MB leaves" \
    "the deferral did not count the reservation of the workers already admitted"
  assert_contains "$out" "below min_avail_pct=20 (9830 MB)" "the deferral did not name the floor"
  assert_contains "$out" "expected worker 1536 MB (default_worker_mb" \
    "startup samples of the fan-out's own workers lowered the expected footprint"
  grep -Eq " event=sample task=fan-1 .* worker_rss_mb=([4-9][0-9]|[0-9]{3,}) " "$home/state/host-footprint.log" ||
    fail "the fan-out workers' real processes were not sampled"
  assert_absent "$home/state/fan-7.meta" "a deferred fan-out worker published a task record"
  assert_absent "$home/state/.host-headroom.lock" "a spawn left the machine-wide headroom lock behind"
  pass "a rapid sequential fan-out is stopped at the machine budget by the running workers' reservation"
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
test_expected_footprint_falls_back_by_group
test_mixed_workers_share_one_budget
test_startup_and_teardown_readings_never_lower_the_default
test_unreadable_home_keeps_the_other_homes_workers
test_secondmate_home_reads_root_thresholds
test_unreadable_thresholds_refuse
test_darwin_measurement
test_linux_measurement
test_missing_tools_never_block
test_record_measures_the_worktree_processes
test_report_summarizes_the_machine_budget
test_spawn_defers_on_a_short_machine
test_spawn_launches_and_records_with_headroom
test_spawn_override_skips_the_check
test_spawn_fan_out_stops_at_the_budget
test_spawn_refuses_on_unreadable_thresholds
