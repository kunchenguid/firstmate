#!/usr/bin/env bash
# tests/fm-agy-quota-lib.test.sh - the regression for agy quota EVIDENCE.
#
# bin/fm-agy-ladder-lib.sh only refuses a launch on positive evidence, so every
# way of silently losing a reading is a way of silently not enforcing the
# captain's 25% Opus 4.6 floor. Each case below pins one of those ways shut:
#
#   1. An ANSI-wrapped footer must record under the SAME key a reader looks up.
#      Keying by the escape-laden model string wrote a reading nothing could
#      ever find - the most dangerous failure here, because it looks like a
#      success on disk.
#   2. Whitespace around the separators must not decide whether a reading
#      exists at all.
#   3. A reading must age out on an absolute ceiling, not only on its own reset
#      window. Quota falls monotonically inside a window, so a reading taken
#      early in one overstates what is left for the rest of it.
#   4. An unparseable or "0m" reset window must NOT discard an otherwise valid
#      percentage; the ceiling above is the guarantee.
#   5. A non-numeric percentage is an absence of evidence, never a zero.
#   6. The live intake poll must turn agy's own quota answer into readings for
#      every rung, and must fail soft when it cannot.
#   7. The in-flight ledger must count recent launches and forget old ones.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-agy-quota-lib.sh
. "$ROOT/bin/fm-agy-quota-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-quota-lib)

# The library reads its bounds at call time, so a case can drive them directly.
export FM_AGY_QUOTA_MAX_AGE=300
export FM_AGY_INFLIGHT_TTL=300

# Every reading below is stamped explicitly and read back against an offset from
# the same stamp. Reading ages are load-bearing here - the whole defect was an
# age being ignored - so a case must never race the second hand between
# recording a reading and asking how old it is.
NOW=$(date +%s)

assert_eq() {
  local expected=$1 actual=$2
  if [ "$expected" != "$actual" ]; then
    fail "expected '$expected' but got '$actual'"
  fi
}

new_state() {
  local dir="$TMP_ROOT/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

echo "Testing fm_agy_parse_reset_time"
assert_eq "15840" "$(fm_agy_parse_reset_time '4h 24m')"
assert_eq "2700" "$(fm_agy_parse_reset_time '45m')"
assert_eq "93600" "$(fm_agy_parse_reset_time '1d 2h')"
assert_eq "30" "$(fm_agy_parse_reset_time '30s')"
assert_eq "0" "$(fm_agy_parse_reset_time 'soon')"
pass "fm_agy_parse_reset_time logic works"

echo "Testing observe and read valid"
state=$(new_state state1)

footer="Gemini 3.1 Pro (High) | ctx: 10.5% | quota: 94.7% (4h 24m)"
fm_agy_quota_observe "$footer" "$state" "$NOW"

res=$(fm_agy_quota_read "Gemini 3.1 Pro (High)" "$state" "$NOW")
assert_eq "94.7 0" "$res"

# Advance time by 10 seconds
res=$(fm_agy_quota_read "Gemini 3.1 Pro (High)" "$state" "$((NOW + 10))")
assert_eq "94.7 10" "$res"
pass "observe and read valid handles normal cases"

echo "Testing read older than reset window"
state=$(new_state state2)

footer="Claude Opus 4.6 (Thinking) | ctx: 5% | quota: 14.7% (1h 0m)"
fm_agy_quota_observe "$footer" "$state" "$NOW"

# 3600 seconds is the window.
res=$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")
assert_eq "14.7 0" "$res"

# 3600 seconds later -> reset. With the ceiling raised past the window so this
# case turns on the window alone and cannot pass for the ceiling's reason.
res=$(FM_AGY_QUOTA_MAX_AGE=7200 fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$((NOW + 3600))")
assert_eq "unknown" "$res"
pass "older than window returns unknown"

echo "Testing missing and ambiguous"
state=$(new_state state3)

# Missing
res=$(fm_agy_quota_read "No Such Model" "$state" "$NOW")
assert_eq "unknown" "$res"

# Ambiguous formatting (missing ctx but has quota, observe will reject it)
footer="Ambiguous Model | quota: 50% (1h)"
fm_agy_quota_observe "$footer" "$state" "$NOW"
res=$(fm_agy_quota_read "Ambiguous Model" "$state" "$NOW")
assert_eq "unknown" "$res"
pass "missing and ambiguous readings fail open"

echo "Testing set -u compliance with 2 arguments"
state=$(new_state state4)
footer="Model Two Args | ctx: 10% | quota: 50% (1h)"
# Recorded on the wall clock, because the wall-clock default is exactly what
# the two-argument form exercises. Only the value is asserted; the age is
# whatever the clock says and is pinned deterministically elsewhere.
fm_agy_quota_observe "$footer" "$state"
# This call must not crash under set -u
res=$(fm_agy_quota_read "Model Two Args" "$state")
assert_eq "50" "${res%% *}"
pass "set -u compliance with 2 arguments works"

# --- 1. ANSI ----------------------------------------------------------------
#
# The reading is stored under a key derived from the model name. When the
# capture carried escape codes, that key differed from the clean one the ladder
# looks up, so a file was written that no reader could ever find: the floor lost
# its evidence while every surface said a reading had been recorded.

echo "Testing ANSI-wrapped footer"
state=$(new_state ansi)
esc=$'\033'
footer="${esc}[1mClaude Opus 4.6 (Thinking)${esc}[0m | ctx: ${esc}[32m5.0%${esc}[0m | quota: ${esc}[33m20.0%${esc}[0m (2h 0m)"
fm_agy_quota_observe "$footer" "$state" "$NOW"

# Looked up by the CLEAN name, which is the only name any caller has.
res=$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")
assert_eq "20.0 0" "$res"

# And the orphaned key the old parser would have written must not exist, so the
# case cannot pass because some other file happened to answer.
[ "$(find "$state" -name '.agy-quota-*' | wc -l | tr -d ' ')" = 1 ] \
  || fail "an ANSI footer must record exactly one reading, under the clean key"
pass "an ANSI-wrapped footer records under the clean model key, not an orphaned one"

# --- 2. Whitespace ----------------------------------------------------------

echo "Testing whitespace variation"
state=$(new_state whitespace)
fm_agy_quota_observe "Claude Opus 4.6 (Thinking)  |  ctx:  5.0%  |  quota:  20.0%  (2h 0m)" "$state" "$NOW"
assert_eq "20.0 0" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")"

state=$(new_state whitespace-tight)
fm_agy_quota_observe "Claude Opus 4.6 (Thinking)|ctx:5.0%|quota:20.0% (2h 0m)" "$state" "$NOW"
assert_eq "20.0 0" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")"

# A trailing pane line after the footer must not steal the reading either.
state=$(new_state whitespace-multiline)
fm_agy_quota_observe "irrelevant chatter
Claude Opus 4.6 (Thinking) | ctx: 5.0% | quota: 20.0% (2h 0m)" "$state" "$NOW"
assert_eq "20.0 0" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")"
pass "padded, tight, and multi-line footers all record the same reading"

# --- 3. The max-age ceiling -------------------------------------------------
#
# This is the case the whole defect turned on: a reading INSIDE its own reset
# window but far too old to describe the account now.

echo "Testing the max-age ceiling"
state=$(new_state ceiling)
fm_agy_quota_observe "Claude Opus 4.6 (Thinking) | ctx: 5% | quota: 95.0% (5h 0m)" "$state" "$NOW"

assert_eq "95.0 0" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")"
assert_eq "95.0 299" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$((NOW + 299))")"

# One second past the ceiling, and still four and a half hours inside its own
# 5h window, the reading stops being evidence. Under the window-only rule this
# same reading authorised launches for the whole five hours.
assert_eq "unknown" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$((NOW + 300))")"
assert_eq "unknown" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$((NOW + 16200))")"

# Prove the window is genuinely still open at that moment, so the case cannot
# go vacuous by the window having quietly elapsed instead.
[ "$(fm_agy_parse_reset_time '5h 0m')" -gt 300 ] \
  || fail "this case must age a reading out while its own window is still open"
pass "a reading past the ceiling is unknown even with hours of its reset window left"

# --- 4. Reset windows that do not parse -------------------------------------
#
# The percentage is the evidence. Discarding a perfectly good 20% because the
# window beside it said "0m" was a silent fail-open at the exact moment the
# percentage mattered most.

echo "Testing unparseable and 0m reset windows"
for window in 'forever' '0m' 'soon' ''; do
  state=$(new_state "reset-$(printf '%s' "${window:-empty}" | tr -c 'a-z0-9' '-')")
  if [ -n "$window" ]; then
    fm_agy_quota_observe "Claude Opus 4.6 (Thinking) | ctx: 5% | quota: 20.0% ($window)" "$state" "$NOW"
  else
    fm_agy_quota_observe "Claude Opus 4.6 (Thinking) | ctx: 5% | quota: 20.0%" "$state" "$NOW"
  fi
    assert_eq "20.0 0" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")"
  # Still governed by the ceiling, which is the only bound left.
  assert_eq "unknown" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$((NOW + 300))")"
done
pass "an unparseable, 0m, or absent reset window keeps the reading under the ceiling"

# --- 5. Non-numeric percentages ---------------------------------------------

echo "Testing non-numeric percentages"
for bad in '--' 'n/a' '' 'NaN'; do
  state=$(new_state "nonnum-$(printf '%s' "${bad:-empty}" | tr -c 'a-z0-9' '-')")
  fm_agy_quota_observe "Claude Opus 4.6 (Thinking) | ctx: 5% | quota: $bad (2h 0m)" "$state" "$NOW"
  res=$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")
  [ "$res" = unknown ] || fail "a '$bad' percentage must read unknown, got '$res'"
done
# Specifically: it must never be recorded AS a zero, which on this scale is the
# most consequential number there is.
[ "$(find "$TMP_ROOT/nonnum---" -name '.agy-quota-*' 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  || fail "a non-numeric percentage must record nothing at all"
pass "a non-numeric percentage reads unknown and is never stored as zero"

# --- 6. The live intake poll ------------------------------------------------
#
# Driven through a stub `agy` on PATH that emits the real command's JSON shape,
# so this exercises the actual parse, conversion, and record path without any
# network call or a single token of quota.

fake_agy() {  # <dir> <body>
  local dir=$1 body=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/agy" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"--print /quota"*|*"/quota"*) cat <<'JSON'
$body
JSON
  ;;
esac
exit 0
SH
  chmod +x "$fakebin/agy"
  printf '%s\n' "$fakebin"
}

echo "Testing the live intake poll"
state=$(new_state poll)
# Two rungs at once, which is the point: the ladder needs the requested rung for
# its floor AND every rung above it to judge a descent, and one call answers all
# of them.
fakebin=$(fake_agy "$state" '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"All Models","buckets":[
  {"id":"claude-opus-4-6-thinking","name":"Claude Opus 4.6 (Thinking)","remaining_fraction":0.201,"reset_time":""},
  {"id":"gemini-3.1-pro-high","name":"Gemini 3.1 Pro (High)","remaining_fraction":0.883,"reset_time":""}
]}]}}}')

if ! command -v jq >/dev/null 2>&1; then
  echo "skip - the intake poll needs jq, which is absent on this host"
else
  PATH="$fakebin:$PATH" fm_agy_quota_poll "$state" "$NOW" \
    || fail "the poll must record a reading from a well-formed quota answer"
  assert_eq "20.1 0" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")"
  assert_eq "88.3 0" "$(fm_agy_quota_read "Gemini 3.1 Pro (High)" "$state" "$NOW")"
  pass "the intake poll records a current reading for every rung from one call"

  # Failing soft is the captain's no-stall ruling in code: a poll that cannot
  # answer must leave prior evidence alone and report that it did not answer,
  # never raise and never invent a reading.
  echo "Testing that the poll fails soft"
  state=$(new_state poll-soft)
  fm_agy_quota_observe "Claude Opus 4.6 (Thinking) | ctx: 5% | quota: 42.0% (2h 0m)" "$state" "$NOW"
  for body in '' 'not json at all' '{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[]}}}'; do
    fakebin=$(fake_agy "$state" "$body")
    rc=0
    PATH="$fakebin:$PATH" fm_agy_quota_poll "$state" "$NOW" || rc=$?
    [ "$rc" -eq 1 ] || fail "an unusable quota answer must report no reading (rc=$rc)"
    assert_eq "42.0 0" "$(fm_agy_quota_read "Claude Opus 4.6 (Thinking)" "$state" "$NOW")"
  done

  # An absent agy is the same ordinary outcome, not an error.
  rc=0
  ( PATH=$(new_state empty-path); export PATH; HOME=$TMP_ROOT/no-home fm_agy_quota_poll "$state" ) || rc=$?
  [ "$rc" -eq 1 ] || fail "an absent agy must report no reading rather than failing loudly (rc=$rc)"

  # And the explicit off switch never runs a subprocess at all.
  rc=0
  FM_AGY_QUOTA_POLL=off fm_agy_quota_poll "$state" || rc=$?
  [ "$rc" -eq 1 ] || fail "FM_AGY_QUOTA_POLL=off must decline to poll"
  pass "the poll fails soft on bad output, an absent agy, and the off switch, preserving prior evidence"
fi

# --- 7. The in-flight ledger ------------------------------------------------

echo "Testing the in-flight ledger"
state=$(new_state inflight)

assert_eq "0" "$(fm_agy_inflight_count 1 "$state" "$NOW")"

fm_agy_inflight_record 1 "$state" "$NOW"
fm_agy_inflight_record 1 "$state" "$NOW"
fm_agy_inflight_record 2 "$state" "$NOW"
assert_eq "2" "$(fm_agy_inflight_count 1 "$state" "$NOW")"
assert_eq "1" "$(fm_agy_inflight_count 2 "$state" "$NOW")"
assert_eq "0" "$(fm_agy_inflight_count 3 "$state" "$NOW")"

# Just inside the TTL a launch still counts; past it, a current reading already
# includes its consumption and counting it again would reserve headroom that is
# not at risk.
assert_eq "2" "$(fm_agy_inflight_count 1 "$state" "$((NOW + 299))")"
assert_eq "0" "$(fm_agy_inflight_count 1 "$state" "$((NOW + 300))")"

# Expiry prunes the ledger rather than letting it grow for the life of the home.
fm_agy_inflight_count 1 "$state" "$((NOW + 300))" >/dev/null
[ ! -s "$state/.agy-inflight" ] || fail "expired reservations must be pruned from the ledger"
pass "the in-flight ledger counts recent launches per rung and forgets expired ones"

echo "ALL TESTS PASSED"
