#!/usr/bin/env bash
# Behavior tests for the periodic-check adapter of the process-to-event runner
# (bin/fm-procevent-periodic.sh).
#
# Every scenario is exercised through the adapter's public commands plus the
# generic runner, against real check processes; nothing here asserts
# implementation-source bytes. The suite proves the load-bearing guarantees: a
# clean run is captured but never announced however much it printed, a nonzero
# exit always announces with its evidence, the source stays armed so the
# watcher's ordinary reconcile runs the next cycle, the recorded schedule
# survives a restart instead of re-running immediately, and every refusal path
# reaches the durable wake queue rather than failing silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-periodic-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# Keep a sleeping runner responsive to a rewritten schedule inside test time.
export FM_PERIODIC_SLEEP_SLICE=1

pe()  { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
per() { FM_HOME="$1" "$ROOT/bin/fm-procevent-periodic.sh" "${@:2}"; }

# Every home this suite arms is tracked so teardown can stop any runner still
# sleeping on a cadence that never comes due.
PERIODIC_HOMES=()
periodic_teardown() {
  local home seen=$'\n'
  for home in ${PERIODIC_HOMES[@]+"${PERIODIC_HOMES[@]}"}; do
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen+="$home"$'\n'
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap periodic_teardown EXIT

new_home() { mkdir -p "$1/state"; PERIODIC_HOMES+=("$1"); }

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

result_path() {  # <home> <source-id> <sequence>
  printf '%s/state/procevent-inbox/%s.%s.result\n' "$1" "$2" "$3"
}

wait_for_result() {  # <home> <source-id> <sequence> [tries]
  local n=${4:-150} f
  f=$(result_path "$1" "$2" "$3")
  for _ in $(seq 1 "$n"); do
    [ -e "$f" ] && return 0
    sleep 0.1
  done
  return 1
}

count_lines() { [ -e "$1" ] && grep -c . "$1" || echo 0; }

# Force a source's next run to be due immediately, the way a real cadence
# elapsing does, without waiting out a real interval.
make_due() {  # <home> <source-id>
  printf 'fm-periodic-due-v1\n%s\n' "$(date +%s)" > "$1/state/periodic/$2.due"
}

# A clean check that still PRINTS on its clean path, which is the whole reason
# the report-worthy signal is the exit status and not the output.
CLEAN="$TMP_ROOT/clean.sh"
cat > "$CLEAN" <<'SH'
#!/usr/bin/env bash
log=${1:-}
[ -z "$log" ] || echo run >> "$log"
echo "== daily sweep header"
echo "-- every item checked out fine"
exit 0
SH
chmod +x "$CLEAN"

# A check that reports something worth reading.
DIRTY="$TMP_ROOT/dirty.sh"
cat > "$DIRTY" <<'SH'
#!/usr/bin/env bash
log=${1:-}
[ -z "$log" ] || echo run >> "$log"
echo "== daily sweep header"
echo "-- DRIFT: production is behind main"
exit 1
SH
chmod +x "$DIRTY"

# --- arm binds the check and refuses a duplicate -----------------------------
H="$TMP_ROOT/h-arm"; new_home "$H"
out=$(per "$H" arm arm-test --interval 3600 --timeout 60 -- "$CLEAN")
assert_contains "$out" "armed: periodic-arm-test" "arm reports the canonical source id"
assert_contains "$out" "every 3600s" "arm reports the registered cadence"
assert_present "$H/state/periodic/periodic-arm-test.spec" "arm writes the private spec"
assert_present "$H/state/periodic/periodic-arm-test.trust" "arm writes the trust binding"
assert_present "$H/state/periodic/periodic-arm-test.due" "arm records the first due time"
assert_present "$H/state/procevent/periodic-arm-test.source" "arm registers the process-event source"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$H/state/periodic/periodic-arm-test.spec")
assert_contains "$mode" 600 "the spec is private"
if per "$H" arm arm-test --interval 3600 --timeout 60 -- "$CLEAN" 2>"$TMP_ROOT/dup.err"; then
  fail "re-arming an existing periodic check must be refused"
fi
assert_grep "already exists" "$TMP_ROOT/dup.err" "the duplicate refusal names the leftover state"
assert_contains "$(per "$H" source-id arm-test)" "periodic-arm-test" "source-id prints the canonical id"
assert_contains "$(per "$H" due arm-test)" now "a --first now check is due immediately"
out=$(per "$H" retire arm-test)
assert_contains "$out" "retired: periodic-arm-test" "retire reports the source"
assert_absent "$H/state/periodic/periodic-arm-test.spec" "retire removes the spec"
assert_absent "$H/state/periodic/periodic-arm-test.trust" "retire removes the trust binding"
assert_absent "$H/state/periodic/periodic-arm-test.due" "retire removes the schedule"
assert_absent "$H/state/procevent/periodic-arm-test.source" "retire drops the registration"
out=$(per "$H" retire arm-test)
assert_contains "$out" "retired: periodic-arm-test" "retire is idempotent"
pass "arm binds the check, refuses duplicates, and retire cleans up"

# --- arm refuses configuration that cannot hold a cadence --------------------
H="$TMP_ROOT/h-reject"; new_home "$H"
if per "$H" arm bad-timeout --interval 60 --timeout 60 -- "$CLEAN" 2>"$TMP_ROOT/to.err"; then
  fail "a timeout that can outlast its own interval must be refused"
fi
assert_grep "must be shorter than" "$TMP_ROOT/to.err" "the refusal explains the cadence conflict"
if per "$H" arm bad-exe --interval 3600 --timeout 60 -- "$TMP_ROOT/definitely-not-here" 2>"$TMP_ROOT/exe.err"; then
  fail "an unavailable check executable must be refused"
fi
assert_grep "check executable is unavailable" "$TMP_ROOT/exe.err" "the refusal names the missing executable"
assert_absent "$H/state/procevent/periodic-bad-exe.source" "a refused arm registers nothing"
pass "arm refuses a cadence-breaking timeout and a missing executable"

# --- a clean run is captured, never announced, and advances the schedule -----
H="$TMP_ROOT/h-clean"; new_home "$H"
CLEANLOG="$TMP_ROOT/clean-runs"
per "$H" arm clean --interval 3600 --timeout 60 -- "$CLEAN" "$CLEANLOG" >/dev/null
pe "$H" start periodic-clean >/dev/null
wait_for_result "$H" periodic-clean 1 || fail "the clean run captured no result"
RESULT=$(result_path "$H" periodic-clean 1)
assert_grep 'status: clean' "$RESULT" "the outcome records a clean run"
assert_grep 'check_exit: 0' "$RESULT" "the outcome records the check exit"
assert_grep 'daily sweep header' "$RESULT" "a clean run still captures its evidence"
assert_contains "$(per "$H" classify "$RESULT")" clean "classify reads the outcome"
per "$H" silent "$RESULT" || fail "a clean outcome must declare silence"
# The whole point: output on the clean path must not become a wake.
assert_not_contains "$(wake_payloads "$H")" periodic-clean "a clean run never wakes firstmate"
assert_present "$H/state/procevent-inbox/periodic-clean.1.handled" \
  "a silenced clean run is recorded handled so it never returns"
# Silence is durable across the watcher's own republication pass.
pe "$H" reconcile >/dev/null
assert_not_contains "$(wake_payloads "$H")" periodic-clean "reconcile never re-announces a silenced run"
assert_present "$H/state/procevent/periodic-clean.source" "a periodic source stays armed after a run"
pass "a clean run is captured with its evidence and never announced"

# --- a nonzero exit always announces, with its evidence off the event line ---
H="$TMP_ROOT/h-report"; new_home "$H"
per "$H" arm report --interval 3600 --timeout 60 -- "$DIRTY" >/dev/null
pe "$H" start periodic-report >/dev/null
wait_for_result "$H" periodic-report 1 || fail "the reporting run captured no result"
RESULT=$(result_path "$H" periodic-report 1)
assert_grep 'status: report' "$RESULT" "a nonzero exit is a report"
assert_grep 'check_exit: 1' "$RESULT" "the outcome records the reporting exit"
assert_grep 'DRIFT: production is behind main' "$RESULT" "the outcome carries the check output"
assert_contains "$(per "$H" classify "$RESULT")" report "classify reads the report"
if per "$H" silent "$RESULT"; then
  fail "a report must never declare silence"
fi
payload=$(wake_payloads "$H")
assert_contains "$payload" "procevent periodic periodic-report 1" "the report wake reached the durable queue"
assert_not_contains "$payload" "DRIFT" "check output never reaches the event line"
out=$(pe "$H" handled periodic-report 1)
assert_contains "$out" "handled: periodic-report 1" "the report acknowledges through the generic channel"
pass "a nonzero exit always announces and keeps its evidence out of the event line"

# --- the cadence continues across restarts through ordinary reconcile --------
H="$TMP_ROOT/h-cycle"; new_home "$H"
CYCLELOG="$TMP_ROOT/cycle-runs"
per "$H" arm cycle --interval 3600 --timeout 60 -- "$CLEAN" "$CYCLELOG" >/dev/null
pe "$H" start periodic-cycle >/dev/null
wait_for_result "$H" periodic-cycle 1 || fail "the first cycle captured no result"
assert_contains "$(count_lines "$CYCLELOG")" 1 "the first cycle ran the check once"
# A runner that exits leaves the source armed, so the watcher's ordinary
# reconcile is what starts the next cycle. Nothing else schedules it.
pe "$H" reconcile >/dev/null
sleep 1
assert_contains "$(count_lines "$CYCLELOG")" 1 \
  "reconcile never re-runs a check before its next due time"
assert_absent "$(result_path "$H" periodic-cycle 2)" "an early reconcile captures no second result"
# Once the cadence elapses, the same reconcile produces the next cycle.
make_due "$H" periodic-cycle
pe "$H" reconcile >/dev/null
wait_for_result "$H" periodic-cycle 2 || fail "reconcile did not run the next cycle once it was due"
assert_contains "$(count_lines "$CYCLELOG")" 2 "the due cycle ran the check a second time"
assert_grep 'status: clean' "$(result_path "$H" periodic-cycle 2)" "the second cycle captured its own outcome"
assert_not_contains "$(wake_payloads "$H")" periodic-cycle "repeated clean cycles stay silent"
assert_present "$H/state/procevent/periodic-cycle.source" "the source is still armed for the cycle after"
pass "the cadence continues across restarts through the watcher's ordinary reconcile"

# --- a mutated check executable is refused without running it ----------------
H="$TMP_ROOT/h-trust"; new_home "$H"
MUT="$TMP_ROOT/mutable.sh"
MUTLOG="$TMP_ROOT/mutable-runs"
cp "$CLEAN" "$MUT"; chmod +x "$MUT"
per "$H" arm trust --interval 3600 --timeout 60 -- "$MUT" "$MUTLOG" >/dev/null
echo 'echo tampered' >> "$MUT"
pe "$H" start periodic-trust >/dev/null
wait_for_result "$H" periodic-trust 1 || fail "the refusal captured no result"
RESULT=$(result_path "$H" periodic-trust 1)
assert_grep 'status: rejected' "$RESULT" "a changed executable is refused"
assert_grep 'trust binding' "$RESULT" "the refusal explains itself"
assert_contains "$(count_lines "$MUTLOG")" 0 "the mutated check never ran"
if per "$H" silent "$RESULT"; then
  fail "a refusal must never declare silence"
fi
assert_contains "$(wake_payloads "$H")" "procevent periodic periodic-trust 1" \
  "a refusal wakes firstmate instead of failing silently"
pass "a mutated check executable is refused without running and still wakes firstmate"

# --- a mutated spec is refused without running anything ----------------------
H="$TMP_ROOT/h-spec"; new_home "$H"
SPECLOG="$TMP_ROOT/spec-runs"
per "$H" arm spec --interval 3600 --timeout 60 -- "$CLEAN" "$SPECLOG" >/dev/null
# Rewrite the cadence without re-binding the trust record.
sed 's/^interval=3600$/interval=1/' "$H/state/periodic/periodic-spec.spec" > "$TMP_ROOT/spec.new"
cat "$TMP_ROOT/spec.new" > "$H/state/periodic/periodic-spec.spec"
pe "$H" start periodic-spec >/dev/null
wait_for_result "$H" periodic-spec 1 || fail "the spec refusal captured no result"
RESULT=$(result_path "$H" periodic-spec 1)
assert_grep 'status: rejected' "$RESULT" "an unbound spec is refused"
assert_contains "$(count_lines "$SPECLOG")" 0 "the check never ran from a mutated spec"
assert_contains "$(wake_payloads "$H")" "procevent periodic periodic-spec 1" \
  "the spec refusal reaches the durable queue"
pass "a mutated spec is refused without executing anything"

# --- a check that overruns its bound is stopped and reported ----------------
H="$TMP_ROOT/h-timeout"; new_home "$H"
HANG="$TMP_ROOT/hang.sh"
cat > "$HANG" <<'SH'
#!/usr/bin/env bash
echo "starting the sweep"
sleep 300
SH
chmod +x "$HANG"
per "$H" arm hang --interval 3600 --timeout 1 -- "$HANG" >/dev/null
pe "$H" start periodic-hang >/dev/null
wait_for_result "$H" periodic-hang 1 || fail "the timeout captured no result"
RESULT=$(result_path "$H" periodic-hang 1)
assert_grep 'status: timeout' "$RESULT" "an overrunning check times out"
assert_grep 'starting the sweep' "$RESULT" "the timeout keeps the partial output as evidence"
assert_contains "$(per "$H" classify "$RESULT")" timeout "classify reads the timeout"
if per "$H" silent "$RESULT"; then
  fail "a timeout must never declare silence"
fi
assert_contains "$(wake_payloads "$H")" "procevent periodic periodic-hang 1" \
  "a timeout wakes firstmate"
assert_present "$H/state/procevent/periodic-hang.source" "a timed-out check stays armed for its next cycle"
pass "a check that overruns its bound is stopped, reported, and left armed"

# --- --first wait defers the first run --------------------------------------
H="$TMP_ROOT/h-first"; new_home "$H"
WAITLOG="$TMP_ROOT/first-runs"
per "$H" arm first --interval 3600 --timeout 60 --first wait -- "$CLEAN" "$WAITLOG" >/dev/null
due=$(per "$H" due first)
[ "$due" != now ] || fail "--first wait must not be due immediately"
pe "$H" reconcile >/dev/null
sleep 1
assert_contains "$(count_lines "$WAITLOG")" 0 "--first wait defers the first run"
assert_absent "$(result_path "$H" periodic-first 1)" "a deferred check captures nothing yet"
pass "--first wait defers the first run by a full interval"

# --- an unreadable schedule is re-established, never treated as due now ------
H="$TMP_ROOT/h-corrupt"; new_home "$H"
CORRUPTLOG="$TMP_ROOT/corrupt-runs"
per "$H" arm corrupt --interval 3600 --timeout 60 --first wait -- "$CLEAN" "$CORRUPTLOG" >/dev/null
printf 'garbage\n' > "$H/state/periodic/periodic-corrupt.due"
pe "$H" reconcile >/dev/null
sleep 1
assert_contains "$(count_lines "$CORRUPTLOG")" 0 \
  "a corrupt schedule never becomes a continuous re-run of the check"
due=$(per "$H" due corrupt)
[ "$due" != now ] || fail "a re-established schedule must not be due immediately"
pass "an unreadable schedule is re-established instead of read as due now"

# --- stored argv is executed directly, never re-split ------------------------
H="$TMP_ROOT/h-argv"; new_home "$H"
ARGVOUT="$TMP_ROOT/argv-seen"
ARGVCHECK="$TMP_ROOT/argv.sh"
cat > "$ARGVCHECK" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$2"
exit 0
SH
chmod +x "$ARGVCHECK"
per "$H" arm argv --interval 3600 --timeout 60 -- "$ARGVCHECK" 'one arg; with *glob* and "quotes"' "$ARGVOUT" >/dev/null
pe "$H" start periodic-argv >/dev/null
wait_for_result "$H" periodic-argv 1 || fail "the argv check captured no result"
assert_contains "$(cat "$ARGVOUT")" 'one arg; with *glob* and "quotes"' \
  "an argument with spaces and shell metacharacters is never re-split or interpreted"
pass "stored argv is executed directly without re-splitting"

# --- retire leaves an unhandled result behind; re-arming the same name is refused ---
H="$TMP_ROOT/h-rearm"; new_home "$H"
per "$H" arm rearm --interval 3600 --timeout 60 -- "$DIRTY" >/dev/null
pe "$H" start periodic-rearm >/dev/null
wait_for_result "$H" periodic-rearm 1 || fail "the reporting run captured no result"
per "$H" retire rearm >/dev/null
assert_present "$(result_path "$H" periodic-rearm 1)" "retire leaves the captured result in place"
if per "$H" arm rearm --interval 3600 --timeout 60 -- "$CLEAN" 2>"$TMP_ROOT/rearm.err"; then
  fail "re-arming a name with an unhandled captured result must be refused"
fi
assert_grep "unhandled captured result" "$TMP_ROOT/rearm.err" "the refusal names the unhandled result"
assert_absent "$H/state/periodic/periodic-rearm.spec" "the refused re-arm leaves no new spec behind"
pe "$H" handled periodic-rearm 1 >/dev/null
out=$(per "$H" arm rearm --interval 3600 --timeout 60 -- "$CLEAN")
assert_contains "$out" "armed: periodic-rearm" "handling the stale result unblocks re-arming"
pass "retire leaves an unhandled result behind and blocks re-arming until it is handled"

echo "all periodic-check adapter tests passed"
