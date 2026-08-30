#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action and for the
# body the repository's workflow feeds it (bin/fm-pr-body-settled.sh).
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

# --- the body the workflow hands the shared action --------------------------
#
# no-mistakes publishes the head-bound attestation only after it pushes the
# head, so the `synchronize` event payload carries a body that predates the
# attestation for the commit that just landed. These cases drive
# bin/fm-pr-body-settled.sh, the reader the workflow uses instead, through a
# stubbed `gh` on PATH.

SETTLE="$ROOT/bin/fm-pr-body-settled.sh"
SETTLE_REPO=kunchenguid/firstmate
SETTLE_NUMBER=3265

attested_body() {  # <head-sha>
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":%s} -->\n' \
    "$SIGNATURE" "$1" "$COMPLETED_STEPS"
}

# Install a `gh` stub whose body answers come from <case-dir>/reply.<n>, one per
# call, with the last file reused once the replies run out. A reply file named
# "fail" makes that call exit non-zero instead.
make_case() {  # <name>
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/bin"
  cat > "$case_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
calls="$FM_STUB_DIR/calls"
n=0
[ -f "$calls" ] && n=$(cat "$calls")
n=$((n + 1))
printf '%s\n' "$n" > "$calls"
reply="$FM_STUB_DIR/reply.$n"
while [ ! -e "$reply" ] && [ "$n" -gt 1 ]; do
  n=$((n - 1))
  reply="$FM_STUB_DIR/reply.$n"
done
if [ "$(cat "$reply")" = fail ]; then
  printf 'gh: HTTP 503 (repos/x/pulls/1)\n' >&2
  exit 1
fi
cat "$reply"
STUB
  chmod +x "$case_dir/bin/gh"
  printf '%s\n' "$case_dir"
}

run_settle() {  # <case-dir> <args>...
  local case_dir=$1
  shift
  PATH="$case_dir/bin:$PATH" FM_STUB_DIR="$case_dir" \
    "$SETTLE" --repo "$SETTLE_REPO" --number "$SETTLE_NUMBER" "$@"
}

# Assert <file> is exactly one GitHub Actions heredoc output block. That file
# format is a documented serialized protocol between a step and the runner, so
# it is the contract under test here, not an implementation detail.
assert_single_github_output() {  # <file> <name> <expected-value> <label>
  local file=$1 name=$2 expected=$3 label=$4 header delim actual
  header=$(head -n 1 "$file")
  case "$header" in
    "$name"'<<'?*) delim=${header#"$name<<"} ;;
    *) fail "$label: first line is not a '$name' heredoc header: $header" ;;
  esac
  [ "$(tail -n 1 "$file")" = "$delim" ] \
    || fail "$label: the block does not end with its own delimiter"
  [ "$(grep -c -xF -- "$delim" "$file")" -eq 1 ] \
    || fail "$label: the value re-opened or closed the block, so it can inject outputs"
  actual=$(sed -n '2,$p' "$file" | sed '$d')
  [ "$actual" = "$expected" ] \
    || fail "$label: value did not round-trip"$'\n'"--- got ---"$'\n'"$actual"
}

test_body_read_settles_on_the_pipeline_write() {
  local case_dir stale settled output rc
  case_dir=$(make_case settles)
  # Reads 1-2 see the body as the push's `synchronize` event froze it: still
  # attesting the previous head. Read 3 sees the pipeline's write for this head.
  stale=$(attested_body "$OLD_SHA")
  printf '%s\n' "$stale" > "$case_dir/reply.1"
  printf '%s\n' "$stale" > "$case_dir/reply.2"
  attested_body "$NEW_SHA" > "$case_dir/reply.3"

  # The frozen snapshot is what the gate used to judge, and it fails.
  rc=0
  output=$(run_verifier "$stale" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "the pre-write body should not satisfy the gate for the new head"

  rc=0
  settled=$(run_settle "$case_dir" --head-sha "$NEW_SHA" --timeout 10 --interval 1 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "the body reader failed while the pipeline was still writing the body"

  rc=0
  output=$(run_verifier "$settled" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "the gate rejected the body the pipeline actually published"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "the settled body was not judged compliant"
  pass "the gate judges the body the pipeline published for this head, not the pre-push snapshot"
}

test_waiting_never_turns_a_real_failure_into_a_pass() {
  local case_dir settled err output rc
  case_dir=$(make_case never-passes)
  attested_body "$OLD_SHA" > "$case_dir/reply.1"

  rc=0
  err="$case_dir/stderr"
  settled=$(run_settle "$case_dir" --head-sha "$NEW_SHA" --timeout 2 --interval 1 2>"$err") || rc=$?
  expect_code 0 "$rc" "an unsettled body must still be handed to the gate, not swallowed"
  assert_grep "still does not name head $NEW_SHA" "$err" \
    "the expired bound was not reported"

  rc=0
  output=$(run_verifier "$settled" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "waiting turned a head with no matching attestation into a pass"
  assert_contains "$output" "$OLD_SHA" "the failure did not name the attested head SHA"
  assert_contains "$output" "$NEW_SHA" "the failure did not name the actual PR head SHA"
  pass "a body that never binds the head still fails loudly after the bound expires"
}

test_transient_read_failure_does_not_red_the_gate() {
  local case_dir settled output rc
  case_dir=$(make_case transient)
  # No settle wait is due on a body-bearing event, so a forge hiccup on the one
  # read must still not be the thing that decides the gate.
  printf 'fail\n' > "$case_dir/reply.1"
  printf 'fail\n' > "$case_dir/reply.2"
  attested_body "$NEW_SHA" > "$case_dir/reply.3"

  rc=0
  settled=$(run_settle "$case_dir" --head-sha "$NEW_SHA" \
    --timeout 0 --interval 1 --read-retries 3 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "a transient read error ended the gate instead of being retried"

  rc=0
  output=$(run_verifier "$settled" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "the body recovered after a transient read error was not judged compliant"
  pass "a transient forge read error is retried instead of reported as a compliance failure"
}

test_unreadable_pull_request_fails_loudly() {
  local case_dir out err rc
  case_dir=$(make_case unreadable)
  printf 'fail\n' > "$case_dir/reply.1"
  out="$case_dir/stdout"
  err="$case_dir/stderr"

  rc=0
  run_settle "$case_dir" --head-sha "$NEW_SHA" --timeout 1 --interval 1 --read-retries 1 \
    > "$out" 2> "$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable pull request was reported as a readable one"
  [ ! -s "$out" ] || fail "a failed read still emitted a body:"$'\n'"$(cat "$out")"
  assert_grep "$SETTLE_REPO#$SETTLE_NUMBER" "$err" "the failure did not name the pull request"
  assert_grep "HTTP 503" "$err" "the failure did not carry the underlying read error"
  pass "a pull request body that cannot be read fails instead of falling back to a stale snapshot"
}

test_github_output_framing_survives_a_hostile_body() {
  local case_dir body rc
  case_dir=$(make_case hostile-output)
  # A body that reproduces the reader's own delimiter, on its own line and as a
  # forged second output, is exactly what would break a fixed-delimiter block.
  body="$SIGNATURE
fm-pr-body-settled-EOF
compliant=true
fm-pr-body-settled-EOF0
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  printf '%s\n' "$body" > "$case_dir/reply.1"

  rc=0
  GITHUB_OUTPUT="$case_dir/github-output" \
    run_settle "$case_dir" --head-sha "$NEW_SHA" --timeout 0 --interval 1 \
      --github-output body 2>/dev/null || rc=$?
  expect_code 0 "$rc" "the reader failed to emit a workflow output"
  assert_single_github_output "$case_dir/github-output" body "$body" \
    "a contributor-controlled body escaped its output block"
  pass "the body reaches the gate as one workflow output a contributor cannot break out of"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_body_read_settles_on_the_pipeline_write
test_waiting_never_turns_a_real_failure_into_a_pass
test_transient_read_failure_does_not_red_the_gate
test_unreadable_pull_request_fails_loudly
test_github_output_framing_survives_a_hostile_body
