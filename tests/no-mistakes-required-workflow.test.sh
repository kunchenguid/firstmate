#!/usr/bin/env bash
# Contract and synthetic event replay for the PR body compliance workflow.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-required-workflow.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SIGNATURE_DATE_STATE="$TMP_ROOT/date-state"
SIGNATURE_GH_LOG="$TMP_ROOT/gh.log"
SIGNATURE_OUTPUT="$TMP_ROOT/signature-output"
export SIGNATURE_DATE_STATE SIGNATURE_GH_LOG

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SIGNATURE_GH_LOG"
SH
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
if [ -s "$SIGNATURE_DATE_STATE" ]; then
  printf '190\n'
else
  printf '100\n' > "$SIGNATURE_DATE_STATE"
  printf '100\n'
fi
SH
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/date" "$FAKEBIN/sleep"

extract_signature_script() {
  python3 - "$WORKFLOW" <<'PY'
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    workflow = yaml.safe_load(fh)
for step in workflow["jobs"]["check"]["steps"]:
    if step.get("name") == "Verify no-mistakes signature in PR body":
        print(step["run"], end="")
        break
else:
    raise SystemExit("signature step missing")
PY
}

signature_result() {
  local body=$1 script
  script=$(extract_signature_script)
  : > "$SIGNATURE_DATE_STATE"
  : > "$SIGNATURE_GH_LOG"
  GITHUB_REPOSITORY=JTInventory/firstmate \
    PR_NUMBER=418 \
    PR_AUTHOR=synthetic-fork-contributor \
    PR_BODY="$body" \
    PATH="$FAKEBIN:$PATH" \
    bash -c "$script" > "$SIGNATURE_OUTPUT" 2>&1
}

render_group() {
  local action=$1 run_id=$2
  case "$action" in
    opened|edited) printf 'no-mistakes-required-418-%s\n' "$run_id" ;;
    synchronize|reopened) printf 'no-mistakes-required-418-head-change\n' ;;
  esac
}

render_run_name() {
  local action=$1 run_number=$2 run_id=$3
  printf 'PR #418 body compliance - %s - event %s (run %s)\n' "$action" "$run_number" "$run_id"
}

test_signature_sequence_at_fixed_head() {
  signature_result "Synthetic body\n$MARKER" || fail "signed opened event must succeed"
  if signature_result 'Synthetic unsigned edit'; then
    fail "unsigned edited event must fail"
  fi
  assert_grep '::error::This PR was not raised through no-mistakes.' "$SIGNATURE_OUTPUT" \
    "unsigned edited event did not reach the compliance rejection"
  assert_grep 'api repos/JTInventory/firstmate/pulls/418 --jq .body' "$SIGNATURE_GH_LOG" \
    "unsigned edited event did not use the controlled live-body lookup"
  signature_result "Synthetic signed edit\n$MARKER" || fail "signed edited event must succeed"
  pass "fixed-head signed opened, unsigned edited, signed edited yields 0/1/0"
}

test_workflow_semantics() {
  local opened edited_one edited_two synchronize reopened
  opened=$(render_group opened 9001)
  edited_one=$(render_group edited 9002)
  edited_two=$(render_group edited 9003)
  synchronize=$(render_group synchronize 9004)
  reopened=$(render_group reopened 9005)
  [ "$opened" != "$edited_one" ] && [ "$opened" != "$edited_two" ] && [ "$edited_one" != "$edited_two" ] || \
    fail "body events must have distinct immutable groups"
  [ "$synchronize" = "$reopened" ] || fail "synchronize and reopened must share head-change"
  case "$opened $edited_one $edited_two" in *head-change*) fail "body event reused head-change" ;; esac

  first=$(render_run_name edited 73 9002)
  second=$(render_run_name edited 74 9003)
  [ "$first" = 'PR #418 body compliance - edited - event 73 (run 9002)' ] || fail "first synthetic run name is incomplete"
  [ "$second" = 'PR #418 body compliance - edited - event 74 (run 9003)' ] || fail "second synthetic run name is incomplete"
  [ "$first" != "$second" ] || fail "distinct events must have unique run names"
  python3 - "$WORKFLOW" "$MARKER" <<'PY'
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    workflow = yaml.safe_load(fh)
event = workflow.get("on", workflow.get(True))
assert event["pull_request"]["types"] == ["opened", "edited", "synchronize", "reopened"]
assert event["pull_request"]["branches"] == ["main"]
assert workflow["permissions"] == {"contents": "read"}
assert workflow["concurrency"]["cancel-in-progress"] is True
assert "github.event.pull_request.number" in workflow["concurrency"]["group"]
assert "github.run_id" in workflow["concurrency"]["group"]
assert workflow["run-name"] == "PR #${{ github.event.pull_request.number }} body compliance - ${{ github.event.action }} - event ${{ github.run_number }} (run ${{ github.run_id }})"
job = workflow["jobs"]["check"]
assert job["name"] == "PR must be raised via no-mistakes"
assert "pull_request_target" not in repr(workflow)
assert "actions/checkout" not in repr(workflow)
assert "secrets." not in repr(workflow)
condition = job["if"]
assert "github-actions[bot]" in condition and "dependabot[bot]" in condition
assert "release-please[bot]" not in condition
run = next(step["run"] for step in job["steps"] if step.get("name") == "Verify no-mistakes signature in PR body")
assert sys.argv[2] in run
assert "api repos/JTInventory/firstmate/pulls/" in run
PY
  pass "semantic workflow identity, security, and signature contracts are preserved"
}

test_signature_sequence_at_fixed_head
test_workflow_semantics
