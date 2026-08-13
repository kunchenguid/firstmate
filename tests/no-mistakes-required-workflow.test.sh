#!/usr/bin/env bash
# Behavior coverage for the PR body compliance gate.
#
# The workflow file is a machine-consumed declarative artifact, so this test
# loads it into a semantic model (parsed YAML: jobs, step env bindings, the
# step's shell program) and then EXECUTES that program the way the runner does,
# with the workflow-declared environment variables bound to synthetic PR
# payloads. Assertions are on observed behavior - exit status and the operator
# diagnostic - never on the workflow's source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

command -v python3 >/dev/null 2>&1 || fail "test needs python3"
python3 -c 'import yaml' 2>/dev/null || fail "test needs PyYAML to model the workflow"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-required.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Reduce the workflow to the one thing the gate is: a program plus the payload
# fields it reads. Everything the runner would do around it (checkout, matrix,
# concurrency) is irrelevant to the pass/fail contract exercised here.
python3 - "$WORKFLOW" "$TMP_ROOT" <<'PY'
import sys
from pathlib import Path

import yaml

workflow_path, out_dir = map(Path, sys.argv[1:])
workflow = yaml.safe_load(workflow_path.read_text(encoding="utf-8"))

jobs = workflow.get("jobs") or {}
if len(jobs) != 1:
    raise SystemExit(f"expected exactly one compliance job, got {sorted(jobs)}")
(job,) = jobs.values()

steps = [s for s in (job.get("steps") or []) if "run" in s]
if len(steps) != 1:
    raise SystemExit(f"expected exactly one run step, got {len(steps)}")
step = steps[0]

env = step.get("env") or {}
for required in ("PR_BODY", "PR_AUTHOR", "PR_NUMBER"):
    if required not in env:
        raise SystemExit(f"step does not bind {required} from the PR payload")

(out_dir / "step.sh").write_text(step["run"], encoding="utf-8")
PY
[ -s "$TMP_ROOT/step.sh" ] || fail "could not model the compliance step from $WORKFLOW"

# Run the modeled step exactly as the runner does: bash, with the PR payload in
# the environment the step declared.
gate_run() {
  local body=$1 author=${2:-synthetic-contributor} number=${3:-4242}
  PR_BODY="$body" PR_AUTHOR="$author" PR_NUMBER="$number" \
    bash "$TMP_ROOT/step.sh" 2>"$TMP_ROOT/stderr" >"$TMP_ROOT/stdout"
}

pipeline_body() {
  printf '%s\n' \
    'Thank you.' \
    '' \
    '## Intent' \
    '' \
    'Fix the thing.' \
    '' \
    '## Pipeline' \
    '' \
    "$SIGNATURE" \
    '' \
    '- review: passed'
}

# A hand-written body - the exact shape that failed this repo's gate on a real
# PR - carries intent, changes, verification and privacy sections but no
# pipeline signature. It must be refused, and the refusal must tell the author
# how to comply rather than failing silently.
handwritten_body() {
  printf '%s\n' \
    'Thank you.' \
    '' \
    '## Intent' \
    '' \
    'Fix Pi Calm mode so operational messages are hidden.' \
    '' \
    '## Verification' \
    '' \
    '- Focused tests pass.' \
    '- CI is green.'
}

test_pipeline_body_passes() {
  gate_run "$(pipeline_body)" || fail "a no-mistakes pipeline body must satisfy the gate"
  assert_contains "$(cat "$TMP_ROOT/stdout")" "Found no-mistakes signature" \
    "a compliant body should report the signature it matched"
  pass "a PR body carrying the no-mistakes pipeline signature passes the gate"
}

test_handwritten_body_fails_with_guidance() {
  gate_run "$(handwritten_body)" && fail "a hand-written body without the signature must fail the gate"
  local err
  err=$(cat "$TMP_ROOT/stderr")
  assert_contains "$err" "This PR was not raised through no-mistakes." \
    "the refusal should name the cause"
  assert_contains "$err" "$SIGNATURE" \
    "the refusal should print the exact signature the author is missing"
  assert_contains "$err" "CONTRIBUTING.md" \
    "the refusal should point at the contributor workflow"
  assert_contains "$err" "Restore the pipeline's '## Pipeline'" \
    "the refusal should name the recovery for a PR whose body was overwritten"
  assert_contains "$err" "re-runs on every body edit" \
    "the refusal should say the gate re-evaluates after the body is restored"
  assert_contains "$err" "PR author: synthetic-contributor" \
    "the refusal should identify the author for maintainer triage"
  pass "a hand-written PR body without the signature fails the gate with actionable guidance"
}

test_empty_and_unset_body_fail() {
  gate_run "" && fail "an empty PR body must fail the gate"
  # GitHub omits the body entirely for a PR opened with no description, so the
  # step runs with PR_BODY unset under `set -u`.
  PR_AUTHOR=synthetic-contributor PR_NUMBER=4242 \
    bash "$TMP_ROOT/step.sh" >/dev/null 2>&1 \
    && fail "an absent PR body must fail the gate instead of erroring open"
  pass "an empty or absent PR body fails the gate"
}

test_near_miss_bodies_fail() {
  # A body that talks about no-mistakes, or links a different repository, is
  # not the deterministic signature the pipeline writes.
  gate_run 'Raised via no-mistakes. See https://github.com/kunchenguid/no-mistakes.' \
    && fail "prose mentioning no-mistakes must not satisfy the gate"
  gate_run 'Updates from [git push no-mistakes](https://github.com/someone-else/no-mistakes)' \
    && fail "a signature pointing at another repository must not satisfy the gate"
  gate_run 'Updates from git push no-mistakes (https://github.com/kunchenguid/no-mistakes)' \
    && fail "an unlinked paraphrase must not satisfy the gate"
  pass "near-miss bodies that lack the exact signature fail the gate"
}

# The signature is markdown containing [ ] ( ) . and /. A body that also
# contains regex metacharacters must not change how the marker is matched.
test_signature_is_matched_literally() {
  gate_run "Updates from .git push no-mistakes..https://github.com/kunchenguid/no-mistakes." \
    && fail "regex wildcards must not stand in for the literal signature"
  gate_run "$(printf '%s\n%s\n' 'a+b*c[d]' "$SIGNATURE")" \
    || fail "regex metacharacters elsewhere in the body must not break a valid signature"
  pass "the signature is matched literally, not as a pattern"
}

# Bot automation is exempted by the job condition, which the runner evaluates
# before the step exists. The step must therefore stay a pure signature check
# and treat every author identically.
test_step_verdict_is_author_independent() {
  gate_run "$(handwritten_body)" 'dependabot[bot]' \
    && fail "the step itself must not implement an author exemption"
  gate_run "$(pipeline_body)" 'dependabot[bot]' \
    || fail "a compliant body must pass regardless of author"
  pass "the step verdict depends on the body alone, never on the author"
}

test_pipeline_body_passes
test_handwritten_body_fails_with_guidance
test_empty_and_unset_body_fail
test_near_miss_bodies_fail
test_signature_is_matched_literally
test_step_verdict_is_author_independent
