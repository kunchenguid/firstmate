#!/usr/bin/env bash
# tests/fm-mate-view.test.sh - tests for bin/fm-mate-view.sh
#
# Covers:
#   - Happy path: parallel inspection of remote and local second mates
#   - Unreachable host: ssh exit 255 prints clear line without failing command
#   - Remote copy missing fm-host-report.sh: prints actionable update advice
#   - Local mate: runs report against local FM_HOME
#   - Argument filtering: specific IDs or unknown ID error
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-mate-view)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

MATE_VIEW="$ROOT/bin/fm-mate-view.sh"

# ----------------------------------------------------------------------------
# Test 1: Happy path (both remote and local second mates)
# ----------------------------------------------------------------------------
test_happy_path() {
  local home="$TMP_ROOT/happy-home"
  local local_mate="$TMP_ROOT/happy-local-mate"
  mkdir -p "$home/data" "$home/state" "$local_mate/data" "$local_mate/state"

  # Create secondmates.md registry
  cat > "$home/data/secondmates.md" <<EOF
- remote-one - Remote worker (host: mac-mini; root: /remote/root; home: /remote/home; scope: test; projects: p1; added 2026-09-01)
- local-one - Local worker (home: $local_mate; scope: test; projects: p2; added 2026-09-01)
EOF

  # Create fake fm-on.sh
  local fake_on="$TMP_ROOT/fake-on-happy.sh"
  cat > "$fake_on" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
cmd=$2
shift 2
if [ "$cmd" = "fm-host-report.sh" ]; then
  cat <<REPORT
# Host Report: remote-host-mini
Home: /remote/home
Code root: /remote/root

## System
Uptime: 5 days, load: 0.45 0.32 0.28 (8 CPUs)
Disk: 150Gi free of 500Gi (30% used)
Memory: 16Gi total, 8Gi free

## Revision
Revision: 1a2b3c4d (main, up to date with origin/main)

## Supervision
Beacon: 12s ago

## Live Agents
  none

## Work
in-flight: 0, queued: 1, done: 5

## Status Logs
  none
REPORT
  exit 0
elif [ "$cmd" = "fm-remote-secondmate-control.sh" ] && [ "${1:-}" = "capture" ]; then
  printf 'remote terminal line 1\nremote terminal line 2\n'
  exit 0
fi
exit 1
SH
  chmod +x "$fake_on"

  local out
  out=$(FM_HOME="$home" FM_ON_OVERRIDE="$fake_on" "$MATE_VIEW")
  local rc=$?

  [ "$rc" -eq 0 ] || fail "happy path failed with exit $rc"
  assert_contains "$out" "=== Secondmate: remote-one (remote: mac-mini) ===" "missing remote header"
  assert_contains "$out" "=== Secondmate: local-one (local: $local_mate) ===" "missing local header"
  assert_contains "$out" "Host Report: remote-host-mini" "missing remote host report"
  assert_contains "$out" "## Terminal Screen (last 20 lines)" "missing terminal screen section"
  assert_contains "$out" "remote terminal line 1" "missing remote screen capture content"

  pass "happy path inspects remote and local second mates"
}

# ----------------------------------------------------------------------------
# Test 2: Unreachable host (ssh exit 255)
# ----------------------------------------------------------------------------
test_unreachable_host() {
  local home="$TMP_ROOT/unreachable-home"
  mkdir -p "$home/data" "$home/state"

  cat > "$home/data/secondmates.md" <<EOF
- remote-down - Down worker (host: offline-box; root: /remote/root; home: /remote/home; scope: test; projects: p1; added 2026-09-01)
EOF

  local fake_on="$TMP_ROOT/fake-on-unreachable.sh"
  cat > "$fake_on" <<'SH'
#!/usr/bin/env bash
set -u
echo "ssh: connect to host offline-box port 22: Operation timed out" >&2
exit 255
SH
  chmod +x "$fake_on"

  local out
  out=$(FM_HOME="$home" FM_ON_OVERRIDE="$fake_on" "$MATE_VIEW")
  local rc=$?

  [ "$rc" -eq 0 ] || fail "unreachable host must not fail the overall command (got exit $rc)"
  assert_contains "$out" "=== Secondmate: remote-down (remote: offline-box) ===" "missing remote header"
  assert_contains "$out" "offline-box: unreachable (ssh exit 255)" "missing unreachable line"

  pass "unreachable host prints ssh exit 255 without failing the command"
}

# ----------------------------------------------------------------------------
# Test 3: Remote copy missing fm-host-report.sh
# ----------------------------------------------------------------------------
test_missing_report_script() {
  local home="$TMP_ROOT/missing-home"
  mkdir -p "$home/data" "$home/state"

  cat > "$home/data/secondmates.md" <<EOF
- remote-old - Old worker (host: unupdated-box; root: /remote/root; home: /remote/home; scope: test; projects: p1; added 2026-09-01)
EOF

  local fake_on="$TMP_ROOT/fake-on-missing.sh"
  cat > "$fake_on" <<'SH'
#!/usr/bin/env bash
set -u
echo "error: not a genuine executable in the configured remote root: fm-host-report.sh" >&2
exit 1
SH
  chmod +x "$fake_on"

  local out
  out=$(FM_HOME="$home" FM_ON_OVERRIDE="$fake_on" "$MATE_VIEW")
  local rc=$?

  [ "$rc" -eq 0 ] || fail "missing report script must not fail the overall command (got exit $rc)"
  assert_contains "$out" "=== Secondmate: remote-old (remote: unupdated-box) ===" "missing remote header"
  assert_contains "$out" "remote copy lacks fm-host-report.sh; update that host" "missing update advice"

  pass "missing remote report script prints update advice"
}

# ----------------------------------------------------------------------------
# Test 4: Local mate inspection
# ----------------------------------------------------------------------------
test_local_mate() {
  local home="$TMP_ROOT/local-only-home"
  local local_mate="$TMP_ROOT/local-only-mate"
  mkdir -p "$home/data" "$home/state" "$local_mate/data" "$local_mate/state"

  cat > "$home/data/secondmates.md" <<EOF
- local-worker - Local mate (home: $local_mate; scope: test; projects: p1; added 2026-09-01)
EOF

  # Set up state in local mate
  echo "working: test task" > "$local_mate/state/task-1.status"
  cat > "$local_mate/state/task-1.meta" <<'META'
kind=ship
mode=no-mistakes
project=firstmate
harness=claude
window=test:fm-task-1
META

  local out
  out=$(FM_HOME="$home" "$MATE_VIEW" local-worker)
  local rc=$?

  [ "$rc" -eq 0 ] || fail "local mate inspection failed with exit $rc"
  assert_contains "$out" "=== Secondmate: local-worker (local: $local_mate) ===" "missing local header"
  assert_contains "$out" "Home: $local_mate" "host report not run against local mate home"
  assert_contains "$out" "task-1.status (last 5 lines):" "missing task status log in host report"

  pass "local mate inspects local home state correctly"
}

# ----------------------------------------------------------------------------
# Test 5: Filtering and unknown argument error
# ----------------------------------------------------------------------------
test_argument_filtering() {
  local home="$TMP_ROOT/filter-home"
  local mate_a="$TMP_ROOT/filter-mate-a"
  local mate_b="$TMP_ROOT/filter-mate-b"
  mkdir -p "$home/data" "$home/state" "$mate_a/data" "$mate_a/state" "$mate_b/data" "$mate_b/state"

  cat > "$home/data/secondmates.md" <<EOF
- mate-a - Mate A (home: $mate_a; scope: test; projects: p1; added 2026-09-01)
- mate-b - Mate B (home: $mate_b; scope: test; projects: p2; added 2026-09-01)
EOF

  # Test filtering to mate-b only
  local out
  out=$(FM_HOME="$home" "$MATE_VIEW" mate-b)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "filtering failed with exit $rc"
  assert_contains "$out" "=== Secondmate: mate-b" "mate-b should be present"
  if printf '%s\n' "$out" | grep -q "=== Secondmate: mate-a"; then
    fail "mate-a should not be present when filtered"
  fi

  # Test unknown secondmate
  local err
  err=$(FM_HOME="$home" "$MATE_VIEW" nonexistent 2>&1) || true
  assert_contains "$err" "error: no registered secondmate matches 'nonexistent'" "missing unknown error"

  pass "argument filtering and unknown secondmate handling work"
}

# ----------------------------------------------------------------------------
# Test 6: Bearings snapshot secondmate_hosts integration
# ----------------------------------------------------------------------------
test_bearings_secondmate_hosts() {
  local home="$TMP_ROOT/bearings-home"
  local local_mate="$TMP_ROOT/bearings-local-mate"
  mkdir -p "$home/data" "$home/state" "$local_mate/data" "$local_mate/state"

  cat > "$home/data/secondmates.md" <<EOF
- local-worker - Local mate (home: $local_mate; scope: test; projects: p1; added 2026-09-01)
EOF

  local snap
  snap=$(FM_HOME="$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "bearings snapshot failed with exit $rc"
  printf '%s' "$snap" | jq -e '.secondmate_hosts | length == 1 and .[0].id == "local-worker"' >/dev/null \
    || fail "bearings did not contain expected secondmate_hosts entry"

  pass "bearings snapshot projects secondmate_hosts correctly"
}

# ----------------------------------------------------------------------------
# Test 7: Bearings host probe stays inside FM_SNAPSHOT_BUDGET with slow fm-on
# ----------------------------------------------------------------------------
test_bearings_host_probe_stays_inside_snapshot_budget() {
  local home="$TMP_ROOT/budget-home"
  local rhome="$TMP_ROOT/budget-rhome"
  mkdir -p "$home/data" "$home/state" "$rhome/state"

  cat > "$home/data/secondmates.md" <<EOF
- remote-slow - Remote slow worker (host: slow-box; root: /remote/root; home: $rhome; scope: test; projects: p1; added 2026-09-01)
EOF

  local fake_on="$TMP_ROOT/fake-on-slow.sh"
  cat > "$fake_on" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
cmd=$2
shift 2
if [ "$cmd" = "fm-remote-file.sh" ]; then
  cat <<'JSON'
{"schema":"fm-secondmate-home-summary.v1","hold_classifier_schema":"fm-captain-hold-buckets.v1","generated":"2026-09-01T22:00:00Z","generated_epoch":2000,"home":"/remote/home","valid":true,"state":"no_active_work","active_children":[],decisions_open":[],holds":[],queued":[],landed":[],endpoints":[],counts":{"active_children":0,"decisions_open":0,"holds":0,"queued":0,"landed":0,"endpoints":0},"omitted":[]}
JSON
  exit 0
elif [ "$cmd" = "fm-host-report.sh" ]; then
  sleep 30
  exit 0
fi
exit 1
SH
  chmod +x "$fake_on"

  local start_t elapsed snap rc
  start_t=$(date +%s)
  snap=$(FM_HOME="$home" FM_ON_OVERRIDE="$fake_on" FM_SNAPSHOT_BUDGET=1 "$ROOT/bin/fm-bearings-snapshot.sh" --json)
  rc=$?
  elapsed=$(( $(date +%s) - start_t ))

  [ "$rc" -eq 0 ] || fail "bearings snapshot with slow stubbed host probe failed with exit $rc"
  [ "$elapsed" -lt 4 ] || fail "bearings snapshot waited past FM_SNAPSHOT_BUDGET (${elapsed}s >= 4s)"
  printf '%s' "$snap" | jq -e '.secondmate_hosts | length == 1 and .[0].id == "remote-slow"' >/dev/null \
    || fail "bearings did not contain expected secondmate_hosts entry"

  pass "host probe stays inside FM_SNAPSHOT_BUDGET when fm-on is slow"
}

test_happy_path
test_unreachable_host
test_missing_report_script
test_local_mate
test_argument_filtering
test_bearings_secondmate_hosts
test_bearings_host_probe_stays_inside_snapshot_budget


