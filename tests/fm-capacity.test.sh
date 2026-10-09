#!/usr/bin/env bash
# Behavioral coverage for bin/fm-capacity.sh: lane counting from task metadata,
# the optional config/lane-capacity target and keyed limits, host-constraint
# verdicts from faked probes, beat pressure files (fresh, late, stale, missing,
# malformed, foreign, several), the --json document, --publish (opt-in, atomic,
# throttled, boots, invalid config), --admit exit codes, captain presence and
# quota runway from fakes, graceful degradation, and a real-host smoke.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-capacity)
CAPACITY="$ROOT/bin/fm-capacity.sh"

# make_home <name> <ship-count> <secondmate-count>: a home with that many
# ship metas and secondmate metas.
make_home() {
  local home="$TMP_ROOT/$1" i
  mkdir -p "$home/state" "$home/config"
  i=0
  while [ "$i" -lt "$2" ]; do
    fm_write_meta "$home/state/ship-$i.meta" "kind=ship" "mode=no-mistakes"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$3" ]; do
    fm_write_secondmate_meta "$home/state/sm-$i.meta" "$home"
    i=$((i + 1))
  done
  printf '%s\n' "$home"
}

# make_probes <dir> <load1> <mem-free-pct> <cores> <avail-kb>: fake Darwin
# probes. An empty value makes that probe fail.
make_probes() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$fakebin/uname"
  cat > "$fakebin/sysctl" <<SH
#!/usr/bin/env bash
case "\$2" in
  vm.loadavg) [ -n "$2" ] && echo "{ $2 1.00 1.00 }" ;;
  kern.memorystatus_level) [ -n "$3" ] && echo "$3" ;;
  hw.logicalcpu) [ -n "$4" ] && echo "$4" ;;
  hw.memsize) [ -f "$fakebin/memsize" ] && cat "$fakebin/memsize" ;;
  kern.boottime) [ -f "$fakebin/boottime" ] && echo "{ sec = \$(cat "$fakebin/boottime"), usec = 0 } Thu Oct  8 21:11:00 2026" ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/getconf"
  cat > "$fakebin/df" <<SH
#!/usr/bin/env bash
[ -n "$5" ] || exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 999999999 1 $5 1% /"
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

run_capacity() {  # <home> <fakebin>
  PATH="$2:$BASE_PATH" FM_HOME="$1" "$CAPACITY" 2>&1
}

test_no_target_prints_counts_only() {
  local home fakebin out rc
  home=$(make_home no-target 3 1)
  fakebin=$(make_probes "$TMP_ROOT/p-no-target" 0.50 60 8 20971520)
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "absent target"
  assert_contains "$(printf '%s\n' "$out" | head -1)" \
    'capacity: free_lanes=unknown reason=no-target lanes=3 target=none secondmates=1 load1=0.50 cores=8 mem_free_pct=60 disk_free_mb=20480' \
    "absent target must report counts without inventing one"
  pass "absent config/lane-capacity reports counts and no target"
}

test_target_yields_open_lanes_and_full() {
  local home fakebin out
  home=$(make_home target 2 1)
  fakebin=$(make_probes "$TMP_ROOT/p-target" 0.50 60 8 20971520)
  printf '5\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin")
  assert_contains "$out" 'capacity: free_lanes=3 reason=ok lanes=2 target=5 secondmates=1 ' \
    "secondmates must not consume lanes"
  printf '2\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=full lanes=2 target=2' "target reached must be full"
  printf '1\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=full lanes=2 target=1' "over target must not go negative"
  pass "a target yields open lanes, full, and never a negative count"
}

test_host_constraints_close_lanes() {
  local home fakebin out
  home=$(make_home constrained 1 0)
  printf '6\n' > "$home/config/lane-capacity"
  fakebin=$(make_probes "$TMP_ROOT/p-cpu" 8.00 60 8 20971520)
  out=$(run_capacity "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=cpu ' "load at core count must constrain"
  fakebin=$(make_probes "$TMP_ROOT/p-all" 9.50 9 8 1048576)
  out=$(run_capacity "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=cpu,memory,disk ' "every constraint must be named"
  assert_contains "$out" 'Constrained: cpu,memory,disk' "human summary must name constraints"
  fakebin=$(make_probes "$TMP_ROOT/p-edge" 7.99 10 8 5242880)
  out=$(run_capacity "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=5 reason=ok ' "values just inside thresholds must not constrain"
  pass "cpu, memory, and disk pressure close every lane and are named"
}

test_unavailable_probes_degrade() {
  local home fakebin out rc
  home=$(make_home degrade 1 0)
  printf '4\n' > "$home/config/lane-capacity"
  fakebin=$(make_probes "$TMP_ROOT/p-none" "" "" "" "")
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "unavailable probes"
  assert_contains "$out" 'capacity: free_lanes=3 reason=ok lanes=1 target=4 secondmates=0 load1=unknown cores=unknown mem_free_pct=unknown disk_free_mb=unknown' \
    "unavailable probes must print unknown and not constrain"
  pass "unavailable probes print unknown and do not constrain"
}

test_invalid_target_is_reported() {
  local home fakebin out rc
  home=$(make_home invalid 1 0)
  fakebin=$(make_probes "$TMP_ROOT/p-invalid" 0.50 60 8 20971520)
  printf 'lots\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 1 "$rc" "invalid target"
  assert_contains "$out" 'free_lanes=unknown reason=invalid-target lanes=1 target=invalid' \
    "invalid target must not be guessed"
  assert_contains "$out" 'fm-capacity: config/lane-capacity: line 1: the first line must be the lane cap, one non-negative integer' \
    "invalid target must name the problem"
  local bad
  for bad in '3\n4\n' '1 2\n' '99999999999999999999\n'; do
    printf '%b' "$bad" >"$home/config/lane-capacity"
    out=$(run_capacity "$home" "$fakebin"); rc=$?
    expect_code 1 "$rc" "invalid target $bad"
    assert_contains "$out" 'reason=invalid-target' "target '$bad' must be rejected"
  done
  printf '  3 \n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  assert_contains "$out" 'target=3' "surrounding whitespace is tolerated"
  pass "a malformed target is reported, not guessed"
}

test_real_host_smoke() {
  local home out rc
  home=$(make_home real 0 0)
  out=$(FM_HOME="$home" "$CAPACITY" 2>&1); rc=$?
  expect_code 0 "$rc" "real host"
  case "$(printf '%s\n' "$out" | head -1)" in
    'capacity: free_lanes=unknown reason=no-target lanes=0 target=none secondmates=0 load1='*' cores='*' mem_free_pct='*' disk_free_mb='*) : ;;
    *) fail "real host line malformed: $out" ;;
  esac
  pass "real host probes produce a well-formed report"
}

# write_beat <file> <level> <avail-gb> <total-gb> <runq> <l1> <on-battery> [why]
# [disk-free-gb]: a lookout.beat 1.0 document with one disk row.
write_beat() {
  local why=${8:-} disk=${9:-500}
  local why_json='[]'
  [ -z "$why" ] || why_json="[\"$why\"]"
  cat > "$1" <<JSON
{"schema":"lookout.beat","schema_version":"1.0","host":"beat-host","os":"wsl","interval_s":15,
 "machine":{"id":"beat-host","status":"$2","load":{"l1":$6,"runq_per_core":$5},
  "mem":{"avail_gb":$3,"total_gb":$4,"swap_rate_pps_1m":0.5,"psi_some10":1.25},
  "disks":[{"label":"disk","free_gb":$disk}],"uptime_s":5000,"on_battery":$7,
  "pressure":{"level":"$2","why":$why_json},"beat":{"errors":[]}}}
JSON
}

# run_capacity_jq <home> <fakebin> [args]: like run_capacity, with jq reachable.
run_capacity_jq() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" "$CAPACITY" "$@" 2>&1
}

test_config_keys_parse_and_refuse_guessing() {
  local home fakebin out rc
  home=$(make_home keys 1 0)
  fakebin=$(make_probes "$TMP_ROOT/p-keys" 0.50 60 8 20971520)
  cat > "$home/config/lane-capacity" <<CFG
# lanes this home runs at once
4   # the cap
min-avail-gb 2.5
min-disk-gb 3
pressure-file $home/beat-a.json
pressure-file $home/beat-b.json
reserve-flag $home/reserved.flag tower reserved by the captain
captain-idle 300
max-load1 20
CFG
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "valid keyed config"
  assert_contains "$out" 'capacity: free_lanes=3 reason=ok lanes=1 target=4 ' "keyed config must keep the cap on its first line"
  printf '4\nmin-avail-gb 2\nenforce\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 1 "$rc" "unknown key"
  assert_contains "$out" "fm-capacity: config/lane-capacity: line 3: unknown key 'enforce'" "unknown key must be named with its line"
  assert_contains "$out" 'free_lanes=unknown reason=invalid-target lanes=1 target=invalid' "unknown key must invalidate the cap"
  printf '4\nmax-load1 20\nmax-load1 30\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 1 "$rc" "repeated key"
  assert_contains "$out" 'line 3: max-load1 appears more than once' "a repeated single key must be refused"
  printf '4\nmin-disk-gb lots\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 1 "$rc" "malformed value"
  assert_contains "$out" 'line 2: min-disk-gb needs a non-negative number' "a malformed value must be refused"
  printf 'min-avail-gb 2\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 1 "$rc" "missing cap"
  assert_contains "$out" 'line 1: the first line must be the lane cap' "a file without the cap first must be refused"
  printf '4\npressure-file relative/beat.json\n' > "$home/config/lane-capacity"
  out=$(run_capacity "$home" "$fakebin"); rc=$?
  expect_code 1 "$rc" "relative pressure file"
  assert_contains "$out" 'line 2: pressure-file takes one absolute path' "a relative pressure file must be refused"
  pass "keyed config lines parse, and unknown, repeated, or malformed lines are refused"
}

test_fresh_beat_replaces_probes() {
  local home fakebin out doc
  home=$(make_home beat 1 0)
  # Probes say constrained on load; a fresh ok beat replaces them.
  fakebin=$(make_probes "$TMP_ROOT/p-beat" 9.00 60 8 20971520)
  write_beat "$home/beat.json" ok 13.5 25.2 0.29 24.7 false
  printf '4\npressure-file %s\n' "$home/beat.json" > "$home/config/lane-capacity"
  out=$(run_capacity_jq "$home" "$fakebin")
  assert_contains "$out" 'capacity: free_lanes=3 reason=ok lanes=1 target=4 secondmates=0 load1=9.00 cores=8 ' \
    "a fresh ok beat must replace the raw load probe"
  assert_contains "$out" 'Pressure: ok from beat.' "the summary must name the beat basis"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'beat|ok|13.5|25.2|0.29|0.5|1.25|24.7|false|disk:500|beat-host' \
    "$(printf '%s\n' "$doc" | jq -r '.pressure | [.basis,.level,.avail_gb,.total_gb,.runq_per_core,.swap_rate_pps_1m,.mem_stall_pct,.load1,.on_battery,(.disks[0] | "\(.label):\(.free_gb)")] | join("|")')|$(printf '%s\n' "$doc" | jq -r .machine)" \
    "the document must carry the beat's own numbers and host"
  write_beat "$home/beat.json" warn 13.5 25.2 0.29 2.0 false "swapping 410 pages/s"
  out=$(run_capacity_jq "$home" "$fakebin")
  assert_contains "$out" 'free_lanes=0 reason=pressure ' "a warn beat must close lanes"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'false|pressure warn: swapping 410 pages/s' \
    "$(printf '%s\n' "$doc" | jq -r '"\(.verdict.admit)|\(.verdict.reasons | join(","))"')" \
    "the verdict must refuse with the beat's reason"
  pass "a fresh beat replaces probes, and its warn level closes lanes with its reason"
}

test_late_stale_missing_and_malformed_beats() {
  local home fakebin out doc now
  home=$(make_home stale 1 0)
  fakebin=$(make_probes "$TMP_ROOT/p-stale" 0.50 60 8 20971520)
  now=$(date +%s)
  printf '4\npressure-file %s\n' "$home/beat.json" > "$home/config/lane-capacity"
  write_beat "$home/beat.json" ok 13.5 25.2 0.29 2.0 false
  fm_touch_epoch "$((now - 45))" "$home/beat.json"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'beat|true' "$(printf '%s\n' "$doc" | jq -r '"\(.pressure.basis)|\(.pressure.why | any(test("^beat-host: beat 4[5-9] s old$")))"')" \
    "a late beat must still count, with its age in why"
  fm_touch_epoch "$((now - 600))" "$home/beat.json"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'probe|ok|true' "$(printf '%s\n' "$doc" | jq -r '"\(.pressure.basis)|\(.pressure.level)|\(.pressure.why | any(test("^beat-host: beat 60[0-9] s old$")))"')" \
    "a stale beat must fall back to probes with its age in why"
  out=$(run_capacity_jq "$home" "$fakebin")
  assert_contains "$out" 'capacity: free_lanes=3 reason=ok ' "a stale beat must not close lanes"
  rm -f "$home/beat.json"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'probe|pressure-file 1: beat absent' "$(printf '%s\n' "$doc" | jq -r '"\(.pressure.basis)|\(.pressure.why | join(","))"')" \
    "a missing beat must fall back to probes"
  printf '{not json' > "$home/beat.json"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'probe|pressure-file 1: beat unreadable' "$(printf '%s\n' "$doc" | jq -r '"\(.pressure.basis)|\(.pressure.why | join(","))"')" \
    "a malformed beat must fall back to probes"
  printf '{"schema":"lookout.beat","schema_version":"2.0","machine":{}}' > "$home/beat.json"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'probe|pressure-file 1: not a lookout.beat 1.x document' "$(printf '%s\n' "$doc" | jq -r '"\(.pressure.basis)|\(.pressure.why | join(","))"')" \
    "a foreign document must fall back to probes"
  fakebin=$(make_probes "$TMP_ROOT/p-stale-none" "" "" "" "")
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'none|unknown|true' "$(printf '%s\n' "$doc" | jq -r '"\(.pressure.basis)|\(.pressure.level)|\(.verdict.admit)"')" \
    "no beat and no probe must leave pressure unknown without refusing"
  pass "late beats count, and stale, missing, malformed, or foreign beats fall back to probes"
}

test_several_pressure_files() {
  local home fakebin doc
  home=$(make_home several 0 0)
  fakebin=$(make_probes "$TMP_ROOT/p-several" 0.50 60 8 20971520)
  write_beat "$home/vm.json" ok 13.5 25.2 0.29 2.0 false "" 700
  write_beat "$home/win.json" critical 2.0 64 1.5 9.0 false "memory 6% available" 40
  printf '4\nmin-disk-gb 60\npressure-file %s\npressure-file %s\n' "$home/vm.json" "$home/win.json" > "$home/config/lane-capacity"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'critical|13.5|2|beat-host: memory 6% available' \
    "$(printf '%s\n' "$doc" | jq -r '.pressure | "\(.level)|\(.avail_gb)|\(.disks | length)|\(.why | join(","))"')" \
    "the worst fresh level must win while the first fresh file supplies memory"
  assert_equals 'disk: beat-host disk 40 GB free, under 60 GB,pressure critical: beat-host: memory 6% available' \
    "$(printf '%s\n' "$doc" | jq -r '.verdict.reasons | join(",")')" "every fresh disk row must count against min-disk-gb"
  pass "several pressure files: worst level wins, first supplies memory, every disk counts"
}

test_limits_and_admit() {
  local home fakebin out rc
  home=$(make_home limits 1 0)
  fakebin=$(make_probes "$TMP_ROOT/p-limits" 0.50 60 8 20971520)
  out=$(run_capacity_jq "$home" "$fakebin" --admit); rc=$?
  expect_code 0 "$rc" "admit without config"
  assert_equals '' "$out" "admit without config must change nothing"
  write_beat "$home/beat.json" ok 5.5 25.2 0.29 24.7 true "" 50
  cat > "$home/config/lane-capacity" <<CFG
4
min-avail-gb 5
min-disk-gb 60
max-load1 20
pressure-file $home/beat.json
reserve-flag $home/reserved.flag tower reserved by the captain
CFG
  : > "$home/reserved.flag"
  out=$(run_capacity_jq "$home" "$fakebin")
  assert_contains "$out" 'capacity: free_lanes=0 reason=memory,disk,load,reserve,battery ' "every limit must be named in order"
  out=$(run_capacity_jq "$home" "$fakebin" --admit); rc=$?
  expect_code 75 "$rc" "admit under limits"
  assert_contains "$out" 'deferred: lane capacity of this home' "a deferral must print one deferred line"
  assert_contains "$out" 'memory: no room for a 1 GB lane: 5.5 GB available, 5 GB kept; disk: disk 50 GB free, under 60 GB; load: 24.7 over its max-load1 20; captain reserve: tower reserved by the captain; on battery' \
    "the deferral must give every reason in words"
  write_beat "$home/beat.json" ok 13.5 25.2 0.29 2.0 false "" 500
  rm -f "$home/reserved.flag"
  out=$(run_capacity_jq "$home" "$fakebin" --admit); rc=$?
  expect_code 0 "$rc" "admit when clear"
  printf '1\n' > "$home/config/lane-capacity"
  out=$(run_capacity_jq "$home" "$fakebin" --admit); rc=$?
  expect_code 75 "$rc" "admit when full"
  assert_contains "$out" 'full: 1 of 1 lanes' "a full home must say so"
  printf '1\nbogus 1\n' > "$home/config/lane-capacity"
  out=$(run_capacity_jq "$home" "$fakebin" --admit); rc=$?
  expect_code 1 "$rc" "admit with invalid config"
  pass "limits close lanes with named reasons, and --admit exits 0, 75, or 1"
}

test_publish_document() {
  local home fakebin rc doc mode i
  home=$(make_home publish 2 1)
  fakebin=$(make_probes "$TMP_ROOT/p-publish" 0.50 60 8 20971520)
  printf '%s\n' 34359738368 > "$fakebin/memsize"
  printf '%s\n' 1791484127 > "$fakebin/boottime"
  fm_write_meta "$home/state/ship-1.meta" "kind=ship" "mode=no-mistakes" "pr=https://github.com/o/r/pull/9"
  printf 'pc-lanes\n' > "$home/.fm-secondmate-home"
  mkdir -p "$home/projects/alpha" "$home/projects/beta"
  touch "$home/state/.last-watcher-beat"
  run_capacity_jq "$home" "$fakebin" --publish >/dev/null; rc=$?
  expect_code 0 "$rc" "publish without config"
  assert_absent "$home/state/lane-capacity.json" "no config must publish nothing"
  printf '6\nmin-avail-gb 4\n' > "$home/config/lane-capacity"
  FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 run_capacity_jq "$home" "$fakebin" --publish >/dev/null; rc=$?
  expect_code 0 "$rc" "publish"
  doc=$(cat "$home/state/lane-capacity.json")
  assert_equals 'fm-lane-capacity.v1|pc-lanes|2|1|ship-0,ship-1|6|ok|alpha,beta|probe|19.2|32|0.06|4|null|null' \
    "$(printf '%s\n' "$doc" | jq -r '[.schema,.home,.lanes.count,.lanes.pr_ready,(.lanes.ids | join(",")),.cap.target,.cap.status,(.projects | join(",")),.pressure.basis,.pressure.avail_gb,.pressure.total_gb,.pressure.runq_per_core,.limits.min_avail_gb,.limits.max_load1,.quota] | map(tostring) | join("|")')" \
    "the published document must carry lanes, cap, projects, and probe pressure"
  assert_equals 'true|4|not-configured|not-configured|1791484127|[1791484127]|true' \
    "$(printf '%s\n' "$doc" | jq -r '[.verdict.admit,.verdict.free_lanes,.reserve.flag,.captain,.boot_id,(.boots | tojson),(.watcher_beat_age_s < 60)] | map(tostring) | join("|")')" \
    "the published document must carry the verdict, boots, and watcher age"
  mode=$(stat -c %a "$home/state/lane-capacity.json" 2>/dev/null || /usr/bin/stat -f %Lp "$home/state/lane-capacity.json")
  assert_equals 600 "$mode" "the published document must be private"
  # A young document is not republished; a new boot is appended, ten kept.
  printf '%s\n' 1791500000 > "$fakebin/boottime"
  run_capacity_jq "$home" "$fakebin" --publish >/dev/null
  assert_equals '[1791484127]' "$(jq -c .boots "$home/state/lane-capacity.json")" "a young document must not be republished"
  i=1
  while [ "$i" -le 11 ]; do
    printf '%s\n' "$((1791500000 + i))" > "$fakebin/boottime"
    FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 run_capacity_jq "$home" "$fakebin" --publish >/dev/null
    i=$((i + 1))
  done
  FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 run_capacity_jq "$home" "$fakebin" --publish >/dev/null
  assert_equals '10|1791500002|1791500011' "$(jq -r '"\(.boots | length)|\(.boots[0])|\(.boots[-1])"' "$home/state/lane-capacity.json")" \
    "boots must append only on a new boot and keep the last ten"
  printf '6\nlanes 3\n' > "$home/config/lane-capacity"
  FM_LANE_CAPACITY_PUBLISH_INTERVAL=0 run_capacity_jq "$home" "$fakebin" --publish >/dev/null; rc=$?
  expect_code 0 "$rc" "publish with invalid config"
  assert_equals 'invalid|null|false' "$(jq -r '"\(.cap.status)|\(.cap.target)|\(.verdict.admit)"' "$home/state/lane-capacity.json")" \
    "an invalid config must be published as invalid"
  pass "publish is opt-in, private, throttled, records boots, and publishes an invalid config as invalid"
}

test_captain_and_quota() {
  local home fakebin doc
  home=$(make_home captain 0 0)
  fakebin=$(make_probes "$TMP_ROOT/p-captain" 0.50 60 8 20971520)
  cat > "$fakebin/ioreg" <<SH
#!/usr/bin/env bash
echo "    | |   \\"HIDIdleTime\\" = \$(cat "$fakebin/idle-ns")"
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
echo '{"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"model:x","runway":{"status":"exhausted_now"}},{"scope":"all_models","runway":{"status":"projected_exhaustion"}}]}}]}'
SH
  chmod +x "$fakebin/ioreg" "$fakebin/quota-axi"
  printf '3\ncaptain-idle 300\nquota-provider claude\n' > "$home/config/lane-capacity"
  printf '%s\n' 12000000000 > "$fakebin/idle-ns"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'present|{"provider":"claude","runway":"projected_exhaustion"}' \
    "$(printf '%s\n' "$doc" | jq -c -r '"\(.captain)|\(.quota | tojson)"')" "recent input must read present, quota its all-models runway"
  printf '%s\n' 900000000000 > "$fakebin/idle-ns"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals idle "$(printf '%s\n' "$doc" | jq -r .captain)" "old input must read idle"
  printf 'version: 2\nwords: |\n  gone\n' > "$home/state/.afk-contract"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals away "$(printf '%s\n' "$doc" | jq -r .captain)" "an away record must read away"
  printf '%s\n' "$doc" > "$TMP_ROOT/captain-doc.json"
  assert_no_grep 900000 "$TMP_ROOT/captain-doc.json" "raw idle time must never be published"
  assert_no_grep HIDIdleTime "$TMP_ROOT/captain-doc.json" "raw idle input must never be published"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/quota-axi"
  rm -f "$home/state/.afk-contract" "$fakebin/ioreg"
  doc=$(run_capacity_jq "$home" "$fakebin" --json)
  assert_equals 'unknown|unknown' "$(printf '%s\n' "$doc" | jq -r '"\(.captain)|\(.quota.runway)"')" \
    "unreadable presence and quota must read unknown"
  pass "captain presence and quota runway publish derived words only, unknown when unreadable"
}

# start_watcher <home>: run the real watcher for that home in the background;
# the suite's cleanup stops it through the arm script.
start_watcher() {
  fm_test_track_watcher_state "$1/state"
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1 &
}

stop_watcher() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
}

test_watcher_publishes_only_when_opted_in() {
  local on off i
  on=$(make_home watch-on 1 0)
  off=$(make_home watch-off 1 0)
  printf '3\n' > "$on/config/lane-capacity"
  start_watcher "$on"
  start_watcher "$off"
  i=0
  while [ "$i" -lt 150 ] && { [ ! -s "$on/state/lane-capacity.json" ] || [ ! -e "$off/state/.last-watcher-beat" ]; }; do
    sleep 0.1
    i=$((i + 1))
  done
  sleep 2
  stop_watcher "$on"
  stop_watcher "$off"
  assert_present "$off/state/.last-watcher-beat" "the unconfigured watcher must have polled"
  assert_absent "$off/state/lane-capacity.json" "an unconfigured home must publish nothing"
  # The verdict depends on this real host's probes, so only its presence is asserted.
  assert_equals 'fm-lane-capacity.v1|3|true' \
    "$(jq -r '"\(.schema)|\(.cap.target)|\(.verdict.admit | type == "boolean")"' "$on/state/lane-capacity.json" 2>/dev/null)" \
    "the opted-in watcher must publish this home's facts"
  pass "the watcher publishes lane facts only for an opted-in home"
}

test_no_target_prints_counts_only
test_target_yields_open_lanes_and_full
test_host_constraints_close_lanes
test_unavailable_probes_degrade
test_invalid_target_is_reported
test_config_keys_parse_and_refuse_guessing
test_fresh_beat_replaces_probes
test_late_stale_missing_and_malformed_beats
test_several_pressure_files
test_limits_and_admit
test_publish_document
test_captain_and_quota
test_watcher_publishes_only_when_opted_in
test_real_host_smoke

echo '# all fm-capacity tests passed'
