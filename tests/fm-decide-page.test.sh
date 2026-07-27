#!/usr/bin/env bash
# Tests for bin/fm-decide-page.sh and the decide watcher check.
#
# Coverage:
#   - Invalid input rejected (missing fields, bad key format, duplicate keys)
#   - Server: submission without secret rejected (403)
#   - Server: submission with unknown key rejected (400)
#   - Server: valid submission written as legible JSON records
#   - Check script: prints one line only when ready marker exists without processed
#   - Check script: silent when processed marker exists
#   - Check script: silent when no decide-* directories exist
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

DECIDE="$ROOT/bin/fm-decide-page.sh"

TMP_ROOT=$(fm_test_tmproot fm-decide-page)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

make_home() {
  local name=$1
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data"
  printf '%s\n' "$dir"
}

valid_json() {
  cat <<'JSON'
{
  "decisions": [
    {
      "key": "deploy-strategy",
      "title": "Deployment strategy",
      "context": "The billing service needs a deployment approach.",
      "options": [
        {"id": "blue-green", "label": "Blue-green", "description": "Zero-downtime"},
        {"id": "rolling",    "label": "Rolling",    "description": "Gradual"}
      ],
      "recommendation": "blue-green"
    },
    {
      "key": "db-migration-order",
      "title": "Migration order",
      "context": "Run schema migration before or after deploy?",
      "options": [
        {"id": "before", "label": "Before deploy"},
        {"id": "after",  "label": "After deploy"}
      ]
    }
  ]
}
JSON
}

# ---------------------------------------------------------------------------
# Input validation tests (no server started)
# ---------------------------------------------------------------------------

run_invalid() {
  local home=$1 json_content=$2 expect_fragment=$3 label=$4
  local json_file="$home/input.json"
  printf '%s\n' "$json_content" > "$json_file"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        "$DECIDE" "$json_file" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: expected non-zero exit, got 0"
  assert_contains "$out" "$expect_fragment" "$label: expected '$expect_fragment' in output"
  pass "$label"
}

H=$(make_home invalid-tests)

run_invalid "$H" 'not json at all' "invalid JSON" "rejects non-JSON input"
run_invalid "$H" '{}' "decisions must be a non-empty array" "rejects missing decisions"
run_invalid "$H" '{"decisions":[]}' "decisions must be a non-empty array" "rejects empty decisions array"
run_invalid "$H" '{"decisions":[{"key":"","title":"T","context":"C","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}]}' \
  "key must be a non-empty slug" "rejects empty key"
run_invalid "$H" '{"decisions":[{"key":"bad key!","title":"T","context":"C","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}]}' \
  "key must be a non-empty slug" "rejects key with spaces"
run_invalid "$H" '{"decisions":[{"key":"ok","title":"","context":"C","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}]}' \
  "title must be a non-empty string" "rejects empty title"
run_invalid "$H" '{"decisions":[{"key":"ok","title":"T","context":"","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}]}' \
  "context must be a non-empty string" "rejects empty context"
run_invalid "$H" '{"decisions":[{"key":"ok","title":"T","context":"C","options":[{"id":"a","label":"A"}]}]}' \
  "options must be an array of at least 2 items" "rejects single option"
run_invalid "$H" '{"decisions":[{"key":"dup","title":"T","context":"C","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}]},{"key":"dup","title":"T2","context":"C2","options":[{"id":"x","label":"X"},{"id":"y","label":"Y"}]}]}' \
  "duplicate key" "rejects duplicate decision keys"
run_invalid "$H" '{"decisions":[{"key":"ok","title":"T","context":"C","options":[{"id":"a","label":"A"},{"id":"a","label":"A2"}]}]}' \
  "duplicate option id" "rejects duplicate option ids"
run_invalid "$H" '{"decisions":[{"key":"ok","title":"T","context":"C","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"recommendation":"nonexistent"}]}' \
  "recommendation must be a valid option id" "rejects invalid recommendation"

# ---------------------------------------------------------------------------
# Check script tests (no server needed)
# ---------------------------------------------------------------------------

H_CHK=$(make_home check-tests)

# Write the check script by invoking fm-decide-page.sh with a valid JSON.
# We use --timeout 1 so the server exits quickly; we don't need it for check tests.
VALID_FILE="$H_CHK/valid.json"
valid_json > "$VALID_FILE"
FM_HOME="$H_CHK" FM_STATE_OVERRIDE="$H_CHK/state" "$DECIDE" --timeout 1 "$VALID_FILE" >/dev/null 2>&1 &
BGPID=$!
# Wait for check.sh to appear (server may still be starting; we only need the check file)
TRIES=0
while [ ! -f "$H_CHK/state/decide.check.sh" ] && [ "$TRIES" -lt 50 ]; do
  sleep 0.1
  TRIES=$((TRIES + 1))
done
wait "$BGPID" 2>/dev/null || true

CHECK_SH="$H_CHK/state/decide.check.sh"
assert_present "$CHECK_SH" "check script was created"

MODE=$(file_mode "$CHECK_SH")
[ "$MODE" = "700" ] || fail "check script must have mode 700, got $MODE"
pass "check script has mode 700"

# check: silent when no decide-* directories at all
out=$(FM_HOME="$H_CHK" "$CHECK_SH")
[ -z "$out" ] || fail "check must be silent with no decide-* dirs, got: $out"
pass "check is silent with no decide-* dirs"

# check: silent when ready marker is absent
mkdir -p "$H_CHK/state/decide-fixture-01"
out=$(FM_HOME="$H_CHK" "$CHECK_SH")
[ -z "$out" ] || fail "check must be silent without ready marker, got: $out"
pass "check is silent without ready marker"

# check: prints one line when ready marker exists
touch "$H_CHK/state/decide-fixture-01/ready"
out=$(FM_HOME="$H_CHK" "$CHECK_SH")
[ -n "$out" ] || fail "check must print a line when ready marker exists"
assert_contains "$out" "responses-ready:" "check output contains responses-ready"
assert_contains "$out" "decide-fixture-01" "check output contains run ID"
LINECOUNT=$(printf '%s' "$out" | wc -l)
[ "$LINECOUNT" -le 1 ] || fail "check must print at most one line, got $LINECOUNT"
pass "check prints one line when ready marker exists"

# check: silent when processed marker exists
touch "$H_CHK/state/decide-fixture-01/processed"
out=$(FM_HOME="$H_CHK" "$CHECK_SH")
[ -z "$out" ] || fail "check must be silent when processed, got: $out"
pass "check is silent when processed marker exists"

# check: first unprocessed run wins when multiple exist
mkdir -p "$H_CHK/state/decide-fixture-02"
touch "$H_CHK/state/decide-fixture-02/ready"
out=$(FM_HOME="$H_CHK" "$CHECK_SH")
[ -n "$out" ] || fail "check must print when a second unprocessed run exists"
assert_contains "$out" "decide-fixture-02" "check surfaces the unprocessed run"
LINECOUNT=$(printf '%s' "$out" | wc -l)
[ "$LINECOUNT" -le 1 ] || fail "check must print at most one line with multiple runs, got $LINECOUNT"
pass "check surfaces second run when first is processed"

# ---------------------------------------------------------------------------
# Server integration tests (requires a live server)
# ---------------------------------------------------------------------------

H_SRV=$(make_home server-tests)
VALID_FILE2="$H_SRV/valid.json"
valid_json > "$VALID_FILE2"

SRV_OUT=$(FM_HOME="$H_SRV" FM_STATE_OVERRIDE="$H_SRV/state" \
  "$DECIDE" --timeout 30 "$VALID_FILE2" 2>&1)
assert_contains "$SRV_OUT" "http://127.0.0.1:" "script outputs a URL"
pass "script outputs http URL"

# Extract port from output.
PORT=$(printf '%s' "$SRV_OUT" | grep -o 'http://127.0.0.1:[0-9]*' | grep -o '[0-9]*$')
[ -n "$PORT" ] || fail "could not parse port from output"

BASE="http://127.0.0.1:$PORT"
sleep 0.5  # brief pause for server warm-up

# GET / returns 200.
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/")
[ "$HTTP_CODE" = "200" ] || fail "GET / expected 200, got $HTTP_CODE"
pass "GET / returns 200"

# GET /other returns 404.
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/other")
[ "$HTTP_CODE" = "404" ] || fail "GET /other expected 404, got $HTTP_CODE"
pass "GET /other returns 404"

# POST /submit without secret returns 403.
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE/submit" \
  -H "Content-Type: application/json" \
  -d '{"secret":"wrong","choices":{}}')
[ "$HTTP_CODE" = "403" ] || fail "wrong secret: expected 403, got $HTTP_CODE"
pass "submission with wrong secret returns 403"

# POST /submit with unknown key returns 400.
# We need the real secret - it is embedded in the page.
PAGE_HTML=$(curl -s "$BASE/")
SECRET_VAL=$(printf '%s' "$PAGE_HTML" | grep -o 'name="__secret" value="[^"]*"' | sed 's/.*value="//;s/"//')
[ -n "$SECRET_VAL" ] || fail "could not extract secret from page"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE/submit" \
  -H "Content-Type: application/json" \
  -d "{\"secret\":\"$SECRET_VAL\",\"choices\":{\"unknown-key\":{\"choice\":\"x\",\"note\":\"\"}}}")
[ "$HTTP_CODE" = "400" ] || fail "unknown key: expected 400, got $HTTP_CODE"
pass "submission with unknown decision key returns 400"

# POST /submit with valid choices succeeds.
SUBMIT_BODY=$(cat <<JSON
{
  "secret": "$SECRET_VAL",
  "choices": {
    "deploy-strategy":    {"choice": "blue-green", "note": "Sounds good"},
    "db-migration-order": {"choice": "before",     "note": ""}
  }
}
JSON
)
SUBMIT_RESP=$(curl -s -w '\n%{http_code}' \
  -X POST "$BASE/submit" \
  -H "Content-Type: application/json" \
  -d "$SUBMIT_BODY")
HTTP_CODE=$(printf '%s' "$SUBMIT_RESP" | tail -1)
RESP_BODY=$(printf '%s' "$SUBMIT_RESP" | head -1)
[ "$HTTP_CODE" = "200" ] || fail "valid submission: expected 200, got $HTTP_CODE (body: $RESP_BODY)"
pass "valid submission returns 200"

# Extract run_id from response body.
RUN_ID=$(printf '%s' "$RESP_BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['run_id'])")
[ -n "$RUN_ID" ] || fail "response body missing run_id"

# Wait briefly for server to write responses.
sleep 0.5

# Response files must exist and be valid JSON with the correct fields.
RESP_DIR="$H_SRV/state/$RUN_ID/responses"
assert_present "$RESP_DIR/deploy-strategy.json" "deploy-strategy response written"
assert_present "$RESP_DIR/db-migration-order.json" "db-migration-order response written"
pass "response files created"

python3 - "$RESP_DIR/deploy-strategy.json" <<'PYCHECK'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["key"]    == "deploy-strategy",  f"bad key: {d['key']}"
assert d["choice"] == "blue-green",       f"bad choice: {d['choice']}"
assert d["note"]   == "Sounds good",      f"bad note: {d['note']}"
assert "timestamp" in d,                  "missing timestamp"
assert "run_id"    in d,                  "missing run_id"
PYCHECK
pass "deploy-strategy response has correct fields"

python3 - "$RESP_DIR/db-migration-order.json" <<'PYCHECK'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["key"]    == "db-migration-order", f"bad key: {d['key']}"
assert d["choice"] == "before",             f"bad choice: {d['choice']}"
PYCHECK
pass "db-migration-order response has correct fields"

# Ready marker must exist.
assert_present "$H_SRV/state/$RUN_ID/ready" "ready marker written after submission"
pass "ready marker exists after submission"

# Check script must now surface this run.
CHECK_SH2="$H_SRV/state/decide.check.sh"
out=$(FM_HOME="$H_SRV" "$CHECK_SH2")
assert_contains "$out" "responses-ready:" "check surfaces submitted run"
assert_contains "$out" "$RUN_ID" "check output contains run ID"
pass "check surfaces submitted run"

# After writing processed marker, check must be silent.
touch "$H_SRV/state/$RUN_ID/processed"
out=$(FM_HOME="$H_SRV" "$CHECK_SH2")
[ -z "$out" ] || fail "check must be silent after processed marker, got: $out"
pass "check is silent after processed marker"

printf 'ok - all tests passed\n'
