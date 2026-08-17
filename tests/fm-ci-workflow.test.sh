#!/usr/bin/env bash
# Contract tests for the self-hosted CI workflow policy checker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKER="$ROOT/bin/fm-ci-workflow-check.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yml"
TMP_ROOT=$(fm_test_tmproot fm-ci-workflow)

run_checker() {
  local workflow=$1 output=$2 rc
  set +e
  "$CHECKER" "$workflow" >"$output" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

mutate_workflow() {
  local mutation=$1 destination=$2
  python3 - "$WORKFLOW" "$destination" "$mutation" <<'PY'
import sys
import yaml

source, destination, mutation = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    workflow = yaml.load(handle, Loader=yaml.BaseLoader)

if mutation == "concurrency-delete":
    workflow.pop("concurrency", None)
elif mutation == "concurrency-unreachable":
    workflow["concurrency"]["group"] = "ci-water-7-${{ false && github.ref }}"
elif mutation == "concurrency-weaken":
    workflow["concurrency"]["group"] = "ci-water-7"
elif mutation == "concurrency-constant-true":
    workflow["concurrency"]["group"] = "${{ true }}"
elif mutation == "routing-delete":
    workflow["jobs"]["suite"]["runs-on"] = workflow["jobs"]["suite"]["runs-on"].replace(
        ',"water-7"', ""
    )
elif mutation == "routing-unreachable":
    workflow["jobs"]["suite"]["if"] = "${{ false }}"
elif mutation == "routing-weaken":
    workflow["jobs"]["suite"]["runs-on"] = "${{ fromJSON('[\"self-hosted\"]') }}"
elif mutation == "routing-constant-true":
    workflow["jobs"]["suite"]["runs-on"] = "${{ true }}"
else:
    raise SystemExit(f"unknown mutation: {mutation}")

with open(destination, "w", encoding="utf-8") as handle:
    yaml.safe_dump(workflow, handle, sort_keys=False)
PY
}

[ -x "$CHECKER" ] || fail "bin/fm-ci-workflow-check.sh must be executable"

control_rc=$(run_checker "$WORKFLOW" "$TMP_ROOT/control.out")
[ "$control_rc" -eq 0 ] || fail "pristine workflow control failed: $(<"$TMP_ROOT/control.out")"
pass "pristine self-hosted workflow passes its policy checker"

for mutation in \
  concurrency-delete \
  concurrency-unreachable \
  concurrency-weaken \
  concurrency-constant-true \
  routing-delete \
  routing-unreachable \
  routing-weaken \
  routing-constant-true; do
  candidate="$TMP_ROOT/$mutation.yml"
  output="$TMP_ROOT/$mutation.out"
  mutate_workflow "$mutation" "$candidate"
  rc=$(run_checker "$candidate" "$output")
  [ "$rc" -ne 0 ] || fail "$mutation escaped the workflow policy checker"
  pass "$mutation mutation is refused (exit $rc)"
done
