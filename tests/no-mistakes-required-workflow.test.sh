#!/usr/bin/env bash
# Behavior of the "PR must be raised via no-mistakes" compliance gate.
#
# The contract under test is the executable step body of
# .github/workflows/no-mistakes-required.yml: given a pull_request event payload
# body (PR_BODY) and the PR's live body, it must decide whether the PR carries
# the no-mistakes signature plus a parseable v1 pipeline attestation whose
# review/test/document steps are completed.
#
# The workflow is parsed into its YAML object and the real step script is run as
# the runner runs it, with gh/sleep shimmed; no assertion looks at the workflow
# text itself.
#
# Regression origin: PR #2827. no-mistakes pushes the branch (and opens the PR)
# before it writes the pipeline body, so the opened/synchronize payload carried a
# pre-attestation body and this gate failed against a body that was already
# replaced seconds later. Runs 32619561064 (opened) and 32622077051 (synchronize)
# both failed that way while the following `edited` run passed on the same head.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the gate parses attestation with jq)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (needed to parse the workflow YAML)"; exit 0; }
python3 -c 'import yaml' >/dev/null 2>&1 || { echo "skip: python3 yaml module not found (needed to parse the workflow YAML)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot no-mistakes-required)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
STEP="$TMP_ROOT/step.sh"

# Extract the step's `run:` script from the parsed workflow, keeping the job's
# `if` guard and expression-bearing `env:` out of it: those are GitHub's to
# evaluate, the script body is the runner's.
python3 - "$WORKFLOW" "$STEP" <<'PY' || fail "could not extract the compliance step from the workflow"
import sys

import yaml

workflow = yaml.safe_load(open(sys.argv[1]))
steps = workflow["jobs"]["check"]["steps"]
run = [s for s in steps if "run" in s and "no-mistakes signature" in s.get("name", "")]
assert len(run) == 1, run
open(sys.argv[2], "w").write(run[0]["run"])
PY

# The live body the shimmed `gh api` answers with, and a counter proving whether
# the gate went back to the API at all.
LIVE_BODY="$TMP_ROOT/live-body.txt"
GH_CALLS="$TMP_ROOT/gh-calls"
: > "$GH_CALLS"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
if [ -n "${FAKE_GH_FAIL:-}" ]; then
  echo "gh: simulated API failure" >&2
  exit 1
fi
cat "$LIVE_BODY"
SH
chmod +x "$FAKEBIN/gh"

# Keep the retry loop's backoff out of the suite's wall clock.
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/sleep"

MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

# body_with <review-status> <test-status> <document-status>
body_with() {
  printf '## Pipeline\n\n%s\n\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"deadbeef","steps":[{"step":"review","status":"%s"},{"step":"test","status":"%s"},{"step":"document","status":"%s"}]} -->\n' \
    "$MARKER" "$1" "$2" "$3"
}

COMPLIANT=$(body_with completed completed completed)
SIGNED_NO_ATTESTATION="## Pipeline

$MARKER
"

# run_gate <event-body> <live-body>: run the step in the current shell, leaving
# its combined output in OUT and its exit code in RC.
OUT=''
RC=0
run_gate() {
  printf '%s' "$2" > "$LIVE_BODY"
  : > "$GH_CALLS"
  PATH="$FAKEBIN:$PATH" \
    LIVE_BODY="$LIVE_BODY" GH_CALLS="$GH_CALLS" FAKE_GH_FAIL="${FAKE_GH_FAIL:-}" \
    PR_BODY="$1" PR_AUTHOR=someone PR_NUMBER=2827 PR_REPO=kunchenguid/firstmate \
    bash "$STEP" >"$TMP_ROOT/out.txt" 2>&1
  RC=$?
  OUT=$(cat "$TMP_ROOT/out.txt")
}

gh_call_count() {
  local count
  count=$(grep -c . "$GH_CALLS" 2>/dev/null) || count=0
  printf '%s\n' "$count"
}

# --- a compliant event payload passes without going back to the API ---------

run_gate "$COMPLIANT" "$COMPLIANT"
expect_code 0 "$RC" "compliant payload body"
assert_contains "$OUT" "Pipeline step attestation is valid" "compliant payload body reports success"
[ "$(gh_call_count)" = 0 ] || fail "a compliant payload body must not re-read the live body"
pass "a compliant event payload passes without re-reading the PR"

# --- the push-then-write race: payload body is stale, live body is compliant --

run_gate "" "$COMPLIANT"
expect_code 0 "$RC" "empty payload body with a compliant live body"
assert_contains "$OUT" "Pipeline step attestation is valid" "stale empty payload is re-read"
[ "$(gh_call_count)" -ge 1 ] || fail "a non-compliant payload body must be re-read from the API"
pass "an opened-event body written before the pipeline section passes once the live body lands"

run_gate "$SIGNED_NO_ATTESTATION" "$COMPLIANT"
expect_code 0 "$RC" "signed-but-unattested payload with a compliant live body"
assert_contains "$OUT" "Pipeline step attestation is valid" "stale signed payload is re-read"
pass "a synchronize-event body that predates the attestation comment passes once the live body lands"

# --- genuinely non-compliant PRs still fail ---------------------------------

run_gate "no pipeline here" "no pipeline here"
expect_code 1 "$RC" "unsigned body"
assert_contains "$OUT" "This PR was not raised through no-mistakes." "unsigned body names the gate"
pass "a body that never gains the signature is refused"

run_gate "$SIGNED_NO_ATTESTATION" "$SIGNED_NO_ATTESTATION"
expect_code 1 "$RC" "signed body with no attestation comment"
assert_contains "$OUT" "structured pipeline step attestation is missing or unparseable" \
  "missing attestation names the version floor"
pass "a signature without a parseable attestation is refused"

SKIPPED=$(body_with skipped completed completed)
run_gate "$SKIPPED" "$SKIPPED"
expect_code 1 "$RC" "attestation with a skipped required step"
assert_contains "$OUT" "review=skipped" "skipped required step is named"
pass "an attestation whose required step only skipped is refused"

# --- an unreadable API must not turn a refusal into a pass ------------------

FAKE_GH_FAIL=1
run_gate "no pipeline here" "$COMPLIANT"
FAKE_GH_FAIL=
expect_code 1 "$RC" "unsigned body when the API re-read fails"
assert_contains "$OUT" "This PR was not raised through no-mistakes." "API failure falls back to the payload verdict"
pass "an unreadable API leaves the payload verdict standing rather than passing"

echo "# all no-mistakes-required workflow tests passed"
