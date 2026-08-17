#!/usr/bin/env bash
# fm-ci-workflow-check.sh - lint the self-hosted CI workflow's mechanical policy.
#
# Usage:
#   fm-ci-workflow-check.sh [ci-workflow [no-mistakes-workflow]]
#
# Parses both workflows as YAML, then fails closed unless CI has one suite job,
# PR/branch-scoped cancellation, the water-7 routing fallback, load admission,
# the complete fm-test-run entrypoint, read-only permissions, and the matching
# water-7 route for the no-mistakes compliance workflow.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_WORKFLOW=${1:-$ROOT/.github/workflows/ci.yml}
COMPLIANCE_WORKFLOW=${2:-$ROOT/.github/workflows/no-mistakes-required.yml}

command -v python3 >/dev/null 2>&1 || {
  printf 'fm-ci-workflow-check.sh: python3 is required\n' >&2
  exit 127
}

python3 - "$CI_WORKFLOW" "$COMPLIANCE_WORKFLOW" <<'PY'
import sys

try:
    import yaml
except ImportError:
    print("fm-ci-workflow-check.sh: python3-yaml is required", file=sys.stderr)
    raise SystemExit(127)

ci_path, compliance_path = sys.argv[1:]
expected_route = "${{ fromJSON(vars.FM_CI_RUNNER_LABELS || '[\"self-hosted\",\"linux\",\"x64\",\"water-7\"]') }}"
expected_group = "ci-water-7-${{ github.event.pull_request.number || github.ref }}"
errors = []


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            document = yaml.load(handle, Loader=yaml.BaseLoader)
    except (OSError, yaml.YAMLError) as error:
        errors.append(f"{path}: invalid workflow YAML: {error}")
        return {}
    if not isinstance(document, dict):
        errors.append(f"{path}: workflow must be a mapping")
        return {}
    return document


def scalar(mapping, key):
    value = mapping.get(key) if isinstance(mapping, dict) else None
    return value if isinstance(value, str) else None


ci = load(ci_path)
compliance = load(compliance_path)

if "pull_request_target" in ci.get("on", {}):
    errors.append("CI must never execute pull_request_target code on water-7")
triggers = ci.get("on", {})
if not isinstance(triggers, dict) or "push" not in triggers or "pull_request" not in triggers:
    errors.append("CI must run for main pushes and pull requests")
if ci.get("permissions") != {"contents": "read"}:
    errors.append("CI permissions must stay exactly contents: read")

concurrency = ci.get("concurrency")
if not isinstance(concurrency, dict):
    errors.append("CI concurrency policy is missing")
else:
    if scalar(concurrency, "group") != expected_group:
        errors.append("CI concurrency must be reachable and scoped to water-7 plus PR number or ref")
    if scalar(concurrency, "cancel-in-progress") != "true":
        errors.append("CI concurrency must cancel stale in-progress runs")

jobs = ci.get("jobs")
if not isinstance(jobs, dict) or set(jobs) != {"suite"}:
    errors.append("CI must expose exactly one suite job")
    suite = {}
else:
    suite = jobs["suite"] if isinstance(jobs["suite"], dict) else {}

if scalar(suite, "name") != "Suite":
    errors.append("the required status-check job must be named Suite")
if scalar(suite, "runs-on") != expected_route:
    errors.append("Suite must route through the water-7 label fallback")
if "if" in suite:
    errors.append("Suite must not be hidden behind a job-level condition")

steps = suite.get("steps", []) if isinstance(suite, dict) else []
run_blocks = [step.get("run", "") for step in steps if isinstance(step, dict)]
joined_runs = "\n".join(run_blocks)
for command, description in (
    ("bin/fm-ci-workflow-check.sh", "workflow policy lint"),
    ("bin/fm-ci-load-guard.sh wait", "pre-suite load admission"),
    ("bin/fm-test-run.sh --all", "complete repository suite"),
    ("bin/fm-ci-load-guard.sh check", "post-suite load verdict"),
):
    if command not in joined_runs:
        errors.append(f"Suite is missing {description}: {command}")

compliance_jobs = compliance.get("jobs", {})
check = compliance_jobs.get("check", {}) if isinstance(compliance_jobs, dict) else {}
if scalar(check, "runs-on") != expected_route:
    errors.append("no-mistakes compliance must use the same water-7 label fallback")
if "pull_request_target" in compliance.get("on", {}):
    errors.append("no-mistakes compliance must not use pull_request_target")

if errors:
    for error in errors:
        print(f"fm-ci-workflow-check.sh: {error}", file=sys.stderr)
    raise SystemExit(1)

print("fm-ci-workflow-check.sh: workflow policy ok (suite=Suite runner=water-7)")
PY
