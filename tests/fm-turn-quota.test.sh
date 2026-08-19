#!/usr/bin/env bash
# tests/fm-turn-quota.test.sh - unit and behavior tests for per-turn quota instrumentation.
#
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_DIR=$(fm_test_tmproot "fm-turn-quota")
STATE_DIR="$TEST_DIR/state"
HOME_DIR="$TEST_DIR"
mkdir -p "$STATE_DIR" "$HOME_DIR/data" "$HOME_DIR/bin"

# Create minimal AGENTS.md and secondmate marker so primary scope check passes
touch "$HOME_DIR/AGENTS.md"
echo "test-primary" > "$HOME_DIR/.fm-secondmate-home"

# --- Test 1: Synthetic log parsing in reader -------------------------------
SYNTH_LOG="$TEST_DIR/synth-quota.log"
cat > "$SYNTH_LOG" << 'LOG'
1000	captain	fpA	1	10	5	2026-07-31T20:00:00Z	absent	absent
1010	stale	fpA	0	12	5	2026-07-31T20:00:10Z	absent	absent
1020	signal	fpB	1	18	7	2026-07-31T20:00:20Z	absent	absent
1030	heartbeat	fpB	0	20	7	2026-07-31T20:00:30Z	absent	absent
LOG

REPORT_OUT=$("$ROOT/bin/fm-turn-quota-reader.sh" --log="$SYNTH_LOG")

assert_contains "$REPORT_OUT" "Total turns: 4" "reader reported incorrect total turn count"
assert_contains "$REPORT_OUT" "Proxy no-op (fingerprint unchanged): 2 (50.0%)" "reader reported incorrect no-op ratio"
assert_contains "$REPORT_OUT" "Claude 5-hour:  total delta 10.00% | 2.50% / turn | 5.00% / changed turn" "reader computed incorrect Claude 5h deltas"
assert_contains "$REPORT_OUT" "Claude 7-day:   total delta 2.00% | 0.50% / turn | 1.00% / changed turn" "reader computed incorrect Claude 7d deltas"
assert_contains "$REPORT_OUT" "Gemini / agy:   absent" "reader must report absent when Gemini readings are missing"
assert_not_contains "$REPORT_OUT" "Gemini / agy:   total delta 0" "reader must never coerce missing Gemini quota to zero"
assert_contains "$REPORT_OUT" "NOTICE: Proxy state fingerprint metric" "reader must print proxy notice"

pass "reader computes synthetic no-op ratio, quota deltas, and absent markers correctly"

# --- Test 2: Writer behavior with missing antigravity-usage -----------------
FAKE_BIN="$TEST_DIR/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/quota-axi" << 'SH'
#!/bin/sh
if [ "$1" = "--json" ]; then
  cat << 'JSON'
{
  "generatedAt": "2026-07-31T22:00:00.000Z",
  "providers": [
    {
      "provider": "claude",
      "windows": [
        {"id": "five_hour", "percentUsed": 30},
        {"id": "seven_day", "percentUsed": 15}
      ]
    }
  ]
}
JSON
fi
SH
chmod +x "$FAKE_BIN/quota-axi"

# Run writer with fakebin (quota-axi present, antigravity-usage absent)
LOG_FILE1="$STATE_DIR/quota-turns-1.log"
PATH="$FAKE_BIN:/bin:/usr/bin" \
FM_ROOT_OVERRIDE="$HOME_DIR" \
FM_HOME="$HOME_DIR" \
FM_STATE_OVERRIDE="$STATE_DIR" \
FM_QUOTA_LOG_OVERRIDE="$LOG_FILE1" \
"$ROOT/bin/fm-turn-quota-writer.sh"

[ -f "$LOG_FILE1" ] || fail "writer did not create log file"
LINE1=$(cat "$LOG_FILE1")

# Verify line fields: epoch, wake_kind, fp, fp_changed, c5, c7, c_gen, g_used, g_gen
W_KIND=$(printf '%s' "$LINE1" | awk -F '\t' '{print $2}')
FP_CHG=$(printf '%s' "$LINE1" | awk -F '\t' '{print $4}')
C5=$(printf '%s' "$LINE1" | awk -F '\t' '{print $5}')
C7=$(printf '%s' "$LINE1" | awk -F '\t' '{print $6}')
C_GEN=$(printf '%s' "$LINE1" | awk -F '\t' '{print $7}')
G_USED=$(printf '%s' "$LINE1" | awk -F '\t' '{print $8}')
G_GEN=$(printf '%s' "$LINE1" | awk -F '\t' '{print $9}')

[ "$W_KIND" = "captain" ] || fail "default wake kind should be captain (got: $W_KIND)"
[ "$FP_CHG" = "1" ] || fail "first line fp_changed should be 1 (got: $FP_CHG)"
[ "$C5" = "30" ] || fail "Claude 5h should be 30 (got: $C5)"
[ "$C7" = "15" ] || fail "Claude 7d should be 15 (got: $C7)"
[ "$C_GEN" = "2026-07-31T22:00:00.000Z" ] || fail "Claude generatedAt mismatch (got: $C_GEN)"
[ "$G_USED" = "absent" ] || fail "missing antigravity-usage must produce absent marker (got: $G_USED)"
[ "$G_GEN" = "absent" ] || fail "missing antigravity-usage generatedAt must be absent (got: $G_GEN)"

pass "writer records quota-axi values and absent marker for missing antigravity-usage"

# --- Test 3: Durable wake kind recording & fingerprint dedup -------------
printf 'signal\n' > "$STATE_DIR/.turn-wake-kind"

PATH="$FAKE_BIN:/bin:/usr/bin" \
FM_ROOT_OVERRIDE="$HOME_DIR" \
FM_HOME="$HOME_DIR" \
FM_STATE_OVERRIDE="$STATE_DIR" \
FM_QUOTA_LOG_OVERRIDE="$LOG_FILE1" \
"$ROOT/bin/fm-turn-quota-writer.sh"

LINE2=$(tail -n 1 "$LOG_FILE1")
W_KIND2=$(printf '%s' "$LINE2" | awk -F '\t' '{print $2}')
FP_CHG2=$(printf '%s' "$LINE2" | awk -F '\t' '{print $4}')

[ "$W_KIND2" = "signal" ] || fail "durable wake kind signal must be recorded (got: $W_KIND2)"
[ "$FP_CHG2" = "0" ] || fail "unchanged state must produce fp_changed = 0 (got: $FP_CHG2)"

pass "writer reads durable wake kind and detects unchanged state fingerprint"

# --- Test 4: CLI wrapper ----------------------------------------------------
CLI_OUT=$("$ROOT/bin/fm-turn-quota.sh" report --log="$LOG_FILE1")
assert_contains "$CLI_OUT" "Total turns: 2" "CLI wrapper failed to render report"
assert_contains "$CLI_OUT" "Proxy no-op (fingerprint unchanged): 1 (50.0%)" "CLI wrapper no-op ratio mismatch"

pass "bin/fm-turn-quota.sh CLI wrapper delegates to reader correctly"

# --- Test 5: Unknown subcommand fails loudly -------------------------------
if "$ROOT/bin/fm-turn-quota.sh" writ --log="$LOG_FILE1" >/dev/null 2>&1; then
  fail "unknown subcommand must not silently fall through to the reader"
fi

pass "CLI wrapper rejects an unknown subcommand instead of silently reporting"

# --- Test 6: Absent fingerprint is excluded, never counted as a no-op -------
ABSENT_LOG="$TEST_DIR/absent-fp.log"
cat > "$ABSENT_LOG" << 'LOG'
1000	captain	absent	absent	absent	absent	absent	absent	absent
1010	captain	absent	absent	absent	absent	absent	absent	absent
1020	signal	fpA	1	absent	absent	absent	absent	absent
1030	signal	fpA	0	absent	absent	absent	absent	absent
LOG

ABSENT_OUT=$("$ROOT/bin/fm-turn-quota-reader.sh" --log="$ABSENT_LOG")
assert_contains "$ABSENT_OUT" "Total turns: 4" "reader dropped absent-fingerprint records from the turn count"
assert_contains "$ABSENT_OUT" "Proxy no-op (fingerprint unchanged): 1 (50.0%)" "absent fingerprints must be excluded from the proxy no-op ratio, not counted as no-ops"
assert_contains "$ABSENT_OUT" "Fingerprint absent (excluded from proxy ratios): 2" "reader must disclose excluded absent-fingerprint records"

ALL_ABSENT_LOG="$TEST_DIR/all-absent-fp.log"
head -n 2 "$ABSENT_LOG" > "$ALL_ABSENT_LOG"
ALL_ABSENT_OUT=$("$ROOT/bin/fm-turn-quota-reader.sh" --log="$ALL_ABSENT_LOG")
assert_contains "$ALL_ABSENT_OUT" "Proxy no-op (fingerprint unchanged): absent" "reader must never fabricate a no-op ratio when every fingerprint is absent"

pass "reader treats an absent fingerprint as absent rather than as a proxy no-op"

# --- Test 7: Writer emits absent fingerprint when no hasher exists ----------
NOHASH_BIN="$TEST_DIR/nohashbin"
mkdir -p "$NOHASH_BIN"
for stub in sha256sum shasum; do
  printf '#!/bin/sh\nexit 1\n' > "$NOHASH_BIN/$stub"
  chmod +x "$NOHASH_BIN/$stub"
done

LOG_FILE2="$STATE_DIR/quota-turns-2.log"
PATH="$NOHASH_BIN:$PATH" \
FM_ROOT_OVERRIDE="$HOME_DIR" \
FM_HOME="$HOME_DIR" \
FM_STATE_OVERRIDE="$STATE_DIR" \
FM_QUOTA_LOG_OVERRIDE="$LOG_FILE2" \
"$ROOT/bin/fm-turn-quota-writer.sh"

NOHASH_LINE=$(tail -n 1 "$LOG_FILE2" 2>/dev/null || true)
NOHASH_FP=$(printf '%s' "$NOHASH_LINE" | awk -F '\t' '{print $3}')
NOHASH_CHG=$(printf '%s' "$NOHASH_LINE" | awk -F '\t' '{print $4}')

[ "$NOHASH_FP" = "absent" ] || fail "unhashable state must record an absent fingerprint (got: $NOHASH_FP)"
[ "$NOHASH_CHG" = "absent" ] || fail "unhashable state must record an absent fp_changed, never 0 (got: $NOHASH_CHG)"

pass "writer records an absent fingerprint instead of a fabricated constant"

# --- Test 8: Gemini accounting picks the scarcest dispatch-eligible pool ----
# An autocomplete-only pool is never spent by the fleet, so it must not become
# the recorded budget just because it is the scarcest entry in .models.
agy_used_for() { # agy_used_for <models-json> -> recorded gemini used field
  local models=$1 bindir statedir logfile
  bindir="$TEST_DIR/agybin-$2"
  statedir="$TEST_DIR/agystate-$2"
  logfile="$TEST_DIR/agy-$2.log"
  mkdir -p "$bindir" "$statedir"
  {
    printf '#!/bin/sh\n'
    printf 'printf %s\n' "'{\"timestamp\":\"2026-08-01T09:00:00Z\",\"models\":$models}'"
  } > "$bindir/antigravity-usage"
  chmod +x "$bindir/antigravity-usage"
  PATH="$bindir:$PATH" \
  FM_ROOT_OVERRIDE="$HOME_DIR" \
  FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$statedir" \
  FM_QUOTA_LOG_OVERRIDE="$logfile" \
  "$ROOT/bin/fm-turn-quota-writer.sh"
  tail -n 1 "$logfile" 2>/dev/null | awk -F '\t' '{print $8"\t"$9}'
}

AGY_PCT=$(agy_used_for '[{"modelId":"gemini-3-pro","isAutocompleteOnly":false,"remainingPercentage":80},{"modelId":"gemini-3-flash","isAutocompleteOnly":false,"remainingPercentage":60},{"modelId":"gemini-3-flash-autocomplete","isAutocompleteOnly":true,"remainingPercentage":5},{"modelId":"other-model","remainingPercentage":1}]' pct)
AGY_PCT_USED=$(printf '%s' "$AGY_PCT" | awk -F '\t' '{print $1}')
AGY_PCT_TS=$(printf '%s' "$AGY_PCT" | awk -F '\t' '{print $2}')

[ "$AGY_PCT_USED" = "40" ] || fail "gemini used must be 100 - scarcest dispatch-eligible remaining (expected 40, got: $AGY_PCT_USED)"
[ "$AGY_PCT_TS" = "2026-08-01T09:00:00Z" ] || fail "gemini generatedAt must come from the probe timestamp (got: $AGY_PCT_TS)"

AGY_FRAC=$(agy_used_for '[{"modelId":"gemini-3-pro","isAutocompleteOnly":false,"remainingPercentage":0.25}]' frac)
AGY_FRAC_USED=$(printf '%s' "$AGY_FRAC" | awk -F '\t' '{print $1}')
[ "$AGY_FRAC_USED" = "75" ] || fail "a 0..1 remaining fraction must convert to a percent used (expected 75, got: $AGY_FRAC_USED)"

pass "writer prices the scarcest dispatch-eligible gemini pool and ignores autocomplete-only pools"
