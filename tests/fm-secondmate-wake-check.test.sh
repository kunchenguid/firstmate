#!/usr/bin/env bash
# Behavior tests for the secondmate wake-loop liveness check.
#
# The defect these pin: a secondmate's agent process can be alive while its wake
# loop is dead, and from outside those two look identical. Every case here drives
# the real scripts against real home directories; none of them inspects source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-secondmate-wake-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-wake-check)

# Every world pins one clock. The check reads a row's own recorded epoch, so a
# fixture that stamps rows with one "now" and probes against a later one would
# drift by whatever second the test happened to cross.
make_world() {  # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  NOW=$(date +%s)
  mkdir -p "$MAIN"/{state,data,config,projects}
}

make_mate_home() {  # <name>
  local home="$WORLD/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# Queue one row into a home's own durable wake queue, stamped <age> seconds ago.
# Written directly rather than through fm_wake_append because the point of the
# fixture is an OLD row, and the production appender always stamps "now".
queue_row_aged() {  # <home> <sequence> <age-seconds>
  local home=$1 seq=$2 age=$3 epoch
  epoch=$(( NOW - age ))
  printf '%s\t%s\tcheck\tprocevent:artemis:%s\tcheck: procevent artemis artemis-src %s\n' \
    "$epoch" "$seq" "$seq" "$seq" >> "$home/state/.wake-queue"
  printf '%s\n' "$seq" > "$home/state/.wake-queue.seq"
}

record_secondmate() {  # <id> <home> [extra-meta-line]
  local id=$1 home=$2 extra=${3:-}
  fm_write_secondmate_meta "$MAIN/state/$id.meta" "$home" "firstmate:fm-$id" artemis claude
  [ -z "$extra" ] || printf '%s\n' "$extra" >> "$MAIN/state/$id.meta"
  printf 'working: watching for review requests\n' > "$MAIN/state/$id.status"
}

run_check() {  # <args>...
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" FM_SECONDMATE_WAKE_NOW="$NOW" "$CHECK" "$@"
}

queued_keys() {
  awk -F '\t' '{print $4}' "$MAIN/state/.wake-queue" 2>/dev/null
}

# The whole point: a live agent and a dead wake loop must stop being the same
# observation. Neither home here has a watcher; only one has work it never took.
test_deaf_home_is_distinguished_from_an_idle_one() {
  local deaf idle out
  make_world distinguish
  deaf=$(make_mate_home deaf)
  idle=$(make_mate_home idle)
  queue_row_aged "$deaf" 1 46800
  record_secondmate deaf "$deaf"
  record_secondmate idle "$idle"

  assert_contains "$(run_check probe "$deaf")" 'stalled 46800 1' \
    "a wake queue unconsumed for thirteen hours was not reported as stalled"
  assert_contains "$(run_check probe "$idle")" 'ok' \
    "an idle secondmate with an empty queue was reported as stalled"

  out=$(run_check scan --startup)
  assert_contains "$out" 'secondmate-wake-stall deaf' \
    "the scan did not report the secondmate whose wake loop stopped"
  assert_not_contains "$out" 'secondmate-wake-stall idle' \
    "the scan reported a healthy idle secondmate as stalled"
  assert_contains "$(queued_keys)" 'secondmate-wake-stall:deaf:1' \
    "the stall was reported without a durable record of its own"
  pass "a deaf secondmate is detected while an idle one stays quiet"
}

# A row younger than the bound is an ordinary in-flight notification, not an
# outage: a secondmate may legitimately hold one for the length of a long turn.
test_a_recent_row_is_not_a_stall() {
  local home
  make_world recent
  home=$(make_mate_home recent)
  queue_row_aged "$home" 1 60
  record_secondmate recent "$home"
  assert_contains "$(run_check probe "$home")" 'ok' \
    "a wake queued a minute ago was treated as an outage"
  [ -z "$(run_check scan --startup)" ] || fail "the scan reported a recent queued wake as a stall"
  pass "a recently queued wake is not a stall"
}

# The oldest row decides, and it is chosen by the queue's own sequence, so a
# newer append can neither mask an old unconsumed row nor invent a stall.
test_oldest_row_decides() {
  local home verdict
  make_world oldest
  home=$(make_mate_home oldest)
  queue_row_aged "$home" 7 46800
  queue_row_aged "$home" 8 5
  verdict=$(run_check probe "$home")
  assert_contains "$verdict" 'stalled' "a fresh newer row masked an old unconsumed one"
  assert_contains "$verdict" ' 7' "the stall did not name the oldest queued sequence"
  pass "the oldest queued row decides the verdict"
}

# Reading another home's queue takes no lock there, so a torn newest row must be
# ignored rather than crash the scan or change which row is oldest.
test_malformed_rows_are_ignored() {
  local home
  make_world malformed
  home=$(make_mate_home malformed)
  queue_row_aged "$home" 3 46800
  printf 'partial-append-with-no-fields' >> "$home/state/.wake-queue"
  assert_contains "$(run_check probe "$home")" 'stalled 46800 3' \
    "a partially appended newest row changed the oldest-row verdict"

  make_world onlymalformed
  home=$(make_mate_home onlymalformed)
  printf 'garbage\n' > "$home/state/.wake-queue"
  assert_contains "$(run_check probe "$home")" 'ok' \
    "a queue with no well-formed row was reported as a stall"
  pass "malformed queue rows are ignored rather than guessed at"
}

# The durable record is its own dedup: the stall reports once and stays quiet
# until the supervisor has actually handled and acknowledged it.
test_stall_reports_once_until_acknowledged() {
  local home first second rows
  make_world dedup
  home=$(make_mate_home dedup)
  queue_row_aged "$home" 1 46800
  record_secondmate dedup "$home"

  first=$(run_check scan --startup)
  assert_contains "$first" 'secondmate-wake-stall dedup' "the first scan did not report the stall"
  second=$(run_check scan --startup)
  [ -z "$second" ] || fail "an unacknowledged stall was reported a second time: $second"
  rows=$(grep -c 'secondmate-wake-stall:dedup' "$MAIN/state/.wake-queue")
  [ "$rows" = 1 ] || fail "the stall queued $rows records instead of one"
  pass "a stall reports once while its record stays unacknowledged"
}

# Most watcher cycles must skip this entirely; only --startup ignores the cadence.
test_scan_honours_its_cadence() {
  local home
  make_world cadence
  home=$(make_mate_home cadence)
  queue_row_aged "$home" 1 46800
  record_secondmate cadence "$home"
  assert_contains "$(FM_SECONDMATE_WAKE_SCAN_SECS=3600 run_check scan)" 'secondmate-wake-stall cadence' \
    "the first cadenced scan did not evaluate"
  # Clear the durable record so a second report is only suppressed by cadence.
  : > "$MAIN/state/.wake-queue"
  [ -z "$(FM_SECONDMATE_WAKE_SCAN_SECS=3600 run_check scan)" ] \
    || fail "a scan inside its own cadence window evaluated anyway"
  assert_contains "$(FM_SECONDMATE_WAKE_SCAN_SECS=3600 run_check scan --startup)" 'secondmate-wake-stall cadence' \
    "--startup did not override the cadence window"
  pass "the scan evaluates on its own bounded cadence and always at startup"
}

# A remote route's home is on another machine. Reporting it as healthy would be
# the exact false confidence this check exists to remove.
test_remote_routes_are_not_claimed_as_healthy() {
  local home
  make_world remote
  home=$(make_mate_home remote)
  queue_row_aged "$home" 1 46800
  record_secondmate remote "$home" "remote_host=elsewhere.test"
  [ -z "$(run_check scan --startup)" ] \
    || fail "a remote route was judged from a local path that only coincidentally exists"
  assert_contains "$(run_check probe /nonexistent-home-path)" 'skipped' \
    "an unreadable home was not reported as uncovered"
  pass "a remote route is left uncovered rather than judged locally"
}

# An ordinary crewmate is not a secondmate: this check owns only the homes whose
# wake loop nothing else can restart.
test_only_secondmates_are_scanned() {
  local home
  make_world crew
  home=$(make_mate_home crew)
  queue_row_aged "$home" 1 46800
  fm_write_meta "$MAIN/state/crew.meta" \
    "window=firstmate:fm-crew" "worktree=$home" "project=alpha" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' "home=$home"
  [ -z "$(run_check scan --startup)" ] || fail "an ordinary crewmate was scanned as a secondmate"
  # And a home with no secondmate at all leaves nothing behind to clean up.
  assert_absent "$MAIN/state/.secondmate-wake-scan" \
    "a home with no recorded secondmate still generated scan state"
  pass "only recorded secondmates are scanned, and a home with none is a true no-op"
}

test_settings_are_bounded() {
  local rc
  make_world bounds
  rc=0; FM_SECONDMATE_WAKE_STALL_SECS=10 run_check scan --startup >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "an out-of-range stall bound was accepted (exit $rc)"
  rc=0; FM_SECONDMATE_WAKE_SCAN_SECS=abc run_check scan --startup >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "a non-numeric scan cadence was accepted (exit $rc)"
  pass "out-of-range and non-numeric settings are refused"
}

test_deaf_home_is_distinguished_from_an_idle_one
test_a_recent_row_is_not_a_stall
test_oldest_row_decides
test_malformed_rows_are_ignored
test_stall_reports_once_until_acknowledged
test_scan_honours_its_cadence
test_remote_routes_are_not_claimed_as_healthy
test_only_secondmates_are_scanned
test_settings_are_bounded
