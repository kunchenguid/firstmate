#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action and for the
# workflow step that hands it the live PR body.
#
# Regression origin: `git push no-mistakes` pushes the branch (synchronize) and
# rebinds the PR body attestation to the new head a moment later (edited). The
# synchronize event payload snapshots the body before that rebind, so judging
# the payload body failed every re-pushed PR on a stale head_sha (#2737) even
# when the live body was corrected minutes before the runner started. The
# workflow's live-body step is extracted from the YAML and executed here
# against a fake `gh`, and whatever it emits is judged by the real pinned
# verifier, so the tests prove the body the gate judges, not the YAML text.
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

# --- workflow live-body step ---------------------------------------------------

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
LIVE_BODY_SCRIPT="$TMP_ROOT/live-body.sh"
PR_REPO=kunchenguid/firstmate
PR_NUMBER=3006

bound_body() {
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":%s} -->\n' \
    "$SIGNATURE" "$1" "$COMPLETED_STEPS"
}

# Pull the `run:` block scalar of the step whose id is live-body out of the
# workflow so the same script GitHub executes runs here. Any other shape (a
# renamed id, the script moved out of the step) fails loudly instead of
# silently testing nothing.
extract_live_body_script() {
  python3 - "$WORKFLOW" > "$LIVE_BODY_SCRIPT" <<'PY2'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()


def indent(line):
    return len(line) - len(line.lstrip())


start = next((i for i, line in enumerate(lines) if line.strip() == "id: live-body"), None)
if start is None:
    sys.exit("no step with id: live-body in the workflow")
key_indent = indent(lines[start])
run_at = None
for j in range(start + 1, len(lines)):
    line = lines[j]
    if not line.strip():
        continue
    if indent(line) < key_indent or (indent(line) == key_indent and line.lstrip().startswith("- ")):
        break
    if indent(line) == key_indent and line.strip() == "run: |":
        run_at = j
        break
if run_at is None:
    sys.exit("the live-body step has no `run: |` block")
block = []
block_indent = None
for line in lines[run_at + 1:]:
    if not line.strip():
        block.append("")
        continue
    if indent(line) <= key_indent:
        break
    if block_indent is None:
        block_indent = indent(line)
    block.append(line[block_indent:])
print("\n".join(block).rstrip("\n"))
PY2
  [ -s "$LIVE_BODY_SCRIPT" ] || fail "could not extract the live-body step script from the workflow"
}

# Fake `gh api` that answers with numbered response files: call n reads
# <dir>/n.json, repeating the last file once the sequence is exhausted. A file
# holding the single word FAIL makes that call exit 1 like an API outage.
install_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_FAKE_LOG"
count=$(cat "$GH_FAKE_COUNT" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$GH_FAKE_COUNT"
last=$(ls "$GH_FAKE_RESPONSES" | sed 's/\.json$//' | sort -n | tail -1)
[ "$count" -le "$last" ] || count=$last
file="$GH_FAKE_RESPONSES/$count.json"
if [ "$(cat "$file")" = FAIL ]; then
  printf 'gh: HTTP 503 unavailable\n' >&2
  exit 1
fi
cat "$file"
SH
  chmod +x "$fakebin/gh"
}

# run_live_body_step <case> <attempts> <response-body>... ; sets STEP_RC,
# STEP_OUTPUT (stdout+stderr), STEP_BODY (the body= output GitHub would pass
# on, or the literal string NONE when the step emitted an empty body), and
# STEP_CALLS (how many times gh was invoked).
run_live_body_step() {
  local case_dir=$1 attempts=$2 fakebin n=0 body
  shift 2
  case_dir="$TMP_ROOT/$case_dir"
  mkdir -p "$case_dir/responses"
  fakebin=$(fm_fakebin "$case_dir")
  install_fake_gh "$fakebin"
  for body in "$@"; do
    n=$((n + 1))
    if [ "$body" = FAIL ]; then
      printf 'FAIL\n' > "$case_dir/responses/$n.json"
    else
      jq -n --arg body "$body" '{number: 3006, body: $body}' > "$case_dir/responses/$n.json"
    fi
  done
  : > "$case_dir/output"
  : > "$case_dir/gh.log"
  STEP_RC=0
  STEP_OUTPUT=$(
    PATH="$fakebin:$PATH" GITHUB_OUTPUT="$case_dir/output" \
      GH_FAKE_RESPONSES="$case_dir/responses" GH_FAKE_LOG="$case_dir/gh.log" \
      GH_FAKE_COUNT="$case_dir/gh.count" \
      PR_REPO="$PR_REPO" PR_NUMBER="$PR_NUMBER" PR_HEAD_SHA="$NEW_SHA" \
      NM_LIVE_BODY_ATTEMPTS="$attempts" NM_LIVE_BODY_INTERVAL=0 \
      bash "$LIVE_BODY_SCRIPT" 2>&1
  ) || STEP_RC=$?
  STEP_CALLS=$(cat "$case_dir/gh.count" 2>/dev/null || printf 0)
  STEP_BODY=$(python3 - "$case_dir/output" <<'PY2'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
i = 0
while i < len(lines):
    if lines[i].startswith("body<<"):
        delimiter = lines[i][len("body<<"):]
        j = i + 1
        while j < len(lines) and lines[j] != delimiter:
            j += 1
        if j >= len(lines):
            sys.exit("body heredoc output never closed")
        value = "\n".join(lines[i + 1:j])
        print(value if value else "NONE")
        sys.exit(0)
    if lines[i].startswith("body="):
        value = lines[i][len("body="):]
        print(value if value else "NONE")
        sys.exit(0)
    i += 1
sys.exit("the step emitted no body output")
PY2
  ) || fail "live-body step wrote no usable GITHUB_OUTPUT body"
}

assert_gh_read_this_pr() {
  local calls
  calls=$(sort -u "$TMP_ROOT/$1/gh.log")
  [ "$calls" = "api repos/$PR_REPO/pulls/$PR_NUMBER" ] \
    || fail "live-body step did not read this PR through the API (saw: $calls)"
}

test_live_body_step_hands_over_an_already_bound_body() {
  local rc output
  run_live_body_step bound 12 "$(bound_body "$NEW_SHA")"
  expect_code 0 "$STEP_RC" "live-body step failed on an already bound body"
  assert_gh_read_this_pr bound
  [ "$STEP_CALLS" = 1 ] || fail "live-body step kept polling a body that already bound the head ($STEP_CALLS calls)"
  rc=0
  output=$(run_verifier "$STEP_BODY" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "pinned verifier rejected the live body the step handed over"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "handed-over live body was not judged compliant"
  pass "live-body step hands an already bound body to the verifier after one read"
}

test_live_body_step_waits_for_the_pipeline_rebind() {
  local stale rc output
  stale=$(bound_body "$OLD_SHA")
  rc=0
  output=$(run_verifier "$stale" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "the stale payload body should fail against the pushed head"
  run_live_body_step rebind 12 "$stale" "$stale" "$(bound_body "$NEW_SHA")"
  expect_code 0 "$STEP_RC" "live-body step failed while waiting for the rebind"
  assert_gh_read_this_pr rebind
  [ "$STEP_CALLS" = 3 ] || fail "live-body step did not stop polling once the body bound the head ($STEP_CALLS calls)"
  assert_contains "$STEP_OUTPUT" "does not attest head $NEW_SHA yet (attempt 1/12)" \
    "live-body step did not report the stale body it waited through"
  rc=0
  output=$(run_verifier "$STEP_BODY" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "pinned verifier rejected the rebound live body"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "rebound live body was not judged compliant"
  pass "live-body step waits through the stale snapshot until the body binds the pushed head"
}

test_live_body_step_never_passes_an_unbound_body() {
  local stale rc output
  stale=$(bound_body "$OLD_SHA")
  run_live_body_step unbound 3 "$stale"
  expect_code 0 "$STEP_RC" "live-body step must leave the verdict to the verifier"
  [ "$STEP_CALLS" = 3 ] || fail "live-body step did not spend exactly its attempt budget ($STEP_CALLS calls)"
  [ "$STEP_BODY" = "$stale" ] || fail "live-body step did not hand over the last live body it read"
  rc=0
  output=$(run_verifier "$STEP_BODY" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "a body that never bound the pushed head passed the gate"
  assert_contains "$output" "$OLD_SHA" "unbound failure did not name the attestation head"
  assert_contains "$output" "$NEW_SHA" "unbound failure did not name the pushed head"
  pass "live-body step exhausts its budget and the verifier still rejects an unbound body"
}

test_live_body_step_falls_back_to_the_payload_when_the_api_is_down() {
  local event rc output
  run_live_body_step outage 2 FAIL
  expect_code 0 "$STEP_RC" "live-body step must not turn an API outage into a verdict"
  [ "$STEP_CALLS" = 2 ] || fail "live-body step did not retry the API before falling back ($STEP_CALLS calls)"
  [ "$STEP_BODY" = NONE ] || fail "live-body step handed over a body it never read"
  assert_contains "$STEP_OUTPUT" "::warning::" "API fallback was silent"
  event="$TMP_ROOT/outage/event.json"
  jq -n --arg body "$(bound_body "$NEW_SHA")" --arg sha "$NEW_SHA" \
    '{pull_request: {number: 3006, body: $body, head: {sha: $sha}, user: {login: "regression"}}}' > "$event"
  rc=0
  output=$(PR_BODY="" GITHUB_EVENT_PATH="$event" PR_HEAD_SHA="$NEW_SHA" python3 "$VERIFY" 2>&1) || rc=$?
  expect_code 0 "$rc" "pinned verifier did not fall back to the event payload body"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "payload fallback was not judged"
  pass "live-body step falls back to the event payload body when the API cannot be read"
}

fetch_shared_verifier
extract_live_body_script
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_live_body_step_hands_over_an_already_bound_body
test_live_body_step_waits_for_the_pipeline_rebind
test_live_body_step_never_passes_an_unbound_body
test_live_body_step_falls_back_to_the_payload_when_the_api_is_down
