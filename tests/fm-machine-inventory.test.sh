#!/usr/bin/env bash
# Behavior tests for bin/fm-machine-inventory.sh.
#
# The command is intentionally silent only when each host-wide category is
# measured and stays within its threshold.
# These tests drive its executable interface through fake host tools, proving
# old listeners, load, containers, simulators, agent processes, and unavailable
# measurement surfaces are reported without ever invoking a lifecycle command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INVENTORY="$ROOT/bin/fm-machine-inventory.sh"
TMP_ROOT=$(fm_test_tmproot fm-machine-inventory)

make_case() {  # <name> -> case root with fake host tools
  local case_dir=$TMP_ROOT/$1
  mkdir -p "$case_dir/fakebin" "$case_dir/home/Library/Developer/CoreSimulator/Devices"
  : > "$case_dir/home/Library/Developer/CoreSimulator/Devices/device_set.plist"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case "${FM_INVENTORY_LSOF:-quiet}" in
  listener)
    case " $* " in *' -iTCP '*) printf 'p101\nccodex\nn*:4310\n' ;; *) printf 'p102\nccnode\nn*:5353\nn*:*\nn192.168.1.129:51898->142.251.157.119:443\n' ;; esac ;;
  error) echo 'lsof fixture error' >&2; exit 2 ;;
  warning)
    printf '%s\n' "lsof: WARNING: can't stat() smbfs file system /Volumes/.timemachine/fixture" '      Output information may be incomplete.' >&2
    case " $* " in *' -iTCP '*) printf 'p101\nccodex\nn*:4310\n' ;; *) printf 'p102\nccnode\nn*:5353\n' ;; esac ;;
esac
SH
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
claude='/Users/me/Library/Application Support/Claude/claude-code/claude.app/Contents/MacOS/claude'
case "${2:-}" in
  pid=,etime=,comm=)
    printf '  101 2-00:00:00 /usr/local/bin/devserver\n  102 2-00:00:00 /usr/sbin/mdns-fixture\n'
    [ "${FM_INVENTORY_PS:-quiet}" = agent ] && printf '  202 2-00:00:00 codex\n  203 3-00:00:00 %s\n' "$claude" ;;
  pid=,command=)
    printf '  101 devserver --port 4310\n  102 mdns-fixture\n'
    [ "${FM_INVENTORY_PS:-quiet}" = agent ] && printf '  202 /opt/homebrew/bin/codex --resume\n  203 %s --resume\n' "$claude" ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -k ] && shift 2
shift
for word in ${FM_INVENTORY_TIMEOUT:-}; do
  for arg; do
    [ "$arg" = "$word" ] && exit 124
  done
done
exec "$@"
SH
  cat > "$case_dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ps)
    case "${FM_INVENTORY_DOCKER:-quiet}" in
      old) printf 'abc123\tforgotten\n' ;;
      hang) printf '%s\n' "$$" > "$(dirname "$0")/../docker-started"; exec sleep 30 ;;
    esac
    exit 0 ;;
  inspect) printf '%s\n' '2026-09-10T00:00:00.000000000Z' ;;
esac
SH
  cat > "$case_dir/fakebin/xcrun" <<'SH'
#!/usr/bin/env bash
[ "${2:-}" = --set ] || { echo 'xcrun fixture requires --set' >&2; exit 1; }
case "$3" in
  */CoreSimulator/Devices)
    if [ "${FM_INVENTORY_SIMULATOR:-quiet}" = booted ]; then
      cat <<'JSON'
{ "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
  { "udid": "00000000-0000-0000-0000-000000000001", "name": "iPhone 16", "state": "Booted", "lastBootedAt": "2026-09-10T00:00:00Z" },
  { "udid": "00000000-0000-0000-0000-000000000002", "name": "iPhone Fresh", "state": "Booted", "lastBootedAt": "2026-09-12T23:55:00Z" },
  { "udid": "00000000-0000-0000-0000-000000000003", "name": "iPhone Off", "state": "Shutdown", "lastBootedAt": "2026-09-01T00:00:00Z" }
] } }
JSON
    else
      printf '%s\n' '{ "devices": {} }'
    fi ;;
  *) printf '{ "devices": { "iOS": [ { "udid": "00000000-0000-0000-0000-0000000000C1", "name": "%s", "state": "Booted", "lastBootedAt": "2026-09-10T00:00:00Z" } ] } }\n' "${3##*/}" ;;
esac
SH
  cat > "$case_dir/fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
[ "${2:-}" = vm.loadavg ] && printf '{ 1.00 2.00 %s }\n' "${FM_INVENTORY_LOAD15:-1.00}"
exit 0
SH
  cat > "$case_dir/fakebin/getconf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 10
SH
  cat > "$case_dir/fakebin/id" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_INVENTORY_UID:-0}"
SH
  cat > "$case_dir/fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != -j ]; then printf '%s\n' 1789257600; exit 0; fi
case "$*" in *T23:55:00*) printf '%s\n' 1789257300 ;; *) printf '%s\n' 1788998400 ;; esac
SH
  chmod +x "$case_dir/fakebin"/*
  printf '%s\n' "$case_dir"
}

run_inventory() {  # <case-dir>
  HOME="$1/home" PATH="$1/fakebin:$PATH" "$INVENTORY"
}

test_silent_when_everything_is_measured_and_healthy() {
  local case_dir output rc
  case_dir=$(make_case quiet)
  set +e
  output=$(run_inventory "$case_dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "healthy inventory exited $rc: $output"
  [ -z "$output" ] || fail "healthy inventory was not silent: $output"
  pass 'healthy complete inventory is silent'
}

test_reports_old_listener_with_age_and_owner() {
  local case_dir output
  case_dir=$(make_case listener)
  output=$(FM_INVENTORY_LSOF=listener run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'LISTENER: protocol=TCP pid=101 age=2-00:00:00 command=codex endpoint=*:4310' 'old listener omitted age, owner, or endpoint'
  assert_contains "$output" 'LISTENER: protocol=UDP pid=102 age=2-00:00:00 command=cnode endpoint=*:5353' 'old bound UDP socket was omitted'
  assert_not_contains "$output" 'endpoint=*:*' 'unbound UDP socket was reported as a listener'
  assert_not_contains "$output" '->' 'connected UDP client socket was reported as a listener'
  pass 'old whole-host listener names its age and owner'
}

test_non_root_listener_scan_reports_other_users_as_unmeasured() {
  local case_dir output
  case_dir=$(make_case non-root)
  output=$(FM_INVENTORY_UID=501 FM_INVENTORY_LSOF=listener run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'NOT CHECKED: TCP network sockets owned by other users (not run as root)' 'non-root TCP scan claimed whole-host coverage'
  assert_contains "$output" 'NOT CHECKED: UDP network sockets owned by other users (not run as root)' 'non-root UDP scan claimed whole-host coverage'
  assert_contains "$output" 'LISTENER: protocol=TCP pid=101' 'non-root scan dropped the sockets it could see'
  pass 'non-root listener scan narrows its claim to the caller'
}

test_reports_each_other_leak_class() {
  local case_dir output
  case_dir=$(make_case leaks)
  output=$(FM_INVENTORY_LOAD15=31.00 FM_INVENTORY_PS=agent FM_INVENTORY_DOCKER=old FM_INVENTORY_SIMULATOR=booted run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'LOAD: fifteen-minute=31.00 cores=10' 'ten-core host at fifteen-minute load 31 was omitted'
  assert_contains "$output" 'CONTAINER: id=abc123 name=forgotten uptime=259200s' 'old container was omitted'
  assert_contains "$output" "SIMULATOR: set=$case_dir/home/Library/Developer/CoreSimulator/Devices udid=00000000-0000-0000-0000-000000000001 name=iPhone 16 uptime=259200s" 'old booted simulator was omitted'
  assert_not_contains "$output" 'iPhone Fresh' 'recently booted simulator was reported'
  assert_not_contains "$output" 'iPhone Off' 'shutdown simulator was reported'
  assert_contains "$output" 'AGENT: pid=202 age=2-00:00:00 command=/opt/homebrew/bin/codex' 'old agent process was omitted'
  assert_contains "$output" 'AGENT: pid=203 age=3-00:00:00 command=/Users/me/Library/Application Support/Claude/claude-code/claude.app/Contents/MacOS/claude' 'agent executable path with spaces was truncated'
  pass 'load, containers, simulators, and agent processes report violations'
}

test_discovers_simulator_device_sets() {
  local case_dir output developer previews
  case_dir=$(make_case simulator-sets)
  if [ "$(id -u)" = 0 ]; then
    pass 'discovered simulator device sets are scanned or reported unreadable (skipped as root)'
    return 0
  fi
  developer="$case_dir/home/Library/Developer"
  previews="$developer/Xcode/UserData/Previews/Simulator Devices"
  mkdir -p "$developer/XCPGDevices" "$previews" "$developer/Xcode/DerivedData" "$case_dir/external/XCTestDevices"
  : > "$developer/XCPGDevices/device_set.plist"
  : > "$case_dir/external/XCTestDevices/device_set.plist"
  ln -s "$case_dir/external/XCTestDevices" "$developer/XCTestDevices"
  : > "$previews/device_set.plist"
  chmod 000 "$previews/device_set.plist" "$developer/Xcode/DerivedData"
  output=$(run_inventory "$case_dir" 2>&1 || true)
  chmod 755 "$developer/Xcode/DerivedData"
  chmod 644 "$previews/device_set.plist"
  assert_contains "$output" "SIMULATOR: set=$developer/XCPGDevices udid=00000000-0000-0000-0000-0000000000C1 name=XCPGDevices uptime=259200s" 'old booted simulator in a discovered set was omitted'
  assert_contains "$output" "SIMULATOR: set=$developer/XCTestDevices udid=00000000-0000-0000-0000-0000000000C1 name=XCTestDevices uptime=259200s" 'old booted simulator in a symlinked device set was omitted'
  assert_contains "$output" "NOT CHECKED: booted simulators set=$previews (device set unreadable)" 'unreadable discovered device set was silent'
  assert_contains "$output" "NOT CHECKED: booted simulator device set discovery under $developer (query failed)" 'unreadable discovery subtree was silent'
  pass 'discovered simulator device sets are scanned or reported unreadable'
}

test_reports_incomplete_measurement_instead_of_claiming_the_host_is_clean() {
  local case_dir output
  case_dir=$(make_case incomplete)
  output=$(FM_INVENTORY_LSOF=error run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'NOT CHECKED: TCP network sockets (lsof query incomplete)' 'failed TCP scan was silent'
  assert_contains "$output" 'NOT CHECKED: UDP network sockets (lsof query incomplete)' 'failed UDP scan was silent'
  pass 'incomplete listener scan narrows the claim visibly'
}

test_lsof_warning_keeps_measured_listeners() {
  local case_dir output
  case_dir=$(make_case lsof-warning)
  output=$(FM_INVENTORY_LSOF=warning run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'LISTENER: protocol=TCP pid=101 age=2-00:00:00 command=codex endpoint=*:4310' 'lsof warning discarded a measured TCP listener'
  assert_contains "$output" 'LISTENER: protocol=UDP pid=102 age=2-00:00:00 command=cnode endpoint=*:5353' 'lsof warning discarded a measured UDP listener'
  assert_contains "$output" "NOT CHECKED: TCP network sockets possibly omitted by lsof warning (lsof: WARNING: can't stat() smbfs file system /Volumes/.timemachine/fixture)" 'TCP lsof warning was silent'
  assert_contains "$output" "NOT CHECKED: UDP network sockets possibly omitted by lsof warning (lsof: WARNING: can't stat() smbfs file system /Volumes/.timemachine/fixture)" 'UDP lsof warning was silent'
  assert_not_contains "$output" 'lsof query incomplete' 'warned but successful lsof query was reported as failed'
  pass 'lsof warning keeps measured listeners and names the possible gap'
}

test_reports_timed_out_queries() {
  local case_dir developer output
  case_dir=$(make_case timeouts)
  developer="$case_dir/home/Library/Developer"
  output=$(FM_INVENTORY_TIMEOUT='lsof inspect find' FM_INVENTORY_DOCKER=old run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'NOT CHECKED: TCP network sockets (lsof query timed out)' 'timed-out TCP scan was silent'
  assert_contains "$output" 'NOT CHECKED: UDP network sockets (lsof query timed out)' 'timed-out UDP scan was silent'
  assert_contains "$output" 'NOT CHECKED: running container id=abc123 name=forgotten uptime (query timed out)' 'timed-out container inspect was silent'
  assert_contains "$output" "NOT CHECKED: booted simulator device set discovery under $developer (query timed out)" 'timed-out device set discovery was silent'
  output=$(FM_INVENTORY_TIMEOUT='ps xcrun' run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'NOT CHECKED: process table (query timed out)' 'timed-out process table was silent'
  assert_contains "$output" 'NOT CHECKED: agent processes (process table unavailable)' 'agent scan claimed coverage without a process table'
  assert_contains "$output" 'NOT CHECKED: running containers (query timed out)' 'timed-out container listing was silent'
  assert_contains "$output" "NOT CHECKED: booted simulators set=$developer/CoreSimulator/Devices (query timed out)" 'timed-out simulator query was silent'
  pass 'every bounded query reports its timeout as NOT CHECKED'
}

test_interrupted_scan_does_not_exit_clean() {
  local case_dir output pid query_pid rc=0 tries=0
  case_dir=$(make_case interrupted)
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_INVENTORY_LOAD15=31.00 FM_INVENTORY_DOCKER=hang HOME="$case_dir/home" PATH="$case_dir/fakebin:$PATH" "$INVENTORY" > "$case_dir/output" 2>&1 &
  pid=$!
  while [ ! -s "$case_dir/docker-started" ] && [ "$tries" -lt 100 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  [ -s "$case_dir/docker-started" ] || fail 'interrupt fixture never reached the container scan'
  query_pid=$(cat "$case_dir/docker-started")
  kill -TERM "$pid"
  wait "$pid" || rc=$?
  output=$(cat "$case_dir/output")
  [ "$rc" -eq 143 ] || fail "TERM-interrupted inventory exited $rc: $output"
  tries=0
  while kill -0 "$query_pid" 2>/dev/null && [ "$tries" -lt 20 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 "$query_pid" 2>/dev/null; then
    kill -KILL "$query_pid" 2>/dev/null
    fail 'interrupted run left its in-flight query running'
  fi
  assert_contains "$output" 'LOAD: fifteen-minute=31.00 cores=10' 'interrupt discarded an already measured finding'
  assert_contains "$output" 'NOT CHECKED: containers scan (interrupted)' 'interrupted scan was not named'
  assert_contains "$output" 'NOT CHECKED: simulators scan (interrupted)' 'scan skipped by the interrupt was not named'
  assert_contains "$output" 'NOT CHECKED: agent processes scan (interrupted)' 'scan skipped by the interrupt was not named'
  assert_not_contains "$output" 'load scan (interrupted)' 'completed scan was reported as interrupted'
  pass 'interrupted scan prints collected findings, names unfinished scans, and exits with the signal status'
}

test_silent_when_everything_is_measured_and_healthy
test_reports_old_listener_with_age_and_owner
test_non_root_listener_scan_reports_other_users_as_unmeasured
test_reports_each_other_leak_class
test_discovers_simulator_device_sets
test_reports_incomplete_measurement_instead_of_claiming_the_host_is_clean
test_lsof_warning_keeps_measured_listeners
test_reports_timed_out_queries
test_interrupted_scan_does_not_exit_clean
