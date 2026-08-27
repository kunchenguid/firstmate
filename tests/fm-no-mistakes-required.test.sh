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

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails

# --- the synchronize seam ---------------------------------------------------
#
# GitHub snapshots the PR body into the event payload when the event fires.
# no-mistakes pushes the branch first and rewrites the body with the new head's
# attestation a couple of minutes later, so the snapshot a `synchronize` run
# would judge still carries the previous head's attestation. These cases drive
# bin/fm-attestation-settle.sh against a `gh` that replays that sequence, then
# hand what it settled on to the same pinned verifier the action runs.

SETTLE="$ROOT/bin/fm-attestation-settle.sh"

attested_body() {
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":%s} -->\n' \
    "$SIGNATURE" "$1" "$COMPLETED_STEPS"
}

new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir" || fail "could not create case dir $dir"
  printf '%s\n' "$dir"
}

# A `gh` that answers the body read with the previous head's attestation until
# read <flip>, then with the pushed head's - the no-mistakes push-then-rewrite
# sequence. A flip past the attempt budget models a push nothing ever attested.
install_gh_stub() {
  local dir=$1 flip=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  attested_body "$OLD_SHA" > "$dir/body.before"
  attested_body "$NEW_SHA" > "$dir/body.after"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
reads=\$(cat "$dir/reads" 2>/dev/null || printf '0')
reads=\$((reads + 1))
printf '%s\n' "\$reads" > "$dir/reads"
if [ "\$reads" -ge $flip ]; then
  cat "$dir/body.after"
else
  cat "$dir/body.before"
fi
SH
  chmod +x "$fakebin/gh" || fail "could not install the gh stub"
  printf '%s\n' "$fakebin"
}

# A `gh` that cannot answer at all (no network, no token, revoked scope).
install_unreadable_gh_stub() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
reads=\$(cat "$dir/reads" 2>/dev/null || printf '0')
printf '%s\n' "\$((reads + 1))" > "$dir/reads"
exit 1
SH
  chmod +x "$fakebin/gh" || fail "could not install the unreadable gh stub"
  printf '%s\n' "$fakebin"
}

run_settle() {
  local dir=$1 fakebin=$2 attempts=$3
  GITHUB_OUTPUT="$dir/github-output" PATH="$fakebin:$PATH" \
    "$SETTLE" --repo owner/repo --pr 3006 --head "$NEW_SHA" \
      --attempts "$attempts" --interval-seconds 0 2>"$dir/settle.err"
}

reads_made() {
  cat "$1/reads" 2>/dev/null || printf '0'
}

# Recover a step output from a $GITHUB_OUTPUT file the way the Actions runner
# does: the heredoc block between "<name><<DELIM" and the delimiter line.
github_output_value() {
  local file=$1 name=$2 line delim='' collecting=0 first=1 out=''
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$collecting" -eq 0 ]; then
      case "$line" in
        "$name"'<<'*) delim=${line#"$name<<"}; collecting=1 ;;
      esac
      continue
    fi
    [ "$line" != "$delim" ] || { collecting=0; continue; }
    if [ "$first" -eq 1 ]; then
      out=$line
      first=0
    else
      out="$out
$line"
    fi
  done < "$file"
  printf '%s\n' "$out"
}

# Judge a body through the event payload rather than an explicit PR_BODY, which
# is what the action falls back to when the workflow passes an empty pr-body.
run_verifier_from_payload() {
  local dir=$1 body=$2 head=$3
  python3 - "$dir/event.json" "$body" "$head" <<'PY'
import json, sys
path, body, head = sys.argv[1], sys.argv[2], sys.argv[3]
payload = {
    "pull_request": {
        "body": body,
        "head": {"sha": head, "ref": "fm/regression"},
        "user": {"login": "regression"},
        "number": 3006,
    }
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
  PR_BODY='' PR_HEAD_SHA='' PR_HEAD_REF='' PR_AUTHOR='' PR_NUMBER='' \
    GITHUB_EVENT_PATH="$dir/event.json" python3 "$VERIFY" 2>&1
}

test_payload_snapshot_of_a_no_mistakes_push_is_the_reported_failure() {
  local dir output rc
  dir=$(new_case payload-snapshot)
  attested_body "$OLD_SHA" > "$dir/body.before"
  rc=0
  output=$(run_verifier_from_payload "$dir" "$(cat "$dir/body.before")" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "the stale synchronize payload snapshot was accepted at the pushed head"
  assert_contains "$output" "Pipeline attestation head_sha does not match the current PR head" \
    "the reproduced synchronize snapshot did not fail the way CI reported"
  pass "the synchronize payload snapshot of a no-mistakes push fails the gate"
}

test_settled_body_passes_the_gate_once_the_push_is_attested() {
  local dir fakebin body output rc
  dir=$(new_case settles)
  fakebin=$(install_gh_stub "$dir" 2)
  rc=0
  body=$(run_settle "$dir" "$fakebin" 5) || rc=$?
  expect_code 0 "$rc" "settling the PR body reported a failure of its own"
  expect_code 2 "$(reads_made "$dir")" "settling kept reading after the body bound to the pushed head"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "the settled body was still judged non-compliant at the pushed head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "the settled body was not reported as compliant"
  pass "the settled live body passes the gate the payload snapshot failed"
}

test_settled_body_reaches_the_action_as_a_step_output() {
  local dir fakebin body recovered
  dir=$(new_case step-output)
  fakebin=$(install_gh_stub "$dir" 1)
  body=$(run_settle "$dir" "$fakebin" 5) || fail "settling the PR body reported a failure of its own"
  [ -s "$dir/github-output" ] || fail "settling wrote no step output for the action to consume"
  recovered=$(github_output_value "$dir/github-output" body)
  [ "$recovered" = "$body" ] || fail "the step output did not round-trip the multi-line settled body"
  assert_contains "$recovered" "$NEW_SHA" "the step output did not carry the pushed head's attestation"
  pass "the settled body round-trips to the action as a multi-line step output"
}

test_unattested_push_still_fails_after_a_bounded_wait() {
  local dir fakebin body output rc
  dir=$(new_case never-attested)
  fakebin=$(install_gh_stub "$dir" 99)
  rc=0
  body=$(run_settle "$dir" "$fakebin" 3) || rc=$?
  expect_code 0 "$rc" "settling refused instead of leaving the verdict to the gate"
  expect_code 3 "$(reads_made "$dir")" "settling did not stop at its attempt budget"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "a push no-mistakes never attested passed the gate after the wait"
  assert_contains "$output" "$OLD_SHA" "the still-stale failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" "the still-stale failure did not name the pushed head SHA"
  pass "a push that never gets attested still fails, after a bounded wait"
}

test_unreadable_body_leaves_the_gate_on_the_event_payload() {
  local dir fakebin body output rc
  dir=$(new_case unreadable)
  fakebin=$(install_unreadable_gh_stub "$dir")
  rc=0
  body=$(run_settle "$dir" "$fakebin" 2) || rc=$?
  expect_code 0 "$rc" "an unreadable PR body failed the settle step instead of deferring"
  [ -z "$body" ] || fail "an unreadable PR body was reported as a body to judge"
  [ -z "$(github_output_value "$dir/github-output" body)" ] || \
    fail "an unreadable PR body produced a non-empty pr-body input"
  rc=0
  output=$(run_verifier_from_payload "$dir" "$(attested_body "$NEW_SHA")" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "the event-payload fallback stopped judging a compliant body"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "the event-payload fallback did not report the compliant body as compliant"
  pass "an unreadable PR body leaves the gate on its event-payload default"
}

test_payload_snapshot_of_a_no_mistakes_push_is_the_reported_failure
test_settled_body_passes_the_gate_once_the_push_is_attested
test_settled_body_reaches_the_action_as_a_step_output
test_unattested_push_still_fails_after_a_bounded_wait
test_unreadable_body_leaves_the_gate_on_the_event_payload
