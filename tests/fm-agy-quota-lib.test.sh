#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-agy-quota-lib.sh
. "$ROOT/bin/fm-agy-quota-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-quota-lib)

assert_eq() {
  local expected=$1 actual=$2
  if [ "$expected" != "$actual" ]; then
    fail "expected '$expected' but got '$actual'"
  fi
}

echo "Testing fm_agy_parse_reset_time"
assert_eq "15840" "$(fm_agy_parse_reset_time '4h 24m')"
assert_eq "2700" "$(fm_agy_parse_reset_time '45m')"
assert_eq "93600" "$(fm_agy_parse_reset_time '1d 2h')"
assert_eq "30" "$(fm_agy_parse_reset_time '30s')"
pass "fm_agy_parse_reset_time logic works"

echo "Testing observe and read valid"
state="$TMP_ROOT/state1"
mkdir -p "$state"

footer="Gemini 3.1 Pro (High) | ctx: 10.5% | quota: 94.7% (4h 24m)"
fm_agy_quota_observe "$footer" "$state"

now=$(date +%s)
res=$(fm_agy_quota_read "Gemini 3.1 Pro (High)" "$state" "$now")
assert_eq "94.7 0" "$res"

# Advance time by 10 seconds
res=$(fm_agy_quota_read "Gemini 3.1 Pro (High)" "$state" "$((now + 10))")
assert_eq "94.7 10" "$res"
pass "observe and read valid handles normal cases"

echo "Testing read older than reset window"
state="$TMP_ROOT/state2"
mkdir -p "$state"

footer="Claude Opus 4.6 (Thinking) | ctx: 5% | quota: 14.7% (1h 0m)"
fm_agy_quota_observe "$footer" "$state"

now=$(date +%s)

# 3600 seconds is the window.
res=$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$now")
assert_eq "14.7 0" "$res"

# 3600 seconds later -> reset
res=$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$((now + 3600))")
assert_eq "unknown" "$res"
pass "older than window returns unknown"

echo "Testing missing, unparseable, ambiguous"
state="$TMP_ROOT/state3"
mkdir -p "$state"

# Missing
res=$(fm_agy_quota_read "No Such Model" "$state" "$(date +%s)")
assert_eq "unknown" "$res"

# Unparseable reset time
footer="Bad Model | ctx: 0% | quota: 50% (forever)"
fm_agy_quota_observe "$footer" "$state"
res=$(fm_agy_quota_read "Bad Model" "$state" "$(date +%s)")
assert_eq "unknown" "$res"

# Ambiguous formatting (missing ctx but has quota, observe will reject it)
footer="Ambiguous Model | quota: 50% (1h)"
fm_agy_quota_observe "$footer" "$state"
res=$(fm_agy_quota_read "Ambiguous Model" "$state" "$(date +%s)")
assert_eq "unknown" "$res"
pass "missing unparseable ambiguous fail open"

echo "Testing set -u compliance with 2 arguments"
state="$TMP_ROOT/state4"
mkdir -p "$state"
footer="Model Two Args | ctx: 10% | quota: 50% (1h)"
fm_agy_quota_observe "$footer" "$state"
# This call must not crash under set -u
res=$(fm_agy_quota_read "Model Two Args" "$state")
# It should successfully read the value (age will be 0 as it was just observed)
assert_eq "50 0" "$res"
pass "set -u compliance with 2 arguments works"

echo "ALL TESTS PASSED"
