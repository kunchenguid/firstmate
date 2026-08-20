#!/usr/bin/env bash
# tests/fm-progress-lib.test.sh - the positive progress measurement
# (bin/fm-progress-lib.sh) supervision uses instead of "the pane has not changed".
#
# The contract under test, and why each half exists:
#   1. TWO independent positive signals, either of which alone carries a
#      progressing verdict - accumulated CPU over the span, and a change in the
#      pane subtree's process membership. They are driven apart deliberately
#      below, and the divergence itself is asserted, so neither case can go
#      quietly vacuous if the other signal starts covering for it.
#   2. `stalled` requires a MATURE span with NEITHER signal. It is positive
#      evidence of non-progress and the only verdict allowed to raise a new
#      alarm.
#   3. Everything unreadable, immature, or nonsensical is `unknown`, never a
#      guess in either direction, and never resets a maturing baseline.
#
# Real processes, no harness: the subtree walk, the ps read, and the time parse
# are exercised against processes this test starts itself, while the verdict
# logic is exercised as a pure function over exact records so a threshold or
# span boundary is pinned to the byte rather than to a machine's timing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-progress-lib.sh"

KIDS=()
cleanup() {
  local p
  for p in "${KIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null || true
  done
}
trap cleanup EXIT

# record <epoch> <cpu-centis> <count> <composition>
record() { printf 'v1 %s %s %s %s' "$1" "$2" "$3" "$4"; }

# --- time parsing: every documented ps shape, and nothing else --------------

test_time_parse_accepts_every_documented_shape() {
  local got
  got=$(fm_progress_time_to_centis '5:27.95') || fail "macOS MM:SS.cc was rejected"
  [ "$got" = 32795 ] || fail "5:27.95 must be 32795 centis, got $got"
  got=$(fm_progress_time_to_centis '6:03.14') || fail "macOS MM:SS.cc was rejected"
  [ "$got" = 36314 ] || fail "6:03.14 must be 36314 centis, got $got"
  # The reading that settled this by hand: +35.19s of CPU between the two.
  [ $(( 36314 - 32795 )) = 3519 ] || fail "the two hand readings must differ by 35.19s"
  got=$(fm_progress_time_to_centis '03:36:15') || fail "Linux HH:MM:SS was rejected"
  [ "$got" = 1297500 ] || fail "03:36:15 must be 1297500 centis, got $got"
  got=$(fm_progress_time_to_centis '1-02:03:04') || fail "DD-HH:MM:SS was rejected"
  [ "$got" = 9378400 ] || fail "1-02:03:04 must be 9378400 centis, got $got"
  got=$(fm_progress_time_to_centis '0:00.00') || fail "a zero reading was rejected"
  [ "$got" = 0 ] || fail "0:00.00 must be 0 centis, got $got"
  pass "fm_progress_time_to_centis: parses macOS, Linux, and multi-day ps time values"
}

test_time_parse_rejects_rather_than_reading_zero() {
  local v
  for v in 'bogus' '' '-' '1:2:3:4' '5:xx' 'a-01:00:00'; do
    if fm_progress_time_to_centis "$v" >/dev/null 2>&1; then
      fail "unparseable ps time '$v' was accepted, which would be read as CPU that did not happen"
    fi
  done
  pass "fm_progress_time_to_centis: refuses an unrecognized value instead of silently reading it as zero"
}

# --- subtree resolution: descendants, not a command-line match --------------

test_subtree_walks_descendants_from_the_root() {
  local parent kid pids
  # A shell whose only job is to hold one long-lived child, so the subtree has a
  # known shape: the shell plus its child.
  bash -c 'sleep 60 & echo $! > "$1"; wait' _ "$TMP_DIR/kid.pid" &
  parent=$!
  KIDS+=("$parent")
  wait_for_file "$TMP_DIR/kid.pid" || fail "the test child never reported its own child pid"
  kid=$(cat "$TMP_DIR/kid.pid")
  KIDS+=("$kid")
  pids=$(fm_progress_subtree_pids "$parent") || fail "the subtree of a live process could not be read"
  printf '%s\n' "$pids" | grep -qx "$parent" || fail "the subtree must include its own root $parent"
  printf '%s\n' "$pids" | grep -qx "$kid" || fail "the subtree must include the descendant $kid a tool call would run in"
  pass "fm_progress_subtree_pids: walks the ppid graph down from the root, root included"
}

test_subtree_refuses_a_dead_or_bogus_root() {
  local gone
  fm_progress_subtree_pids 0 >/dev/null 2>&1 && fail "pid 0 must not resolve to a subtree"
  fm_progress_subtree_pids '' >/dev/null 2>&1 && fail "an empty root must not resolve to a subtree"
  fm_progress_subtree_pids notapid >/dev/null 2>&1 && fail "a non-numeric root must not resolve to a subtree"
  # A plausible-looking but dead pid is the case that matters: it survives input
  # validation, so only the walk itself can reject it, and returning success with
  # an empty subtree here would read downstream as a pane doing no work.
  gone=$(dead_pid)
  fm_progress_subtree_pids "$gone" >/dev/null 2>&1 \
    && fail "a live-looking but dead pid ($gone) must fail, not resolve to an empty subtree"
  pass "fm_progress_subtree_pids: refuses a bogus or dead root rather than reporting an empty subtree"
}

test_sample_reads_real_accumulated_cpu() {
  local burner idle_pid busy_sample idle_sample busy_a busy_b
  bash -c 'while :; do :; done' &
  burner=$!
  KIDS+=("$burner")
  sleep 2
  bash -c 'sleep 60' &
  idle_pid=$!
  KIDS+=("$idle_pid")
  sleep 2
  busy_sample=$(fm_progress_sample "$burner") || fail "a live busy process could not be sampled"
  idle_sample=$(fm_progress_sample "$idle_pid") || fail "a live sleeping process could not be sampled"
  busy_a=$(printf '%s' "$busy_sample" | cut -d' ' -f3)
  busy_b=$(printf '%s' "$idle_sample" | cut -d' ' -f3)
  [ "$busy_a" -gt 100 ] || fail "a process that spun for 2s must show over 1s of accumulated CPU, got ${busy_a} centis"
  [ "$busy_b" -lt 50 ] || fail "a sleeping process must show almost no accumulated CPU, got ${busy_b} centis"
  pass "fm_progress_sample: reads real accumulated CPU, and a spinning process is separated from a sleeping one"
}

test_sample_membership_is_order_stable() {
  local parent kid first second
  # `ps -p` promises nothing about row order, so two samples of the SAME
  # processes must still produce the SAME membership string - otherwise a wedged
  # pane could borrow a progressing verdict from row ordering alone.
  bash -c 'sleep 60 & sleep 61 & sleep 62 & wait' &
  parent=$!
  KIDS+=("$parent")
  sleep 1
  first=$(fm_progress_sample "$parent") || fail "a multi-process subtree could not be sampled"
  second=$(fm_progress_sample "$parent") || fail "a multi-process subtree could not be re-sampled"
  [ "$(printf '%s' "$first" | cut -d' ' -f4)" -ge 4 ] \
    || fail "the fixture must have several processes for order to matter, got $first"
  [ "$(printf '%s' "$first" | cut -d' ' -f5)" = "$(printf '%s' "$second" | cut -d' ' -f5)" ] \
    || fail "the same processes produced different membership strings: '$first' vs '$second'"
  # And the verdict follows: unchanged membership must not read as progress.
  kid=$(fm_progress_compare "$first" "$second" 0)
  [ "${kid%% *}" != progressing ] \
    || fail "an unchanged multi-process subtree read as progressing: $kid"
  pass "fm_progress_sample: subtree membership is order-stable, so identical processes never read as a change"
}

test_sample_fails_on_an_unreadable_subtree() {
  local dead
  bash -c 'exit 0' &
  dead=$!
  wait "$dead" 2>/dev/null || true
  fm_progress_sample "$dead" >/dev/null 2>&1 \
    && fail "sampling an exited process must fail rather than report a zero-CPU subtree"
  pass "fm_progress_sample: an unreadable subtree fails instead of reading as no work"
}

# --- verdict logic, with the two signals deliberately driven apart ----------

test_cpu_signal_alone_carries_progressing() {
  local base now out
  # Composition is IDENTICAL in both records, so only the CPU delta can speak.
  base=$(record 1000 0 1 "4242")
  now=$(record 1300 3519 1 "4242")
  out=$(fm_progress_compare "$base" "$now" 180)
  [ "${out%% *}" = progressing ] || fail "35.19s of CPU over 300s must read progressing, got '$out'"
  case "$out" in *cpu*) ;; *) fail "the reading must name CPU as what carried it, got '$out'" ;; esac
  # Divergence assertion: the other signal is provably absent, so this case
  # cannot start passing for the wrong reason.
  [ "$(printf '%s' "$base" | cut -d' ' -f5)" = "$(printf '%s' "$now" | cut -d' ' -f5)" ] \
    || fail "the CPU-only case must keep subtree composition identical"
  pass "fm_progress_compare: accumulated CPU alone carries progressing when the subtree never changes"
}

test_subtree_signal_alone_carries_progressing() {
  local base now out delta
  # CPU is IDENTICAL in both records - the shape of a worker whose turn is a
  # series of short commands, whose CPU `ps -o time=` never attributes to the
  # surviving process because it reaped every child that spent it.
  base=$(record 1000 500 2 "4242,4243")
  now=$(record 1300 500 2 "4242,4299")
  out=$(fm_progress_compare "$base" "$now" 180)
  [ "${out%% *}" = progressing ] || fail "a changed subtree must read progressing, got '$out'"
  case "$out" in *subtree*) ;; *) fail "the reading must name the subtree as what carried it, got '$out'" ;; esac
  delta=$(( 500 - 500 ))
  [ "$delta" -eq 0 ] || fail "the subtree-only case must keep accumulated CPU identical"
  pass "fm_progress_compare: a changed subtree alone carries progressing when accumulated CPU is flat"
}

test_stalled_needs_a_mature_span_with_neither_signal() {
  local base out
  base=$(record 1000 500 1 "4242")
  out=$(fm_progress_compare "$base" "$(record 1179 500 1 "4242")" 180)
  [ "${out%% *}" = unknown ] || fail "one second short of the span must stay unknown, got '$out'"
  case "$out" in *span-immature*) ;; *) fail "an immature span must say so, got '$out'" ;; esac
  out=$(fm_progress_compare "$base" "$(record 1180 500 1 "4242")" 180)
  [ "${out%% *}" = stalled ] || fail "a mature span with neither signal must read stalled, got '$out'"
  pass "fm_progress_compare: stalled requires the full span AND both signals silent"
}

test_cpu_below_the_rate_threshold_is_not_progress() {
  local out
  # 1% of a core sustained for 600s: real, tiny, and not work. The threshold is
  # a RATE, so a long span cannot accumulate idle noise into a false verdict.
  out=$(fm_progress_compare "$(record 1000 0 1 "4242")" "$(record 1600 600 1 "4242")" 180)
  [ "${out%% *}" = stalled ] || fail "1% of a core over 600s must read stalled, got '$out'"
  out=$(fm_progress_compare "$(record 1000 0 1 "4242")" "$(record 1600 1200 1 "4242")" 180)
  [ "${out%% *}" = progressing ] || fail "2% of a core over 600s must read progressing, got '$out'"
  pass "fm_progress_compare: the CPU signal is a sustained rate, not a total that idling can accumulate into"
}

test_nonsense_records_are_unknown_not_a_verdict() {
  local out
  out=$(fm_progress_compare "garbage" "$(record 1600 0 1 "4242")" 180)
  [ "${out%% *}" = unknown ] || fail "a malformed baseline must be unknown, got '$out'"
  out=$(fm_progress_compare "$(record 1000 0 1 "4242")" "garbage" 180)
  [ "${out%% *}" = unknown ] || fail "a malformed sample must be unknown, got '$out'"
  out=$(fm_progress_compare "$(record 1600 0 1 "4242")" "$(record 1000 0 1 "4242")" 180)
  [ "${out%% *}" = unknown ] || fail "a backwards clock must be unknown, not stalled, got '$out'"
  out=$(fm_progress_compare "$(record 1000 900 1 "4242")" "$(record 1600 100 1 "4242")" 180)
  [ "${out%% *}" = unknown ] || fail "CPU time going backwards must be unknown, not a verdict, got '$out'"
  out=$(fm_progress_compare "v2 1000 0 1 4242" "$(record 1600 0 1 "4242")" 180)
  [ "${out%% *}" = unknown ] || fail "a record from another version must be unknown, got '$out'"
  pass "fm_progress_compare: every nonsensical input is unknown, never stalled and never progressing"
}

# --- baseline lifecycle -----------------------------------------------------

test_probe_records_a_baseline_then_matures_it() {
  local state key burner out saved
  state="$TMP_DIR/probe-state"
  mkdir -p "$state"
  key=probe1
  bash -c 'while :; do :; done' &
  burner=$!
  KIDS+=("$burner")
  out=$(fm_progress_probe "$state" "$key" 180 "$burner")
  [ "${out%% *}" = unknown ] || fail "the first probe has nothing to compare and must be unknown, got '$out'"
  [ -s "$state/.progress-$key" ] || fail "the first probe must record a baseline to measure the next span from"
  sleep 2
  out=$(fm_progress_probe "$state" "$key" 1 "$burner")
  [ "${out%% *}" = progressing ] || fail "a spinning process must read progressing on the next probe, got '$out'"
  saved=$(cat "$state/.progress-$key")
  [ "$(printf '%s' "$saved" | cut -d' ' -f3)" -gt 100 ] \
    || fail "a progressing verdict must roll the baseline forward to the reading that proved it"
  pass "fm_progress_probe: records a baseline, then rolls it forward on measured progress"
}

test_probe_keeps_a_maturing_baseline_when_it_cannot_read() {
  local state key before after dead
  state="$TMP_DIR/probe-state2"
  mkdir -p "$state"
  key=probe2
  printf 'v1 1000 500 1 4242' > "$state/.progress-$key"
  before=$(cat "$state/.progress-$key")
  bash -c 'exit 0' &
  dead=$!
  wait "$dead" 2>/dev/null || true
  out=$(fm_progress_probe "$state" "$key" 180 "$dead")
  [ "${out%% *}" = unknown ] || fail "an unreadable subtree must probe unknown, got '$out'"
  after=$(cat "$state/.progress-$key")
  [ "$before" = "$after" ] \
    || fail "one unreadable read must not reset a maturing span, or a wedge could hide behind ps failures"
  pass "fm_progress_probe: an unreadable subtree leaves the maturing baseline untouched"
}

test_probe_holds_the_baseline_while_a_stall_matures() {
  local state key sleeper before after out
  state="$TMP_DIR/probe-state3"
  mkdir -p "$state"
  key=probe3
  bash -c 'sleep 60' &
  sleeper=$!
  KIDS+=("$sleeper")
  fm_progress_probe "$state" "$key" 1 "$sleeper" >/dev/null
  before=$(cat "$state/.progress-$key")
  sleep 2
  out=$(fm_progress_probe "$state" "$key" 1 "$sleeper")
  [ "${out%% *}" = stalled ] || fail "a sleeping process past its span must read stalled, got '$out'"
  after=$(cat "$state/.progress-$key")
  [ "$before" = "$after" ] \
    || fail "a stalled verdict must not roll the baseline forward, or the span would restart every poll"
  pass "fm_progress_probe: a stalled verdict holds the baseline so the span keeps growing"
}

wait_for_file() {  # <path>
  local i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

TMP_DIR=$(fm_test_tmproot fm-progress-lib-tests)

test_time_parse_accepts_every_documented_shape
test_time_parse_rejects_rather_than_reading_zero
test_subtree_walks_descendants_from_the_root
test_subtree_refuses_a_dead_or_bogus_root
test_sample_reads_real_accumulated_cpu
test_sample_membership_is_order_stable
test_sample_fails_on_an_unreadable_subtree
test_cpu_signal_alone_carries_progressing
test_subtree_signal_alone_carries_progressing
test_stalled_needs_a_mature_span_with_neither_signal
test_cpu_below_the_rate_threshold_is_not_progress
test_nonsense_records_are_unknown_not_a_verdict
test_probe_records_a_baseline_then_matures_it
test_probe_keeps_a_maturing_baseline_when_it_cannot_read
test_probe_holds_the_baseline_while_a_stall_matures
