#!/usr/bin/env bash
# tests/fm-wake-drain-shadow-skip.test.sh - shadow-mode unchanged-wake record:
# a drained wake whose facts (kind, key, payload; not epoch or sequence) equal
# the last drained wake from the same source appends one would-skip record, and
# the wake is still presented exactly as before.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-shadow-skip-tests)
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

drain_ack() {  # <state> <out>
  local state=$1 out=$2 through gen
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$out.err" || fail "drain failed: $(cat "$out.err")"
  through=$(sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \(.*\)$/\1/p' "$out.err" | head -1)
  gen=$(sed -n 's/.*--recovery-generation \(.*\)$/\1/p' "$out.err" | head -1)
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$through" --recovery-generation "$gen" >/dev/null 2>&1 \
    || fail "ack failed"
}

test_equal_facts_log_one_would_skip_and_still_present() {
  local dir state log
  dir=$(make_case equal); state="$dir/state"; log="$state/.wake-would-skip.log"
  append_wake "$state" check job-a "build green"
  drain_ack "$state" "$dir/1.out"
  [ ! -s "$log" ] || fail "first wake from a source logged a would-skip"
  sleep 1
  append_wake "$state" check job-a "build green"
  drain_ack "$state" "$dir/2.out"
  grep -F 'build green' "$dir/2.out" >/dev/null || fail "repeat wake was not presented: $(cat "$dir/2.out")"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "expected one would-skip record: $(cat "$log")"
  awk -F '\t' '$1 ~ /^[0-9]+$/ && $2 == "check" && $3 == "job-a" && $4 != ""' "$log" | grep . >/dev/null \
    || fail "record lacks time/source/fingerprint: $(cat "$log")"
  pass "equal facts from the same source log one would-skip and the wake is still presented"
}

test_changed_facts_and_other_sources_do_not_log() {
  local dir state log
  dir=$(make_case changed); state="$dir/state"; log="$state/.wake-would-skip.log"
  append_wake "$state" check job-a "build green"
  drain_ack "$state" "$dir/1.out"
  append_wake "$state" check job-a "build red"
  drain_ack "$state" "$dir/2.out"
  append_wake "$state" check job-b "build red"
  drain_ack "$state" "$dir/3.out"
  [ ! -s "$log" ] || fail "changed payload or different source logged: $(cat "$log")"
  grep -F 'build red' "$dir/3.out" >/dev/null || fail "wake not presented"
  pass "changed payloads and distinct sources never log a would-skip"
}

test_redrain_without_ack_does_not_log() {
  local dir state log
  dir=$(make_case redrain); state="$dir/state"; log="$state/.wake-would-skip.log"
  append_wake "$state" check job-a "build green"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/1.out" 2>/dev/null || fail "first drain failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/2.out" 2>/dev/null || fail "second drain failed"
  grep -F 'build green' "$dir/2.out" >/dev/null || fail "unacked wake was not re-presented: $(cat "$dir/2.out")"
  [ ! -s "$log" ] || fail "re-presented unacked row logged a would-skip: $(cat "$log")"
  pass "re-draining an unacknowledged row never logs a would-skip"
}

test_batch_compares_in_sequence_order() {
  local dir state log
  dir=$(make_case order); state="$dir/state"; log="$state/.wake-would-skip.log"
  append_wake "$state" check job-a "build green"
  append_wake "$state" check job-a "build red"
  append_wake "$state" check job-a "build green"
  drain_ack "$state" "$dir/1.out"
  append_wake "$state" check job-a "build red"
  drain_ack "$state" "$dir/2.out"
  [ ! -s "$log" ] || fail "red after a newest green logged a would-skip: $(cat "$log")"
  pass "rows in one drain are compared in sequence order, not presentation order"
}

test_equal_facts_log_one_would_skip_and_still_present
test_batch_compares_in_sequence_order
test_redrain_without_ack_does_not_log
test_changed_facts_and_other_sources_do_not_log
