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
[ "${GH_TOKEN:-}" = synthetic-gh-token ] || exit 91
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

workflow_json() {
  python3 "$ROOT/tests/workflow-contract.py" "$1"
}

extract_signature_script() {
  local workflow
  workflow=$(workflow_json "$WORKFLOW")
  WORKFLOW_JSON="$workflow" python3 - <<'PY'
import json
import os

workflow = json.loads(os.environ["WORKFLOW_JSON"])
for step in workflow["jobs"]["check"]["steps"]:
    if step.get("name") == "Verify no-mistakes signature in PR body":
        print(step["run"], end="")
        break
else:
    raise SystemExit("signature step missing")
PY
}

workflow_signature_env() {
  local workflow
  workflow=$(workflow_json "$WORKFLOW")
  WORKFLOW_JSON="$workflow" python3 - <<'PY'
import json
import os

workflow = json.loads(os.environ["WORKFLOW_JSON"])
for step in workflow["jobs"]["check"]["steps"]:
    if step.get("name") == "Verify no-mistakes signature in PR body":
        for key, value in step.get("env", {}).items():
            print(f"{key}\t{value}")
        break
else:
    raise SystemExit("signature step missing")
PY
}

apply_signature_env() {
  local body=$1 key expression value
  while IFS=$'\t' read -r key expression; do
    case "$expression" in
      '${{ github.event.pull_request.body }}') value=$body ;;
      '${{ github.event.pull_request.user.login }}') value=synthetic-fork-contributor ;;
      '${{ github.event.pull_request.number }}') value=418 ;;
      '${{ github.token }}') value=synthetic-gh-token ;;
      *) fail "unsupported signature-step environment expression for $key: $expression" ;;
    esac
    export "$key=$value"
  done < <(workflow_signature_env)
}

signature_result() {
  local body=$1 script
  script=$(extract_signature_script)
  : > "$SIGNATURE_DATE_STATE"
  : > "$SIGNATURE_GH_LOG"
  export GITHUB_REPOSITORY=JTInventory/firstmate
  apply_signature_env "$body" || return 1
  export PATH="$FAKEBIN:$PATH"
  bash -c "$script" > "$SIGNATURE_OUTPUT" 2>&1
}

render_workflow_field() {
  local field=$1 action=$2 run_number=$3 run_id=$4 workflow
  workflow=$(workflow_json "$WORKFLOW")
  WORKFLOW_JSON="$workflow" FIELD="$field" ACTION="$action" \
    RUN_NUMBER="$run_number" RUN_ID="$run_id" python3 - <<'PY'
import json
import os
import re

workflow = json.loads(os.environ["WORKFLOW_JSON"])
field = os.environ["FIELD"]
value = workflow["concurrency"]["group"] if field == "concurrency.group" else workflow["run-name"]
context = {
    "github.event.pull_request.number": 418,
    "github.event.action": os.environ["ACTION"],
    "github.run_number": int(os.environ["RUN_NUMBER"]),
    "github.run_id": os.environ["RUN_ID"],
}

def evaluate(expression):
    expression = expression.strip()
    for token, replacement in sorted(context.items(), key=lambda item: -len(item[0])):
        expression = expression.replace(token, repr(replacement))
    expression = expression.replace("||", " or ").replace("&&", " and ")
    return eval(expression, {"__builtins__": {}}, {})

print(re.sub(r"\$\{\{\s*(.*?)\s*\}\}", lambda match: str(evaluate(match.group(1))), value))
PY
}

render_group() {
  render_workflow_field concurrency.group "$1" 1 "$2"
}

render_run_name() {
  render_workflow_field run-name "$1" "$2" "$3"
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
  local workflow
  workflow=$(workflow_json "$WORKFLOW")
  WORKFLOW_JSON="$workflow" python3 - <<'PY'
import json
import os

workflow = json.loads(os.environ["WORKFLOW_JSON"])
event = workflow["on"]
assert event["pull_request"]["types"] == ["opened", "edited", "synchronize", "reopened"]
assert event["pull_request"]["branches"] == ["main"]
assert workflow["permissions"] == {"contents": "read", "pull-requests": "read"}
assert workflow["concurrency"]["cancel-in-progress"] is True
assert "github.event.pull_request.number" in workflow["concurrency"]["group"]
assert "github.run_id" in workflow["concurrency"]["group"]
assert workflow["run-name"] == "PR #${{ github.event.pull_request.number }} body compliance - ${{ github.event.action }} - event ${{ github.run_number }} (run ${{ github.run_id }})"
job = workflow["jobs"]["check"]
assert job["name"] == "PR must be raised via no-mistakes"
assert set(event) == {"pull_request"}
def contains_secret(value):
    if isinstance(value, dict):
        return any(contains_secret(child) for child in value.values())
    if isinstance(value, list):
        return any(contains_secret(child) for child in value)
    return isinstance(value, str) and "secrets." in value
assert all(
    not isinstance(step.get("uses"), str)
    or step["uses"].split("@", 1)[0] != "actions/checkout"
    for step in job["steps"]
)
assert all(not contains_secret(step.get(field, {})) for step in job["steps"] for field in ("run", "env", "with"))
condition = job["if"]
assert "github-actions[bot]" in condition and "dependabot[bot]" in condition
assert "release-please[bot]" not in condition
PY
  local status=$?
  expect_code 0 "$status" "workflow semantic assertions must pass"
  pass "semantic workflow identity, security, and signature contracts are preserved"
}

test_signature_sequence_at_fixed_head
test_workflow_semantics
