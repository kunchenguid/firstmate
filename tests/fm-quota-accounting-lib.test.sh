#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-accounting-lib.sh: the opening and closing
# quota readings recorded around a task, the same-window rule that makes a
# delta publishable, the never-a-gate guarantee that every entry point
# succeeds and records why a reading is unavailable, the atomic key-replace
# meta writer, and the plain-English summary. Drives the library through its
# documented sourced interface with a PATH-faked quota-axi.
# shellcheck disable=SC1091 # the sourced test lib and bin libraries resolve at runtime
# shellcheck disable=SC2030,SC2031 # each case deliberately scopes PATH and the fake's env knobs inside one command-substitution subshell
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-accounting)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

# The fake quota-axi: version and snapshot both come from the environment, so
# each case picks its vendor behavior without rewriting the shim.
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'quota-axi %s\n' "${FAKE_QUOTA_VERSION:-0.1.51}"
  exit 0
fi
[ "${FAKE_QUOTA_JSON_RC:-0}" = 0 ] || exit "$FAKE_QUOTA_JSON_RC"
cat "$FAKE_QUOTA_SNAPSHOT"
SH
chmod +x "$FAKEBIN/quota-axi"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$ROOT/bin/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-quota-accounting-lib.sh
. "$ROOT/bin/fm-quota-accounting-lib.sh"

has_line() {  # <haystack> <exact line>
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

line_value() {  # <haystack> <key> -> value of the single key= line
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# --- snapshot fixtures -------------------------------------------------------

# Opening snapshot: the claude provider carries a session window and a weekly
# window that resets SOONER, so the session pick below proves kind preference
# rather than soonest-reset order. The codex row proves provider selection.
SNAP_START="$TMP_ROOT/start.json"
cat > "$SNAP_START" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"codex",
  "windows":[{"id":"five_hour","kind":"session","percentRemaining":10,"resetsAt":"2026-10-01T01:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"through_reset"}}]}},
 {"provider":"claude",
  "windows":[
    {"id":"five_hour","kind":"session","percentRemaining":87.5,"resetsAt":"2026-10-01T05:00:00.123+00:00"},
    {"id":"weekly","kind":"week","percentRemaining":64,"resetsAt":"2026-09-30T23:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":87.5,"runway":{"status":"through_reset"}}]}}
]}
JSON

# Closing snapshot: same window identity (the reset spelling differs only in
# the fractional seconds and offset the library normalizes away).
SNAP_END="$TMP_ROOT/end.json"
cat > "$SNAP_END" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"claude",
  "windows":[
    {"id":"five_hour","kind":"session","percentRemaining":42.25,"resetsAt":"2026-10-01T05:00:00Z"},
    {"id":"weekly","kind":"week","percentRemaining":60,"resetsAt":"2026-09-30T23:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":42.25,"runway":{"status":"through_reset"}}]}}
]}
JSON

# Closing snapshot whose delta needs rounding: 87.5 - 42.333 = 45.167 -> 45.17.
SNAP_END_ROUND="$TMP_ROOT/end-round.json"
cat > "$SNAP_END_ROUND" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"claude",
  "windows":[{"id":"five_hour","kind":"session","percentRemaining":42.333,"resetsAt":"2026-10-01T05:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":42.333,"runway":{"status":"through_reset"}}]}}
]}
JSON

# Closing snapshot whose resetsAt jittered across a whole-second boundary
# (live quota-axi reports sub-second jitter): same window, one second later.
SNAP_END_JITTER="$TMP_ROOT/end-jitter.json"
cat > "$SNAP_END_JITTER" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"claude",
  "windows":[{"id":"five_hour","kind":"session","percentRemaining":42.25,"resetsAt":"2026-10-01T05:00:01.02Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":42.25,"runway":{"status":"through_reset"}}]}}
]}
JSON

# Closing snapshot after the window refilled: same id, new reset time.
SNAP_END_RESET="$TMP_ROOT/end-reset.json"
cat > "$SNAP_END_RESET" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"claude",
  "windows":[{"id":"five_hour","kind":"session","percentRemaining":99,"resetsAt":"2026-10-01T10:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":99,"runway":{"status":"through_reset"}}]}}
]}
JSON

# No session-kind window: the soonest reset must win.
SNAP_NOSESSION="$TMP_ROOT/nosession.json"
cat > "$SNAP_NOSESSION" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"claude",
  "windows":[
    {"id":"monthly","kind":"month","percentRemaining":70,"resetsAt":"2026-10-28T00:00:00Z"},
    {"id":"weekly","kind":"week","percentRemaining":64,"resetsAt":"2026-10-04T00:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":64,"runway":{"status":"through_reset"}}]}}
]}
JSON

# A malformed session window (string percentRemaining) must be filtered out,
# leaving the valid weekly window as the pick.
SNAP_FILTER="$TMP_ROOT/filter.json"
cat > "$SNAP_FILTER" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"claude",
  "windows":[
    {"id":"five_hour","kind":"session","percentRemaining":"87.5","resetsAt":"2026-10-01T05:00:00Z"},
    {"id":"weekly","kind":"week","percentRemaining":64,"resetsAt":"2026-10-04T00:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":64,"runway":{"status":"through_reset"}}]}}
]}
JSON

# Windows absent entirely.
SNAP_NOWIN="$TMP_ROOT/nowin.json"
cat > "$SNAP_NOWIN" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"claude","windows":[],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":64,"runway":{"status":"through_reset"}}]}}
]}
JSON

# The claude provider is missing from the snapshot.
SNAP_OTHER="$TMP_ROOT/other.json"
cat > "$SNAP_OTHER" <<'JSON'
{"schemaVersion":5,"providers":[
 {"provider":"codex",
  "windows":[{"id":"five_hour","kind":"session","percentRemaining":10,"resetsAt":"2026-10-01T01:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"through_reset"}}]}}
]}
JSON

# A snapshot fm_quota_json_valid rejects (schema 4 is below the floor).
SNAP_BAD="$TMP_ROOT/bad.json"
printf '{"schemaVersion":4,"providers":[]}\n' > "$SNAP_BAD"

# Schema 6: the claude provider expanded to two accounts; a claude-harness
# candidate has no lane, so it must bind the "default" account.
SNAP_S6="$TMP_ROOT/schema6.json"
cat > "$SNAP_S6" <<'JSON'
{"schemaVersion":6,"providers":[
 {"provider":"claude","accountKey":"default",
  "windows":[{"id":"five_hour","kind":"session","percentRemaining":80,"resetsAt":"2026-10-01T05:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"}}]}},
 {"provider":"claude","accountKey":"claude-work",
  "windows":[{"id":"five_hour","kind":"session","percentRemaining":10,"resetsAt":"2026-10-01T05:00:00Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
    {"scope":"all_models","status":"known","effectivePercentRemaining":10,"runway":{"status":"through_reset"}}]}}
]}
JSON

# --- timeout guard -----------------------------------------------------------

assert_equals 20 "$(FM_QUOTA_ACCOUNTING_TIMEOUT=abc fm_quota_accounting_timeout)" \
  "non-numeric timeout did not fall back to the default"
assert_equals 20 "$(FM_QUOTA_ACCOUNTING_TIMEOUT=0 fm_quota_accounting_timeout)" \
  "zero timeout did not fall back to the default"
assert_equals 7 "$(FM_QUOTA_ACCOUNTING_TIMEOUT=7 fm_quota_accounting_timeout)" \
  "a valid timeout override was not honored"
pass "timeout env guard falls back to the default on invalid values"

# --- opening reading ---------------------------------------------------------

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_START"
  fm_quota_accounting_start_lines claude ""
) || fail "recorded opening reading exited non-zero"
has_line "$lines" 'quota_unit=percent_points_of_quota_window' \
  || fail "opening reading did not name its unit: $lines"
has_line "$lines" 'quota_provider=claude' || fail "opening reading bound the wrong provider: $lines"
has_line "$lines" 'quota_window=five_hour' \
  || fail "opening reading did not prefer the session window over the sooner-resetting weekly one: $lines"
has_line "$lines" 'quota_window_resets_at=2026-10-01T05:00:00Z' \
  || fail "opening reading did not normalize the reset time to UTC Z without fractional seconds: $lines"
has_line "$lines" 'quota_start_status=recorded' || fail "opening reading was not recorded: $lines"
has_line "$lines" 'quota_start_percent_remaining=87.5' \
  || fail "opening reading carried the wrong percent: $lines"
case "$(line_value "$lines" quota_start_at)" in
  ''|*[!0-9]*) fail "quota_start_at is not an epoch: $lines" ;;
esac
printf '%s\n' "$lines" | grep -q '^quota_account=' \
  && fail "a schema 5 reading must not record an account: $lines"
pass "opening reading records the session window with a normalized reset time"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_NOSESSION"
  fm_quota_accounting_start_lines claude ""
)
has_line "$lines" 'quota_window=weekly' \
  || fail "with no session window the soonest reset was not selected: $lines"
pass "window selection falls back to the soonest reset without a session window"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_FILTER"
  fm_quota_accounting_start_lines claude ""
)
has_line "$lines" 'quota_window=weekly' \
  || fail "a malformed session window was not filtered out of selection: $lines"
pass "a window missing its numeric percent is filtered rather than selected"

out=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_START"
  fm_quota_accounting_read claude "" weekly || exit 9
  printf '%s\n' "$FM_QUOTA_ACCOUNTING_WINDOW"
) || fail "pinned-window read failed"
assert_equals weekly "$out" "a preferred window id did not override the session default"
pass "a reading pinned to a window id anchors to that window"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_S6"
  fm_quota_accounting_start_lines claude ""
)
has_line "$lines" 'quota_account=default' \
  || fail "a schema 6 reading did not record the default account it bound: $lines"
has_line "$lines" 'quota_start_percent_remaining=80' \
  || fail "a schema 6 reading bound the wrong account row: $lines"
pass "a schema 6 reading records the account the row join bound"

# --- opening reading: unavailable, never a gate ------------------------------

SANS_QUOTA=$(fm_test_base_path_sans "$PATH" quota-axi)
lines=$(
  export PATH="$SANS_QUOTA"
  fm_quota_accounting_start_lines claude ""
) || fail "a missing quota-axi made the opening reading fail instead of recording unavailable"
has_line "$lines" 'quota_start_status=unavailable' \
  || fail "missing quota-axi was not recorded as unavailable: $lines"
has_line "$lines" 'quota_start_reason=quota-axi is not installed' \
  || fail "missing quota-axi reason was not recorded: $lines"
printf '%s\n' "$lines" | grep -q '^quota_window=' \
  && fail "an unavailable reading must not invent a window: $lines"
pass "a missing quota-axi is recorded as unavailable and never fails the hook"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_START" FAKE_QUOTA_VERSION=0.1.50
  fm_quota_accounting_start_lines claude ""
) || fail "a below-floor quota-axi made the opening reading fail"
has_line "$lines" 'quota_start_status=unavailable' \
  || fail "below-floor quota-axi was not recorded as unavailable: $lines"
assert_contains "$(line_value "$lines" quota_start_reason)" 'below the 0.1.51 compatibility floor' \
  "below-floor reason did not name the floor"
pass "a quota-axi below the compatibility floor records unavailable"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_START" FAKE_QUOTA_JSON_RC=3
  fm_quota_accounting_start_lines claude ""
) || fail "a failing quota-axi --json made the opening reading fail"
has_line "$lines" 'quota_start_status=unavailable' \
  || fail "failing --json was not recorded as unavailable: $lines"
assert_contains "$(line_value "$lines" quota_start_reason)" 'quota-axi --json failed or exceeded its' \
  "failing --json reason was not recorded"
pass "a failing quota-axi --json records unavailable"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_BAD"
  fm_quota_accounting_start_lines claude ""
) || fail "an invalid snapshot made the opening reading fail"
has_line "$lines" 'quota_start_reason=quota-axi --json returned a snapshot this firstmate cannot read' \
  || fail "invalid snapshot reason was not recorded: $lines"
pass "a snapshot the validator rejects records unavailable"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_START"
  fm_quota_accounting_start_lines devin ""
) || fail "an unmapped harness made the opening reading fail"
has_line "$lines" 'quota_start_reason=quota-axi tracks no provider for harness devin' \
  || fail "unmapped harness reason was not recorded: $lines"
pass "a harness quota-axi tracks no provider for records unavailable"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_OTHER"
  fm_quota_accounting_start_lines claude ""
) || fail "a snapshot without the provider made the opening reading fail"
has_line "$lines" 'quota_start_reason=provider claude is not in the quota snapshot' \
  || fail "absent-provider reason was not recorded: $lines"
pass "a provider missing from the snapshot records unavailable"

lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_NOWIN"
  fm_quota_accounting_start_lines claude ""
) || fail "a provider with no windows made the opening reading fail"
has_line "$lines" 'quota_start_reason=provider claude reports no resetting quota window' \
  || fail "no-window reason was not recorded: $lines"
pass "a provider with no usable window records unavailable"

# --- closing reading and delta validity --------------------------------------

write_start_meta() {  # <file> [extra key=val...]
  local file=$1
  shift
  fm_write_meta "$file" \
    id=t1 \
    harness=claude \
    model=default \
    quota_unit=percent_points_of_quota_window \
    quota_provider=claude \
    quota_window=five_hour \
    quota_window_resets_at=2026-10-01T05:00:00Z \
    quota_start_status=recorded \
    quota_start_at=1759000000 \
    quota_start_percent_remaining=87.5 \
    "$@"
}

META="$TMP_ROOT/t1.meta"

write_start_meta "$META"
lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_END"
  fm_quota_accounting_end_lines "$META"
) || fail "closing reading exited non-zero"
has_line "$lines" 'quota_end_status=recorded' || fail "closing reading was not recorded: $lines"
has_line "$lines" 'quota_end_percent_remaining=42.25' \
  || fail "closing reading carried the wrong percent: $lines"
has_line "$lines" 'quota_end_window=five_hour' \
  || fail "closing reading did not anchor to the dispatch window: $lines"
has_line "$lines" 'quota_end_window_resets_at=2026-10-01T05:00:00Z' \
  || fail "closing reset time was not normalized: $lines"
has_line "$lines" 'quota_delta_status=measured' \
  || fail "same-window readings did not produce a measured delta: $lines"
has_line "$lines" 'quota_delta_percent_points=45.25' \
  || fail "the measured delta is wrong: $lines"
pass "same-window readings publish a measured delta in percentage points"

write_start_meta "$META"
lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_END_ROUND"
  fm_quota_accounting_end_lines "$META"
)
has_line "$lines" 'quota_delta_percent_points=45.17' \
  || fail "the delta was not rounded to two decimals: $lines"
pass "a measured delta is rounded to two decimals"

write_start_meta "$META"
lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_END_JITTER"
  fm_quota_accounting_end_lines "$META"
)
has_line "$lines" 'quota_delta_status=measured' \
  || fail "a one-second resetsAt jitter discarded the measured delta: $lines"
has_line "$lines" 'quota_delta_percent_points=45.25' \
  || fail "the jitter-tolerant delta is wrong: $lines"
pass "sub-second resetsAt jitter across a second boundary still measures the delta"

write_start_meta "$META"
lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_END_RESET"
  fm_quota_accounting_end_lines "$META"
)
has_line "$lines" 'quota_delta_status=window_reset' \
  || fail "a reset window did not mark the delta unusable: $lines"
printf '%s\n' "$lines" | grep -q '^quota_delta_percent_points=' \
  && fail "a reset window must not publish a delta number: $lines"
pass "a window reset is reported as unusable rather than as a wrong number"

# The closing reading must anchor to the window the dispatch reading chose,
# not to the session window the vendor would pick fresh.
write_start_meta "$META"
fm_quota_accounting_meta_write "$META" <<'EOF' || fail "could not repoint the start window"
quota_window=weekly
quota_start_percent_remaining=64
quota_window_resets_at=2026-09-30T23:00:00Z
EOF
lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_END"
  fm_quota_accounting_end_lines "$META"
)
has_line "$lines" 'quota_end_window=weekly' \
  || fail "closing reading did not anchor to the dispatch window: $lines"
has_line "$lines" 'quota_delta_status=measured' \
  || fail "anchored closing reading did not measure: $lines"
has_line "$lines" 'quota_delta_percent_points=4' \
  || fail "anchored delta is wrong: $lines"
pass "the closing reading anchors to the window recorded at dispatch"

# A schema 6 closing reading binds the default account; a different recorded
# account is a different window identity, so the delta is unusable.
write_start_meta "$META" quota_account=claude-work
lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_S6"
  fm_quota_accounting_end_lines "$META"
)
has_line "$lines" 'quota_delta_status=window_reset' \
  || fail "an account mismatch did not mark the delta unusable: $lines"
pass "readings from different accounts never publish a delta"

fm_write_meta "$META" \
  id=t1 harness=claude model=default \
  quota_start_status=unavailable quota_start_at=1759000000 \
  'quota_start_reason=quota-axi is not installed'
lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_END"
  fm_quota_accounting_end_lines "$META"
)
has_line "$lines" 'quota_end_status=recorded' \
  || fail "a closing reading without a dispatch reading was not recorded: $lines"
has_line "$lines" 'quota_delta_status=no_start' \
  || fail "a missing dispatch reading did not mark the delta no_start: $lines"
pass "a closing reading without a dispatch reading records no_start"

write_start_meta "$META"
lines=$(
  export PATH="$FAKEBIN:$PATH" FAKE_QUOTA_SNAPSHOT="$SNAP_END" FAKE_QUOTA_JSON_RC=3
  fm_quota_accounting_end_lines "$META"
) || fail "a failing quota-axi made the closing reading fail instead of recording unavailable"
has_line "$lines" 'quota_end_status=unavailable' \
  || fail "failing closing reading was not recorded as unavailable: $lines"
has_line "$lines" 'quota_delta_status=unavailable' \
  || fail "failing closing reading did not mark the delta unavailable: $lines"
assert_contains "$(line_value "$lines" quota_end_reason)" 'quota-axi --json failed or exceeded its' \
  "failing closing reason was not recorded"
pass "a failing closing reading records unavailable and never fails the hook"

# --- meta writer -------------------------------------------------------------

write_start_meta "$META" window=fm:t1
fm_quota_accounting_meta_write "$META" <<'EOF' || fail "meta write failed"
quota_start_status=unavailable
quota_end_status=recorded
EOF
assert_equals 1 "$(grep -c '^quota_start_status=' "$META")" \
  "a replaced key did not stay single"
assert_grep 'quota_start_status=unavailable' "$META" "the replaced key lost its new value"
assert_grep 'quota_end_status=recorded' "$META" "a new key was not appended"
assert_grep 'window=fm:t1' "$META" "an untouched key was lost"
assert_grep 'quota_start_percent_remaining=87.5' "$META" "an untouched quota key was lost"
pass "the meta writer replaces named keys and preserves every other line"

write_start_meta "$META" window=fm:t1
before=$(cat "$META")
if printf 'not a key value line\n' | fm_quota_accounting_meta_write "$META"; then
  fail "a malformed payload line was accepted"
fi
assert_equals "$before" "$(cat "$META")" "a rejected payload still changed the record"
pass "the meta writer rejects a malformed payload without touching the record"

if printf 'quota_end_status=recorded\n' | fm_quota_accounting_meta_write "$TMP_ROOT/absent.meta"; then
  fail "a missing record was accepted"
fi
ln -s "$META" "$TMP_ROOT/link.meta"
if printf 'quota_end_status=recorded\n' | fm_quota_accounting_meta_write "$TMP_ROOT/link.meta"; then
  fail "a symlinked record was accepted"
fi
pass "the meta writer refuses a missing or symlinked record"

write_start_meta "$META" window=fm:t1
before=$(cat "$META")
printf '' | fm_quota_accounting_meta_write "$META" || fail "an empty payload failed"
assert_equals "$before" "$(cat "$META")" "an empty payload changed the record"
pass "an empty payload succeeds without touching the record"

# --- summary -----------------------------------------------------------------

write_start_meta "$META" \
  quota_delta_status=measured quota_delta_percent_points=45.25
summary=$(fm_quota_accounting_summary "$META")
assert_equals \
  'quota: 45.25 percentage points of the claude five_hour window drained while this task ran, shared with everything else running in it' \
  "$summary" "the measured summary changed shape"
pass "the measured summary names the unit, window, and the shared-window caveat"

write_start_meta "$META" quota_delta_status=window_reset
assert_equals 'quota: not attributable; the quota window reset while this task ran' \
  "$(fm_quota_accounting_summary "$META")" "the window_reset summary changed shape"
write_start_meta "$META" quota_delta_status=no_start
assert_equals 'quota: not attributable; no reading was recorded when this task was dispatched' \
  "$(fm_quota_accounting_summary "$META")" "the no_start summary changed shape"
write_start_meta "$META" quota_delta_status=unavailable \
  'quota_end_reason=quota-axi is not installed'
assert_equals 'quota: not attributable; quota-axi is not installed' \
  "$(fm_quota_accounting_summary "$META")" "the unavailable summary lost its reason"
fm_write_meta "$META" id=t1 harness=claude
assert_equals '' "$(fm_quota_accounting_summary "$META")" \
  "a record with no accounting still produced a summary"
pass "every unusable delta summarizes as not attributable, and no accounting means no summary"

# --- drain alert -------------------------------------------------------------

CONFIG_DIR="$TMP_ROOT/config"
mkdir -p "$CONFIG_DIR"

write_start_meta "$META" \
  quota_delta_status=measured quota_delta_percent_points=12.5
alert=$(fm_quota_accounting_alert "$META" fm:t1 "$CONFIG_DIR") \
  || fail "a drain above the default threshold did not alert"
assert_equals \
  'check: quota drain: task fm:t1 drained 12.5 percentage points of the claude five_hour quota window while it ran (alert threshold 10), shared with everything else running in that window' \
  "$alert" "the alert payload changed shape"
pass "a measured drain above the default threshold alerts with task, drain, unit, and caveat"

write_start_meta "$META" \
  quota_delta_status=measured quota_delta_percent_points=9.99
if fm_quota_accounting_alert "$META" fm:t1 "$CONFIG_DIR" >/dev/null; then
  fail "a drain below the default threshold alerted"
fi
write_start_meta "$META" \
  quota_delta_status=measured quota_delta_percent_points=10
if fm_quota_accounting_alert "$META" fm:t1 "$CONFIG_DIR" >/dev/null; then
  fail "a drain exactly at the threshold alerted"
fi
pass "a drain at or below the threshold stays quiet"

printf '  2.5  \n' > "$CONFIG_DIR/quota-drain-alert-threshold"
write_start_meta "$META" \
  quota_delta_status=measured quota_delta_percent_points=3
alert=$(fm_quota_accounting_alert "$META" fm:t1 "$CONFIG_DIR") \
  || fail "a drain above the configured threshold did not alert"
assert_contains "$alert" '(alert threshold 2.5)' "the configured threshold was not applied"
pass "the config file lowers the threshold"

printf 'not-a-number\n' > "$CONFIG_DIR/quota-drain-alert-threshold"
assert_equals 10 "$(fm_quota_accounting_alert_threshold "$CONFIG_DIR")" \
  "an unparseable threshold did not fall back to the default"
rm -f "$CONFIG_DIR/quota-drain-alert-threshold"
assert_equals 10 "$(fm_quota_accounting_alert_threshold "$CONFIG_DIR")" \
  "an absent threshold file did not fall back to the default"
pass "an unparseable or absent threshold file means the default"

for status in window_reset no_start unavailable; do
  write_start_meta "$META" "quota_delta_status=$status" quota_delta_percent_points=99
  if fm_quota_accounting_alert "$META" fm:t1 "$CONFIG_DIR" >/dev/null; then
    fail "a $status delta alerted"
  fi
done
pass "only a measured delta can alert"

printf '# all fm-quota-accounting-lib tests passed\n'
