#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

# The PR-opening event can arrive before no-mistakes appends its attestation.
# The workflow must re-read the current PR body rather than permanently judging
# that stale event payload.
test_required_workflow_reads_the_current_pr_body() {
  local workflow script metadata fakebin output attempts attested body stale_attempts
  workflow="$ROOT/.github/workflows/no-mistakes-required.yml"
  script="$TMP_ROOT/read-current-pr.sh"
  metadata="$TMP_ROOT/read-current-pr.json"
  fakebin="$TMP_ROOT/fakebin"
  output="$TMP_ROOT/current-pr.output"
  attempts="$TMP_ROOT/current-pr.attempts"
  mkdir -p "$fakebin"

  command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse the required-check workflow"
  ruby -ryaml -rjson - "$workflow" "$script" "$metadata" <<'RUBY' || fail "required-check workflow has no valid current-PR reader"
workflow = YAML.safe_load(File.read(ARGV[0]), aliases: true)
permissions = workflow.fetch("permissions")
steps = workflow.fetch("jobs").fetch("check").fetch("steps")
reader = steps.find { |step| step["id"] == "current-pr" } or raise "current-PR reader is missing"
verifier = steps.find { |step| step["uses"]&.include?("require-no-mistakes") } or raise "verifier step is missing"
raise "PR read permission is missing" unless permissions["pull-requests"] == "read"
raise "verifier does not use the current body" unless verifier.dig("with", "pr-body") == "${{ steps.current-pr.outputs.body }}"
File.write(ARGV[1], reader.fetch("run"))
File.write(ARGV[2], JSON.generate({ "body_binding" => verifier.dig("with", "pr-body") }))
RUBY

  attested="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  # shellcheck disable=SC2016 # The fake gh script must receive literal shell expansions.
  printf '%s\n' '#!/usr/bin/env bash' \
    'count=$(cat "$CURRENT_PR_ATTEMPTS" 2>/dev/null || printf 0)' \
    'printf "%s\\n" "$((count + 1))" > "$CURRENT_PR_ATTEMPTS"' \
    'if [ "$count" -lt "$STALE_ATTEMPTS" ]; then' \
    '  printf "%s\\n" "$UNATTESTED_BODY"' \
    'else' \
    '  printf "%s\\n" "$ATTESTED_BODY"' \
    'fi' > "$fakebin/gh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/sleep"
  chmod +x "$fakebin/gh" "$fakebin/sleep"
  body='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
  # Thirty stale reads consume the previous one-minute retry budget. The next
  # response proves the workflow keeps polling long enough for a normally
  # delayed pipeline attestation rather than failing its opening-event body.
  stale_attempts=30
  PATH="$fakebin:$PATH" GITHUB_REPOSITORY=kunchenguid/firstmate PR_NUMBER=3135 \
    PR_HEAD_SHA="$NEW_SHA" GITHUB_OUTPUT="$output" CURRENT_PR_ATTEMPTS="$attempts" STALE_ATTEMPTS="$stale_attempts" UNATTESTED_BODY="$body" \
    ATTESTED_BODY="$attested" bash "$script" \
    || fail "required-check current-PR reader did not poll successfully"
  assert_contains "$(cat "$output")" "no-mistakes-pipeline-attestation:v1" \
    "required-check current-PR reader retained the live attestation"
  [ "$(cat "$attempts")" -eq $((stale_attempts + 1)) ] \
    || fail "required-check current-PR reader did not outlast the former one-minute retry budget"
  assert_contains "$(cat "$metadata")" 'steps.current-pr.outputs.body' \
    "required-check verifier is not bound to the current PR body"
  pass "required-check workflow waits for and verifies the current PR body"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_required_workflow_reads_the_current_pr_body
