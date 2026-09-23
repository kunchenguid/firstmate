#!/usr/bin/env bash
# Behavioral coverage for bin/fm-capacity.sh: lane counting from task metadata,
# the optional config/lane-capacity target, host-constraint verdicts from faked
# probes, graceful degradation when probes are unavailable, and a real-host smoke.
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
  assert_contains "$out" 'fm-capacity: config/lane-capacity must hold one non-negative integer' \
    "invalid target must name the problem"
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

test_no_target_prints_counts_only
test_target_yields_open_lanes_and_full
test_host_constraints_close_lanes
test_unavailable_probes_degrade
test_invalid_target_is_reported
test_real_host_smoke

echo '# all fm-capacity tests passed'
