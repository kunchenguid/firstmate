#!/usr/bin/env bash
# Behavior tests for disabled Cognee session-cost probe planning.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-cognee-session-cost-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-cognee-session-cost-probe)

json_lines_count() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path
print(sum(1 for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()))
PY
}

test_missing_required_args_fail_closed() {
  local dir out code
  dir="$TMP_ROOT/missing"
  mkdir -p "$dir"

  set +e
  out=$("$PROBE" --telemetry "$dir/telemetry.jsonl" --window-start-utc 2026-06-30T00:00:00Z 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "missing required args should fail closed"
  assert_contains "$out" "reason=missing_required_args" "failure reason is explicit"
  assert_contains "$out" "external_action_authorized=false" "failed probe cannot authorize action"
  pass "missing required args fail closed"
}

test_allowed_get_endpoint_templates_are_planned() {
  local dir telemetry output out code
  dir="$TMP_ROOT/allowed"
  mkdir -p "$dir"
  telemetry="$dir/telemetry.jsonl"
  output="$dir/probe.jsonl"
  cat > "$telemetry" <<'JSONL'
{"schema_version":"cognee_telemetry.v2","event_type":"api_attempt","ts_utc":"2026-06-30T01:00:00Z","run_id":"run-one","request_id":"req-one","logical_search_id":"logical-one","operation":{"endpoint_template":"/api/v1/search","http_method":"POST"},"privacy":{"answer_body_logged":false}}
JSONL

  set +e
  out=$("$PROBE" --telemetry "$telemetry" --window-start-utc 2026-06-30T00:00:00Z \
    --window-end-utc 2026-06-30T02:00:00Z --output-jsonl "$output" \
    --endpoint "GET /health" \
    --endpoint "GET /openapi.json" \
    --endpoint "GET /api/v1/sessions" \
    --endpoint "GET /api/v1/sessions/{session_id}" \
    --endpoint "GET /api/v1/sessions/cost-by-model" 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" "allowed GET endpoint templates should be accepted"
  assert_contains "$out" "status=prepared" "helper should only prepare probes"
  assert_present "$output" "probe output should be written"
  [ "$(json_lines_count "$output")" = "5" ] || fail "expected one event per allowed endpoint"
  python3 - "$output" <<'PY' || fail "allowed endpoint JSON assertions failed"
import json
import sys
from pathlib import Path

events = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
expected = {
    "/health",
    "/openapi.json",
    "/api/v1/sessions",
    "/api/v1/sessions/{session_id}",
    "/api/v1/sessions/cost-by-model",
}
if {event["probe"]["endpoint_template"] for event in events} != expected:
    raise SystemExit("unexpected endpoint set")
for event in events:
    if event["probe"]["http_method"] != "GET":
        raise SystemExit("non-GET method emitted")
    if event["probe"]["mutates_remote"] is not False:
        raise SystemExit("probe marked as mutating")
    if event["external_action_authorized"] is not False:
        raise SystemExit("external action was authorized")
    if event["decision"]["cost_correlation_status"] != "unmatched":
        raise SystemExit("disabled planner should not claim correlation")
PY
  pass "allowed GET endpoint templates are planned"
}

test_mutation_and_search_endpoint_templates_are_rejected() {
  local dir telemetry output out code
  dir="$TMP_ROOT/reject"
  mkdir -p "$dir"
  telemetry="$dir/telemetry.jsonl"
  output="$dir/probe.jsonl"
  : > "$telemetry"

  set +e
  out=$("$PROBE" --telemetry "$telemetry" --window-start-utc 2026-06-30T00:00:00Z \
    --window-end-utc 2026-06-30T01:00:00Z --output-jsonl "$output" \
    --endpoint "POST /api/v1/search" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "POST search should be rejected"
  assert_contains "$out" "reason=blocked_endpoint_template" "unsafe endpoint reason is explicit"
  assert_contains "$out" "external_action_authorized=false" "unsafe endpoint cannot authorize action"
  assert_absent "$output" "unsafe endpoint should not write output"

  set +e
  out=$("$PROBE" --telemetry "$telemetry" --window-start-utc 2026-06-30T00:00:00Z \
    --window-end-utc 2026-06-30T01:00:00Z --output-jsonl "$output" \
    --endpoint "GET /api/v1/search" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "GET search should still be rejected"
  assert_contains "$out" "reason=blocked_endpoint_template" "search endpoint is blocked by template"
  assert_absent "$output" "search endpoint should not write output"
  pass "mutation and search endpoint templates are rejected"
}

test_env_file_values_load_safely_without_source_or_eval() {
  local dir telemetry output envfile marker out code secret
  dir="$TMP_ROOT/envfile"
  mkdir -p "$dir"
  telemetry="$dir/telemetry.jsonl"
  output="$dir/probe.jsonl"
  envfile="$dir/cognee.env"
  marker="$dir/should-not-exist"
  # shellcheck disable=SC2016 # Command substitution text must stay literal for env-loader safety coverage.
  secret='safe value with spaces $(touch '"$marker"')'
  : > "$telemetry"
  {
    printf 'COGNEE_BASE_URL=%s\n' 'https://env-file.invalid'
    printf 'COGNEE_API_KEY=%s\n' "$secret"
    # shellcheck disable=SC2016 # Command substitution text must stay literal for env-loader safety coverage.
    printf 'UNSAFE_UNKNOWN=%s\n' '$(touch '"$marker"')'
  } > "$envfile"

  set +e
  out=$(env -u COGNEE_BASE_URL -u COGNEE_API_KEY "$PROBE" --telemetry "$telemetry" \
    --window-start-utc 2026-06-30T00:00:00Z --window-end-utc 2026-06-30T01:00:00Z \
    --output-jsonl "$output" --env-file "$envfile" --endpoint "GET /health" 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" "env-file loading should be safe and sufficient"
  assert_contains "$out" "env_file_loaded=true" "helper should report env-file load by fact only"
  assert_not_contains "$out" "$secret" "output must not print env-file values"
  assert_present "$output" "probe output should be written"
  assert_not_contains "$(cat "$output")" "$secret" "probe telemetry must not store env-file values"
  assert_absent "$marker" "dotenv values and unknown names must not execute"
  pass "env-file values load safely"
}

test_session_ids_are_hashed_and_bodies_and_secrets_are_not_logged() {
  local dir telemetry output out code raw_session secret
  dir="$TMP_ROOT/privacy"
  mkdir -p "$dir"
  telemetry="$dir/telemetry.jsonl"
  output="$dir/probe.jsonl"
  raw_session="session-raw-should-not-log"
  secret="SECRET_VALUE_SHOULD_NOT_LOG"
  cat > "$telemetry" <<JSONL
{"schema_version":"cognee_telemetry.v2","event_type":"api_attempt","ts_utc":"2026-06-30T00:15:00Z","run_id":"run-secret","request_id":"req-secret","logical_search_id":"logical-secret","session_id":"$raw_session","answer":"ANSWER_BODY_DO_NOT_LOG","prompt":"PROMPT_BODY_DO_NOT_LOG","source_body":"SOURCE_BODY_DO_NOT_LOG","api_key":"$secret","headers":{"authorization":"Bearer $secret"},"operation":{"endpoint_template":"/api/v1/search","http_method":"POST"}}
JSONL

  set +e
  out=$("$PROBE" --telemetry "$telemetry" --window-start-utc 2026-06-30T00:00:00Z \
    --window-end-utc 2026-06-30T01:00:00Z --output-jsonl "$output" --endpoint "GET /api/v1/sessions/{session_id}" 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" "privacy fixture should be prepared"
  assert_not_contains "$out" "$raw_session" "raw session id must not print"
  assert_not_contains "$out" "$secret" "secret value must not print"
  assert_present "$output" "probe output should be written"
  assert_not_contains "$(cat "$output")" "$raw_session" "raw session id must not be written"
  assert_contains "$(cat "$output")" "sha256:" "hashed session id should be written"
  assert_not_contains "$(cat "$output")" "ANSWER_BODY_DO_NOT_LOG" "answer bodies must not be logged"
  assert_not_contains "$(cat "$output")" "PROMPT_BODY_DO_NOT_LOG" "prompt bodies must not be logged"
  assert_not_contains "$(cat "$output")" "SOURCE_BODY_DO_NOT_LOG" "source bodies must not be logged"
  assert_not_contains "$(cat "$output")" "$secret" "secret-like values must not be logged"
  python3 - "$output" <<'PY' || fail "privacy fields were not normalized"
import json
import sys
from pathlib import Path

event = json.loads(Path(sys.argv[1]).read_text().splitlines()[0])
if event["privacy"]["session_id_hashed"] is not True:
    raise SystemExit("session_id_hashed should be true")
if event["privacy"]["answer_body_logged"] is not False:
    raise SystemExit("answer_body_logged should be false")
if event["privacy"]["prompt_logged"] is not False:
    raise SystemExit("prompt_logged should be false")
if event["privacy"]["source_body_logged"] is not False:
    raise SystemExit("source_body_logged should be false")
if event["privacy"]["auth_headers_logged"] is not False:
    raise SystemExit("auth_headers_logged should be false")
if not event["vendor_usage"]["session_id_hash"].startswith("sha256:"):
    raise SystemExit("session id hash missing")
PY
  pass "session ids are hashed and bodies and secrets are not logged"
}

test_no_live_network_is_used() {
  local dir telemetry output fakebin out code
  dir="$TMP_ROOT/no-network"
  mkdir -p "$dir"
  telemetry="$dir/telemetry.jsonl"
  output="$dir/probe.jsonl"
  fakebin=$(fm_fakebin "$dir")
  : > "$telemetry"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl should not run" >&2
exit 99
SH
  chmod +x "$fakebin/curl"

  set +e
  out=$(PATH="$fakebin:$PATH" "$PROBE" --telemetry "$telemetry" \
    --window-start-utc 2026-06-30T00:00:00Z --window-end-utc 2026-06-30T01:00:00Z \
    --output-jsonl "$output" --endpoint "GET /health" 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" "disabled helper should not call curl"
  assert_not_contains "$out" "curl should not run" "curl stub must not be invoked"
  assert_present "$output" "probe output should still be written"
  pass "no live network is used by the disabled probe helper"
}

test_missing_required_args_fail_closed
test_allowed_get_endpoint_templates_are_planned
test_mutation_and_search_endpoint_templates_are_rejected
test_env_file_values_load_safely_without_source_or_eval
test_session_ids_are_hashed_and_bodies_and_secrets_are_not_logged
test_no_live_network_is_used
