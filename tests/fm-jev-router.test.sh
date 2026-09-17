#!/usr/bin/env bash
# Behavior tests for fm-jev-router.sh - Jev-powered intake routing.
#
# The router sends one request plus six typed routing questions to the TypeSafe
# System One API and applies confidence-gated routing: confident requests route
# (exit 0), low-confidence or safety-flagged requests escalate (exit 2), and a
# missing key, missing input, transport error, or malformed response is an error
# (exit 1). These tests exercise that contract through the script's public
# interface with a mocked transport - no live API dependency - and pin the
# fail-closed and never-print-the-key guarantees.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-jev-router-tests)
SCRIPT="$ROOT/bin/fm-jev-router.sh"

# A key value the router must never print, leak into a child argv, or write.
SECRET='FM_JEV_TEST_SUPER_SECRET'

# --- fake transport ---------------------------------------------------------
#
# curl is mocked: it records every invocation's argv, writes the canned response
# body to the -o target, and prints the canned HTTP code (or exits with
# MOCK_CURL_EXIT). No network is ever reached.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
if [ -n "${MOCK_CURL_EXIT:-}" ]; then
  exit "$MOCK_CURL_EXIT"
fi
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat "$MOCK_RESP" > "$out"
printf '%s' "${MOCK_HTTP:-200}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# make_response <file> <project-choice> <project-conf> <worker-conf> [<dest-noul> [<irrev-noul> [<sec-noul>]]]
# Emits the answer shape the router consumes. Only the fields that drive routing
# vary; the rest are fixed so a case can change one lever in isolation. The three
# safety Nouls default to 0 (no flag).
make_response() {
  local file=$1 pc=$2 pconf=$3 wconf=$4 dest=${5:-0} irrev=${6:-0} sec=${7:-0}
  cat > "$file" <<EOF
{"model":"jev-latest","answers":{"project":{"choice":"$pc","confidence":$pconf},"deliverable":{"choice":"ship"},"effort_class":{"choice":"medium"},"secondmate_scope":{"choice":"main","confidence":$wconf},"surface":{"choice":"internal"},"safety_destructive":{"noul":$dest},"safety_irreversible":{"noul":$irrev},"safety_security":{"noul":$sec}}}
EOF
}

RUN_RC=0
RUN_LINE=
CURL_LOG=
# run_router <case> <response-file> [-- [env pairs...]]
# Runs the script against a fresh isolated home and fake transport, capturing
# merged stdout/stderr and the exit code.
run_router() {
  local case_name=$1 resp=$2
  shift 2
  local case_dir fakebin out rc=0 arg
  local -a script_args=() env_pairs=()
  case_dir="$TMP_ROOT/$case_name"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  CURL_LOG="$case_dir/curl.log"
  : > "$CURL_LOG"
  local seen_separator=0
  for arg in "$@"; do
    if [ "$seen_separator" -eq 0 ] && [ "$arg" = -- ]; then
      seen_separator=1
      continue
    fi
    if [ "$seen_separator" -eq 0 ]; then
      script_args+=("$arg")
    else
      env_pairs+=("$arg")
    fi
  done
  out=$(env "PATH=$fakebin:$BASE_PATH" \
    "FM_HOME=$case_dir" \
    "MOCK_CURL_LOG=$CURL_LOG" \
    "MOCK_RESP=$resp" \
    "${env_pairs[@]+"${env_pairs[@]}"}" \
    "$SCRIPT" "${script_args[@]+"${script_args[@]}"}" \
    </dev/null 2>&1) || rc=$?
  RUN_RC=$rc
  RUN_LINE=$out
}

assert_no_network() {  # <label>
  [ ! -s "$CURL_LOG" ] \
    || fail "$1: the router must make no network call, but curl ran: $(tr '\n' '|' < "$CURL_LOG")"
}

# --- confidence bands -------------------------------------------------------

test_high_confidence_routes() {
  local resp
  resp="$TMP_ROOT/high.json"
  make_response "$resp" callfinix 0.95 0.9 0.0
  run_router high "$resp" --state "add a pricing page" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 0 "$RUN_RC" "high confidence must route"
  assert_contains "$RUN_LINE" "DECISION: ROUTE - " "high confidence must route cleanly"
  assert_not_contains "$RUN_LINE" "FLAG FOR REVIEW" "high confidence must not flag for review"
  assert_not_contains "$RUN_LINE" "ESCALATE" "high confidence must not escalate"
  pass "high confidence routes with exit 0 and no flag"
}

test_medium_confidence_routes_but_flags() {
  local resp
  resp="$TMP_ROOT/medium.json"
  make_response "$resp" callfinix 0.5 0.9 0.0
  run_router medium "$resp" --state "add a pricing page" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 0 "$RUN_RC" "medium confidence must still route"
  assert_contains "$RUN_LINE" "FLAG FOR REVIEW" "medium confidence must flag for review"
  pass "medium confidence routes with exit 0 but flags for review"
}

test_low_confidence_escalates() {
  local resp
  resp="$TMP_ROOT/low.json"
  make_response "$resp" callfinix 0.1 0.9 0.0
  run_router low "$resp" --state "add a pricing page" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 2 "$RUN_RC" "low project confidence must escalate"
  assert_contains "$RUN_LINE" "ESCALATE" "low confidence must escalate"
  assert_contains "$RUN_LINE" "low confidence on project" "the escalation reason must name the project"
  pass "low project confidence escalates with exit 2"
}

test_low_worker_confidence_escalates() {
  local resp
  resp="$TMP_ROOT/worker-low.json"
  make_response "$resp" callfinix 0.95 0.1 0.0
  run_router worker-low "$resp" --state "add a pricing page" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 2 "$RUN_RC" "low worker confidence must escalate"
  assert_contains "$RUN_LINE" "low confidence on worker routing" "the escalation reason must name the worker"
  pass "low worker confidence escalates with exit 2"
}

# --- escalation gates -------------------------------------------------------

test_safety_flag_escalates() {
  local resp
  # Any one atomic safety judgment at or above the flag escalates, even when
  # routing is otherwise confident.
  resp="$TMP_ROOT/safety-destructive.json"
  make_response "$resp" callfinix 0.95 0.9 0.9 0.0 0.0
  run_router safety-destructive "$resp" --state "rotate the credentials" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 2 "$RUN_RC" "a high destructive flag must escalate"
  assert_contains "$RUN_LINE" "safety flag is high" "the escalation reason must name the safety flag"
  assert_contains "$RUN_LINE" "destructive" "the escalation reason must name the destructive flag"

  resp="$TMP_ROOT/safety-irreversible.json"
  make_response "$resp" callfinix 0.95 0.9 0.0 0.9 0.0
  run_router safety-irreversible "$resp" --state "rotate the credentials" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 2 "$RUN_RC" "a high irreversible flag must escalate"
  assert_contains "$RUN_LINE" "irreversible" "the escalation reason must name the irreversible flag"

  resp="$TMP_ROOT/safety-security.json"
  make_response "$resp" callfinix 0.95 0.9 0.0 0.0 0.9
  run_router safety-security "$resp" --state "rotate the credentials" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 2 "$RUN_RC" "a high security flag must escalate"
  assert_contains "$RUN_LINE" "security-sensitive" "the escalation reason must name the security flag"
  pass "any single high safety flag escalates with exit 2"
}

test_unknown_project_escalates() {
  local resp
  resp="$TMP_ROOT/other.json"
  make_response "$resp" other 0.9 0.9 0.0
  run_router other "$resp" --state "add a pricing page" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 2 "$RUN_RC" "an unknown project must escalate"
  assert_contains "$RUN_LINE" "no known project matched" "the escalation reason must name the unknown project"
  pass "an unknown project escalates with exit 2"
}

# --- error paths (exit 1) ---------------------------------------------------

test_missing_key_fails_closed() {
  local resp
  resp="$TMP_ROOT/missing-key.json"
  make_response "$resp" callfinix 0.95 0.9 0.0
  run_router missing-key "$resp" --state "add a pricing page"
  expect_code 1 "$RUN_RC" "a missing key must be an error, not a route"
  assert_contains "$RUN_LINE" "TYPESAFE_API_KEY not set" "the error must name the missing key"
  assert_no_network "missing-key"
  pass "a missing key fails closed with exit 1 and no network call"
}

test_missing_input_is_an_error() {
  local resp
  resp="$TMP_ROOT/no-input.json"
  make_response "$resp" callfinix 0.95 0.9 0.0
  run_router no-input "$resp" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 1 "$RUN_RC" "missing request text must be an error"
  assert_contains "$RUN_LINE" "no request text provided" "the error must name the missing input"
  assert_no_network "no-input"
  pass "missing request text is an error with exit 1 and no network call"
}

test_transport_error_is_an_error() {
  local resp
  resp="$TMP_ROOT/transport.json"
  make_response "$resp" callfinix 0.95 0.9 0.0
  run_router transport "$resp" --state "add a pricing page" \
    -- "TYPESAFE_API_KEY=$SECRET" "MOCK_CURL_EXIT=7"
  expect_code 1 "$RUN_RC" "a transport failure must be an error"
  assert_contains "$RUN_LINE" "API call failed" "the error must name the failed call"
  pass "a transport failure is an error with exit 1"
}

test_non_200_http_is_an_error() {
  local resp
  resp="$TMP_ROOT/http500.json"
  make_response "$resp" callfinix 0.95 0.9 0.0
  run_router http500 "$resp" --state "add a pricing page" \
    -- "TYPESAFE_API_KEY=$SECRET" "MOCK_HTTP=500"
  expect_code 1 "$RUN_RC" "a non-200 response must be an error"
  assert_contains "$RUN_LINE" "API call failed" "the error must name the failed call"
  pass "a non-200 response is an error with exit 1"
}

test_malformed_response_is_an_error() {
  local resp
  resp="$TMP_ROOT/malformed.json"
  printf '%s\n' 'this is not json' > "$resp"
  run_router malformed "$resp" --state "add a pricing page" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 1 "$RUN_RC" "a malformed response must be an error"
  assert_contains "$RUN_LINE" "not a well-formed routing answer" "the error must name the malformed response"
  pass "a malformed response is an error with exit 1"
}

# --- secrecy and interface --------------------------------------------------

test_never_prints_the_api_key() {
  local resp
  resp="$TMP_ROOT/secret.json"
  make_response "$resp" callfinix 0.95 0.9 0.0
  run_router secret "$resp" --state "add a pricing page" -- "TYPESAFE_API_KEY=$SECRET"
  expect_code 0 "$RUN_RC" "the keyed call must still route"
  assert_not_contains "$RUN_LINE" "$SECRET" "the key must never appear in script output"
  assert_not_contains "$(cat "$CURL_LOG")" "$SECRET" "the key must never appear in curl argv"
  pass "the API key never appears in script output or in curl argv"
}

test_help_succeeds() {
  local rc=0
  "$SCRIPT" --help >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "--help must succeed"
  pass "--help succeeds with exit 0"
}

test_dry_run_previews_without_a_key() {
  local resp rc=0
  resp="$TMP_ROOT/dry.json"
  make_response "$resp" callfinix 0.95 0.9 0.0
  RUN_LINE=$("$SCRIPT" --dry-run --state "add a pricing page" </dev/null 2>&1) || rc=$?
  expect_code 0 "$rc" "--dry-run must succeed without a key"
  assert_contains "$RUN_LINE" "DRY RUN" "--dry-run must mark itself as a preview"
  assert_not_contains "$RUN_LINE" "$SECRET" "--dry-run must never contain the key"
  pass "--dry-run previews the request with exit 0 and no key"
}

test_high_confidence_routes
test_medium_confidence_routes_but_flags
test_low_confidence_escalates
test_low_worker_confidence_escalates
test_safety_flag_escalates
test_unknown_project_escalates
test_missing_key_fails_closed
test_missing_input_is_an_error
test_transport_error_is_an_error
test_non_200_http_is_an_error
test_malformed_response_is_an_error
test_never_prints_the_api_key
test_help_succeeds
test_dry_run_previews_without_a_key
