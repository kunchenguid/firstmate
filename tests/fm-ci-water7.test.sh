#!/usr/bin/env bash
# Contract tests for the hosted slim primary path and self-hosted fallback policy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_ensure_pyyaml || fail "python3 PyYAML is required to parse workflow policy"

test_workflows_use_hosted_slim_ci_with_a_self_hosted_fallback() {
  if ! python3 - "$ROOT" <<'PY'
import pathlib
import os
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ModuleNotFoundError:
    print("fm-ci-water7.test.sh: python3 PyYAML is required to parse workflow policy", file=sys.stderr)
    sys.exit(2)

root = pathlib.Path(sys.argv[1])
labels = ["self-hosted", "Linux", "X64", "water-7"]
ci_path = root / ".github/workflows/ci.yml"
fallback_path = root / ".github/workflows/ci-water7-fallback.yml"
required_path = root / ".github/workflows/no-mistakes-required.yml"
ci = yaml.safe_load(ci_path.read_text())
fallback = yaml.safe_load(fallback_path.read_text())
required = yaml.safe_load(required_path.read_text())

assert ci.get("permissions") == {"contents": "read"}
assert fallback.get("permissions") == {"contents": "read"}
assert required.get("permissions") == {"contents": "read", "pull-requests": "read"}
expected_primary_jobs = [
    "lint",
    "critical-teardown",
    "critical-spawn",
    "critical-delivery",
    "critical-smokes",
    "test-coverage",
    "tests-portable-parallel-1",
    "tests-portable-parallel-2",
    "tests-portable-serial",
    "tests-herdr",
    "tests-timing-aggregate",
    "invariants",
]
assert list(ci["jobs"]) == expected_primary_jobs, list(ci["jobs"])
assert list(fallback["jobs"]) == ["suite"]
assert list(required["jobs"]) == ["check"]

assert fallback["concurrency"] == {
    "group": "ci-water-7-fallback-${{ github.event.workflow_run.id || github.run_id }}",
    "cancel-in-progress": True,
}

assert fallback["env"] == {"FM_CI_MAX_LOAD": "12"}

fallback_job = fallback["jobs"]["suite"]
required_job = required["jobs"]["check"]
hosted_label = "ubuntu-slim"
required_timeout = 15

primary_names = {
    "lint": "Lint",
    "critical-teardown": "Critical teardown safety",
    "critical-spawn": "Critical spawn safety",
    "critical-delivery": "Critical delivery and wake safety",
    "critical-smokes": "Critical end-to-end smokes",
    "test-coverage": "Test coverage guard",
    "tests-portable-parallel-1": "Behavior portable parallel 1",
    "tests-portable-parallel-2": "Behavior portable parallel 2",
    "tests-portable-serial": "Behavior portable serial ${{ matrix.shard }}",
    "tests-herdr": "Behavior tests (Herdr)",
    "tests-timing-aggregate": "Behavior timing aggregate",
    "invariants": "Repo invariants",
}
for job_id, job in ci["jobs"].items():
    assert job["runs-on"] == "ubuntu-latest", (job_id, job["runs-on"])
    assert job["name"] == primary_names[job_id], (job_id, job["name"])
    assert "self-hosted" not in str(job["runs-on"])
    assert "water-7" not in str(job["runs-on"])

lint = ci["jobs"]["lint"]
assert "strategy" not in lint
assert "needs" not in lint
assert "if" not in lint
assert lint.get("env") == {"FM_LINT_JOBS": "1"}
assert lint["steps"][-1]["run"] == "bin/fm-lint.sh --ci-fast"
assert "actionlint" not in str(lint)

critical_commands = {
    "critical-teardown": [
        "tests/fm-teardown.test.sh",
        "tests/fm-teardown-endpoint-safety.test.sh",
    ],
    "critical-spawn": [
        "tests/fm-spawn-dispatch-profile.test.sh",
        "tests/fm-spawn-pool-base-freshen.test.sh",
        "tests/fm-spawn-worktree-settle.test.sh",
    ],
    "critical-delivery": [
        "tests/fm-pr-merge.test.sh",
        "tests/fm-branch-supervision.test.sh",
        "tests/fm-wake-queue.test.sh",
        "tests/fm-wake-drain.test.sh",
        "tests/fm-wake-drain-open-decisions.test.sh",
        "tests/fm-wake-drain-open-decisions-cursor.test.sh",
        "tests/fm-wake-drain-unread-status.test.sh",
    ],
    "critical-smokes": [
        "tests/fm-backend-autodetect-smoke.test.sh",
        "tests/fm-backend-tmux-smoke.test.sh",
        "tests/fm-afk-inject-e2e.test.sh",
    ],
}
for job_id, scripts in critical_commands.items():
    job = ci["jobs"][job_id]
    assert "if" not in job
    assert "strategy" not in job
    command = job["steps"][-1]["run"]
    assert command.startswith("bin/fm-test-run.sh "), (job_id, command)
    for script in scripts:
        assert script in command, (job_id, script, command)

full_ci_gate = "github.event_name == 'push' || contains(github.event.pull_request.labels.*.name, 'full-ci')"
for job_id in (
    "test-coverage",
    "tests-portable-parallel-1",
    "tests-portable-parallel-2",
    "tests-portable-serial",
    "tests-herdr",
    "invariants",
):
    assert ci["jobs"][job_id]["if"] == full_ci_gate, job_id
assert ci["jobs"]["tests-timing-aggregate"]["if"] == f"always() && ({full_ci_gate})"
for job_id in ("tests-portable-parallel-1", "tests-portable-parallel-2"):
    assert ci["jobs"][job_id]["timeout-minutes"] == 15, job_id
portable_commands = {
    job_id: next(
        step["run"]
        for step in ci["jobs"][job_id]["steps"]
        if step.get("name", "").startswith("Run portable parallel shard")
    )
    for job_id in ("tests-portable-parallel-1", "tests-portable-parallel-2")
}

def execute_portable_command(job_id, expected_lane, expected_index, expected_jobs):
    with tempfile.TemporaryDirectory(prefix="fm-water7-command-") as directory:
        root = pathlib.Path(directory)
        runner = root / "bin/fm-test-run.sh"
        runner.parent.mkdir()
        args_file = root / "runner-args"
        runner.write_text(
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "printf '%s\\0' \"$@\" > \"$FM_WATER7_ARGS\"\n",
            encoding="utf-8",
        )
        runner.chmod(0o755)
        runner_temp = root / "runner-temp"
        runner_temp.mkdir()
        env = os.environ.copy()
        env.update({"RUNNER_TEMP": str(runner_temp), "FM_WATER7_ARGS": str(args_file)})
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", portable_commands[job_id]],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (job_id, result.stdout, result.stderr)
        args = args_file.read_bytes().split(b"\0")[:-1]
        args = [arg.decode() for arg in args]
        expected_json = runner_temp / "fm-test" / f"fm-test-timing-{expected_lane}.json"
        expected_args = ["--lane", expected_lane, "--json", str(expected_json)]
        if expected_jobs != 1:
            expected_args[0:0] = ["--jobs", str(expected_jobs)]
        assert args == expected_args, (job_id, args)
        assert expected_json.parent.is_dir(), (job_id, expected_json)
        match = re.fullmatch(r"portable-parallel-(\d+)", args[args.index("--lane") + 1])
        assert match and int(match.group(1)) == expected_index, (job_id, args)
        return expected_lane


executed_lanes = [
    execute_portable_command("tests-portable-parallel-1", "portable-parallel-1", 1, 2),
    execute_portable_command("tests-portable-parallel-2", "portable-parallel-2", 2, 1),
]
assert sorted(executed_lanes) == ["portable-parallel-1", "portable-parallel-2"]
assert [ci["jobs"][job_id]["timeout-minutes"] for job_id in portable_commands] == [15, 15]

required_tool_step = {
    "name": "Install required test tools",
    "run": "sudo apt-get update\nsudo apt-get install -y ripgrep\n",
}
for job_id in (
    "tests-portable-parallel-1",
    "tests-portable-parallel-2",
    "tests-portable-serial",
    "tests-herdr",
):
    steps = ci["jobs"][job_id]["steps"]
    assert required_tool_step in steps, (job_id, steps)

serial = ci["jobs"]["tests-portable-serial"]
assert serial["strategy"]["fail-fast"] is False
assert serial["strategy"]["matrix"]["shard"] == [1, 2, 3, 4]
assert ci["jobs"]["tests-timing-aggregate"]["needs"] == [
    "tests-portable-parallel-1",
    "tests-portable-parallel-2",
    "tests-portable-serial",
    "tests-herdr",
]

assert fallback_job["runs-on"] == labels
assert fallback_job["name"] == "Suite"
assert fallback_job["timeout-minutes"] == 120
assert required_job["runs-on"] == hosted_label
assert required_job["timeout-minutes"] == required_timeout
for forbidden in ("self-hosted", "water-7"):
    assert forbidden not in str(required_job["runs-on"]), forbidden

for job in (fallback_job, required_job):
    assert "strategy" not in job
    assert job.get("continue-on-error") is None

normalize = lambda value: " ".join(value.split())
fallback_admission = (
    "(github.event_name == 'workflow_run' && "
    "github.event.workflow_run.conclusion == 'failure' && "
    "github.event.workflow_run.head_repository.full_name == github.repository) || "
    "github.event_name == 'workflow_dispatch'"
)
required_admission = (
    "github.event.pull_request.head.repo.full_name == github.repository && "
    "github.event.pull_request.user.login != 'github-actions[bot]' && "
    "github.event.pull_request.user.login != 'dependabot[bot]'"
)
assert normalize(fallback_job["if"]) == fallback_admission
assert normalize(required_job["if"]) == required_admission

fallback_on = fallback.get(True, fallback.get("on"))
assert fallback_on["workflow_run"] == {
    "workflows": ["CI"],
    "types": ["completed"],
}
assert "workflow_dispatch" in fallback_on

def fallback_admitted(event_name, repository, conclusion=None, head_repository=None):
    return event_name == "workflow_dispatch" or (
        event_name == "workflow_run"
        and conclusion == "failure"
        and head_repository == repository
    )

repository = "pedromuller-del/firstmate"
assert fallback_admitted("workflow_run", repository, "failure", repository)
assert not fallback_admitted("workflow_run", repository, "success", repository)
assert not fallback_admitted("workflow_run", repository, "failure", "contributor/firstmate")
assert fallback_admitted("workflow_dispatch", repository)

assert fallback_job["env"] == {
    "LC_ALL": "C",
    "LANG": "C",
    "GIT_AUTHOR_NAME": "Firstmate CI",
    "GIT_AUTHOR_EMAIL": "firstmate-ci@users.noreply.github.com",
    "GIT_COMMITTER_NAME": "Firstmate CI",
    "GIT_COMMITTER_EMAIL": "firstmate-ci@users.noreply.github.com",
}
assert len(fallback_job["steps"]) == 4
checkout, admission, command, verdict = fallback_job["steps"]
assert checkout["uses"] == "actions/checkout@v6"
assert checkout["with"]["fetch-depth"] == 0
assert checkout["with"]["persist-credentials"] is False
assert checkout["with"]["ref"] == "${{ github.event.workflow_run.head_sha || github.sha }}"
assert admission["run"] == 'bin/fm-ci-load-guard.sh wait --max-load "$FM_CI_MAX_LOAD" --timeout 900 --poll 15'
assert command["run"] == "bin/fm-ci.sh"
assert "env" not in command
assert verdict["if"] == "always()"
assert verdict["run"] == 'bin/fm-ci-load-guard.sh check --max-load "$FM_CI_MAX_LOAD"'

required_runs = [step["run"] for step in required_job["steps"] if "run" in step]
assert len(required_runs) == 1
assert "${{" not in required_runs[0]
assert "Updates from [git push no-mistakes]" in required_runs[0]

# The hosted body-compliance lane stays checkout-free and independent.
required_uses = [step.get("uses") for step in required_job["steps"] if "uses" in step]
assert required_uses == [], required_uses
fallback_uses = [step.get("uses") for step in fallback_job["steps"] if "uses" in step]
assert fallback_uses == ["actions/checkout@v6"], fallback_uses

# The fallback never weakens failures or reaches outside this repository.
for step in fallback_job["steps"]:
    assert step.get("continue-on-error") is None
    if "uses" in step:
        assert step["uses"] == "actions/checkout@v6", step["uses"]
    delivered = [step.get("run", "")]
    delivered.extend(str(value) for value in (step.get("env") or {}).values())
    for text in delivered:
        for forbidden in ("GITHUB_PATH", "GITHUB_ENV", "kunchenguid/firstmate"):
            assert forbidden not in text, forbidden
for step in required_job["steps"]:
    assert step.get("continue-on-error") is None
    assert "uses" not in step
    delivered = [step.get("run", "")]
    delivered.extend(str(value) for value in (step.get("env") or {}).values())
    for text in delivered:
        for forbidden in ("GITHUB_PATH", "GITHUB_ENV", "kunchenguid/firstmate"):
            assert forbidden not in text, forbidden
PY
  then
    fail "workflow routing or command policy contract failed"
  fi
  pass "hosted slim CI is primary and the self-hosted suite is a failure/manual fallback"
}

test_herdr_installer_matches_the_presentation_floor() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-herdr-installer-floor)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/destination"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'x86_64\n' ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" > "$FM_TEST_CURL_URL"
cat > "$out" <<'HERDR'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  '--version ') printf 'herdr 0.8.0\n' ;;
  'status --json') printf '{"client":{"version":"0.8.0","protocol":19}}\n' ;;
  *) exit 2 ;;
esac
HERDR
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf 'b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28  %s\n' "$1"
SH
  chmod +x "$fakebin/uname" "$fakebin/curl" "$fakebin/sha256sum"

  out=$(PATH="$fakebin:$PATH" FM_TEST_CURL_URL="$tmp/url" \
    "$ROOT/bin/fm-install-herdr.sh" "$destination" 2>&1) \
    || fail "Herdr installer did not install the presentation-floor release"$'\n'"$out"
  [ "$(cat "$tmp/url")" = \
    "https://github.com/ogulcancelik/herdr/releases/download/v0.8.0/herdr-linux-x86_64" ] \
    || fail "Herdr installer did not download the exact presentation-floor release"
  assert_contains "$out" "installed herdr 0.8.0 (protocol 19)" \
    "Herdr installer did not verify the presentation-floor version and protocol"
  [ "$("$destination/herdr" --version)" = "herdr 0.8.0" ] \
    || fail "installed Herdr binary did not preserve the exact version pin"
  pass "Herdr installer pins the release that satisfies the presentation protocol floor"
}

test_body_compliance_command_distinguishes_signed_from_unsigned_bodies() {
  local script out rc tmp fakebin
  if ! script=$(python3 - "$ROOT" <<'PY'
import pathlib
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(2)

root = pathlib.Path(sys.argv[1])
required = yaml.safe_load(
    (root / ".github/workflows/no-mistakes-required.yml").read_text()
)
runs = [
    step["run"]
    for step in required["jobs"]["check"]["steps"]
    if "run" in step
]
assert len(runs) == 1
print(runs[0], end="")
PY
  ); then
    fail "could not load the body-compliance delivered command from workflow YAML"
  fi

  marker='## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"abc123","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'

  out=$(cd "$ROOT" && PR_BODY="$marker" PR_AUTHOR=test PR_NUMBER=42 PR_HEAD_SHA=abc123 bash -c "$script" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 0 ] || fail "signed no-mistakes PR body was rejected: rc=$rc out=$out"
  assert_contains "$out" "Found no-mistakes signature in PR #42 body."

  marker='## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":2222,"steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'
  rc=0
  out=$(cd "$ROOT" && PR_BODY="$marker" PR_AUTHOR=test PR_NUMBER=45 PR_HEAD_SHA=2222 bash -c "$script" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "workflow accepted a numeric head_sha matching the textual PR head: rc=$rc out=$out"
  assert_contains "$out" "not bound to this pull request head" \
    "workflow non-string head_sha failure was not explicit"

  marker='## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"abc123","steps":[{"step":"review","status":"completed"},{"step":"review","status":"failed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'
  rc=0
  out=$(cd "$ROOT" && PR_BODY="$marker" PR_AUTHOR=test PR_NUMBER=43 PR_HEAD_SHA=abc123 bash -c "$script" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "workflow accepted duplicate attestation steps: rc=$rc out=$out"
  assert_contains "$out" "duplicate step names" \
    "workflow duplicate-step failure was not explicit"

  marker='## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"abc123","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"},{"status":"completed"}]} -->'
  rc=0
  out=$(cd "$ROOT" && PR_BODY="$marker" PR_AUTHOR=test PR_NUMBER=44 PR_HEAD_SHA=abc123 bash -c "$script" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "workflow accepted a malformed attestation step: rc=$rc out=$out"
  assert_contains "$out" "malformed steps member" \
    "workflow malformed-step failure was not explicit"

  tmp=$(fm_test_tmproot fm-ci-water7-unsigned)
  fakebin="$tmp/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/gh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/sleep"
  chmod +x "$fakebin/gh" "$fakebin/sleep"
  out=$(PATH="$fakebin:$PATH" GITHUB_REPOSITORY=pedromuller-del/firstmate \
    PR_BODY='manual PR without the signature' PR_AUTHOR=test PR_NUMBER=7 \
    bash -c "$script" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || fail "unsigned PR body was accepted: rc=$rc out=$out"
  assert_contains "$out" "::error::This PR was not raised through no-mistakes."

  pass "body-compliance command accepts signed PR bodies and rejects unsigned ones"
}

test_body_compliance_polls_live_pr_body_when_opened_payload_is_stale() {
  local script fakebin tmp out rc
  tmp=$(fm_test_tmproot fm-ci-water7-opened-race)
  if ! script=$(python3 - "$ROOT" <<'PY'
import pathlib
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(2)

root = pathlib.Path(sys.argv[1])
required = yaml.safe_load(
    (root / ".github/workflows/no-mistakes-required.yml").read_text()
)
runs = [
    step["run"]
    for step in required["jobs"]["check"]["steps"]
    if "run" in step
]
assert len(runs) == 1
print(runs[0], end="")
PY
  ); then
    fail "workflow must poll the live PR body before declaring a signature violation"
  fi

  marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
  attestation='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"abc123","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'
  fakebin="$tmp/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = api ] && [ "\$2" = repos/pedromuller-del/firstmate/pulls/88 ] && [ "\$3" = --jq ] && [ "\$4" = .body ]; then
  printf '%s\n%s' 'live body with ${marker}' '${attestation}'
  exit 0
fi
echo "unexpected gh call: \$*" >&2
exit 1
EOF
  chmod +x "$fakebin/gh"

  rc=0
  out=$(
    cd "$ROOT" && \
      PATH="$fakebin:$PATH" \
      GITHUB_REPOSITORY=pedromuller-del/firstmate \
      PR_BODY='opened-event snapshot without the signature yet' \
      PR_AUTHOR=test \
      PR_NUMBER=88 \
      PR_HEAD_SHA=abc123 \
      bash -c "$script" 2>&1
  ) || rc=$?
  [ "$rc" -eq 0 ] || fail "stale opened payload should pass after live poll: rc=$rc out=$out"
  assert_contains "$out" "Live PR body includes the no-mistakes signature"
  assert_contains "$out" "Found no-mistakes signature in PR #88 body."
  pass "body-compliance polls the live PR body when the opened event payload is stale"
}

make_policy_fixture() {
  local repo=$1 fakebin=$2 command_name
  mkdir -p "$repo/bin/backends" "$repo/.claude" "$fakebin"
  cp "$ROOT/bin/fm-ci.sh" "$repo/bin/fm-ci.sh"
  cp "$ROOT/bin/fm-backend.sh" "$repo/bin/fm-backend.sh"
  cp "$ROOT/bin/backends/herdr.sh" "$repo/bin/backends/herdr.sh"
  cp "$ROOT/bin/fm-install-chrome.sh" "$repo/bin/fm-install-chrome.sh"
  cp "$ROOT/bin/fm-composer-lib.sh" "$repo/bin/fm-composer-lib.sh"
  cp "$ROOT/bin/fm-transition-lib.sh" "$repo/bin/fm-transition-lib.sh"
  chmod +x "$repo/bin/fm-ci.sh"
  printf '%s\n' \
    '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->' \
    '@AGENTS.md' > "$repo/CLAUDE.md"
  ln -s ../.agents/skills "$repo/.claude/skills"
  : > "$repo/AGENTS.md"

  cat > "$repo/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --required-version) echo 0.11.0 ;;
  --list-files) printf '%s\n' bin/fm-ci.sh ;;
  *)
    printf 'lint\n' >> "$FM_CI_CALLS"
    printf 'FM_LINT_JOBS=%s\n' "${FM_LINT_JOBS:-unset}" >> "$FM_CI_LINT_ENV"
    ;;
esac
SH
  cat > "$repo/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'test-run %s\n' "$*" >> "$FM_CI_CALLS"
if [ "${1:-}" = --list-lanes ]; then
  printf '%s\n' \
    portable-parallel-1 \
    portable-parallel-2 \
    portable-serial \
    portable-serial-1of4 \
    portable-serial-2of4 \
    portable-serial-3of4 \
    portable-serial-4of4 \
    real-herdr-gated
  exit 0
fi
printf 'SHELL=%s|HERDR_SESSION=%s|FM_HERDR_LAB_PROTECTED_SESSION=%s\n' \
  "${SHELL:-}" "${HERDR_SESSION:-}" "${FM_HERDR_LAB_PROTECTED_SESSION:-}" >> "$FM_CI_SUITE_ENV"
printf 'FM_CHROME_BIN=%s\n' "${FM_CHROME_BIN:-}" >> "$FM_CI_SUITE_ENV"
json=
aggregate=
aggregate_inputs=()
selection=
gate_skip=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json=$2; shift 2; continue ;;
    --aggregate-json) aggregate=$2; shift 2; continue ;;
    --lane) selection="lane=$2"; shift 2; continue ;;
    --family) selection="family=$2"; shift 2; continue ;;
    --changed) selection=changed; shift; continue ;;
    --fail-on-gate-skip) gate_skip=$2; shift 2; continue ;;
  esac
  [ -n "$aggregate" ] && aggregate_inputs+=("$1")
  shift
done
[ -z "$gate_skip" ] || selection="$selection;fail-on-gate-skip=$gate_skip"
if [ -n "$aggregate" ]; then
  # The real owner refuses an unusable input with one concise line and a
  # non-zero status, so the fixture must too: a fake that exits 0 after a
  # failed merge would hide the boundary bin/fm-ci.sh relies on.
  for input in "${aggregate_inputs[@]}"; do
    [ -f "$input" ] || {
      printf 'fm-test-run: aggregate input not found: %s\n' "$input" >&2
      exit 2
    }
  done
  python3 - "$aggregate" "${aggregate_inputs[@]}" <<'PY'
import json, sys
out, *inputs = sys.argv[1:]
lanes = []
slowest = []
for path in inputs:
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"fm-test-run: aggregate input is not valid timing JSON: {path}: {exc}\n")
        raise SystemExit(2)
    lanes.append({"selection": doc["selection"], "summary": doc["summary"]})
    slowest.extend(doc.get("scripts", []))
slowest.sort(key=lambda row: (-row["duration_ms"], row["path"]))
with open(out, "w", encoding="utf-8") as fh:
    json.dump({"lanes": lanes, "slowest": slowest[:15]}, fh)
PY
  exit $?
fi
# Keyed off the selection this run actually received, never off the artifact
# name, so a lane label that disagrees with its selection shows up as a wrong
# total in the published report.
case "$selection" in
  lane=portable-parallel-1) duration=101; start=1 ;;
  lane=portable-parallel-2) duration=202; start=4 ;;
  lane=portable-serial-1of4) duration=301; start=7 ;;
  lane=portable-serial-2of4) duration=302; start=10 ;;
  lane=portable-serial-3of4) duration=303; start=13 ;;
  lane=portable-serial-4of4) duration=304; start=16 ;;
  'family=real-herdr-gated;fail-on-gate-skip=herdr not found') duration=404; start=19 ;;
  *) duration=0; start=1 ;;
esac
failed=0
if [ -n "${FM_TEST_LANE_SUITE_FAIL:-}" ] && [ "$FM_TEST_LANE_SUITE_FAIL" = "$selection" ]; then
  failed=1
fi
if [ -n "$json" ]; then
  # The real runner contains an unwritable artifact and still exits on its own
  # suite verdict, so the fixture must not fail the lane for one either.
  if [ -n "${FM_TEST_LANE_ARTIFACT_FAIL:-}" ] && [ "$FM_TEST_LANE_ARTIFACT_FAIL" = "$selection" ]; then
    printf 'fm-test-run: could not write timing artifact: %s\n' "$json" >&2
    [ "$failed" -eq 0 ] || exit 1
    exit 0
  fi
  python3 - "$json" "$selection" "$duration" "$start" <<'PY'
import json, sys
out, selection, duration, start = sys.argv[1:]
scripts = [{"path": f"tests/test-{i}.test.sh", "duration_ms": i} for i in range(int(start), int(start) + 3)]
with open(out, "w", encoding="utf-8") as fh:
    json.dump({"selection": selection, "summary": {"duration_ms": int(duration)}, "scripts": scripts}, fh)
PY
fi
[ "$failed" -eq 0 ] || exit 1
SH
  chmod +x "$repo"/bin/*.sh

  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
cat <<EOF
LoadState=loaded
ActiveState=active
SubState=running
UnitFileState=enabled
User=fm-ci-runner
CPUQuotaPerSecUSec=${FM_TEST_CPU_QUOTA:-6s}
MemoryMax=infinity
TasksMax=${FM_TEST_TASKS_MAX:-16854}
LimitNOFILE=524288
LimitNOFILESoft=1024
EOF
SH
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >> "$FM_CI_HERDR_CALLS"
case "$1 ${2:-}" in
  '--version ') printf '%s\n' 'herdr 0.8.0' ;;
  'status --json')
    running=${FM_TEST_HERDR_RUNNING:-true}
    [ ! -e "$FM_TEST_HERDR_STATE" ] || running=true
    printf '{"client":{"version":"0.8.0","protocol":19},"server":{"running":%s}}\n' "$running"
    ;;
  'server --session') : > "$FM_TEST_HERDR_STATE" ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
SH
  mkdir -p "$fakebin.install"
  cp "$fakebin/herdr" "$fakebin.install/herdr"
  cp "$fakebin/shellcheck" "$fakebin.install/shellcheck"
  cat > "$repo/bin/fm-install-shellcheck.sh" <<'SH'
#!/usr/bin/env bash
printf 'shellcheck\n' >> "$FM_CI_INSTALL_CALLS"
install -m 0755 "$FM_TEST_INSTALL_FIXTURES/shellcheck" "$1/shellcheck"
SH
  cat > "$repo/bin/fm-install-herdr.sh" <<'SH'
#!/usr/bin/env bash
printf 'herdr\n' >> "$FM_CI_INSTALL_CALLS"
install -m 0755 "$FM_TEST_INSTALL_FIXTURES/herdr" "$1/herdr"
SH
cat > "$repo/bin/fm-install-chrome.sh" <<'SH'
#!/usr/bin/env bash
printf 'chrome\n' >> "$FM_CI_INSTALL_CALLS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$1/chrome"
chmod +x "$1/chrome"
printf '%s/chrome\n' "$1"
SH
  chmod +x "$repo/bin/fm-install-shellcheck.sh" "$repo/bin/fm-install-herdr.sh" "$repo/bin/fm-install-chrome.sh"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'var GIT_AUTHOR_IDENT') printf '%s <%s> 0 +0000\n' "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" ;;
  'ls-files --') exit 0 ;;
  *) exec /usr/bin/git "$@" ;;
esac
SH
  for command_name in tmux rg tasks-axi treehouse dpkg-deb; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$command_name"
  done
  chmod +x "$fakebin"/*
}

run_policy_fixture() {
  local repo=$1 fakebin=$2 calls=$3
  local policy_env=()
  # Scrub every ambient input the policy itself reads - the Herdr selection,
  # the workflow's fast-lane base, and the job-summary metadata a real Water 7
  # step exports - so each test states the environment it is proving, not what
  # the surrounding shell or CI job happened to export.
  [ -z "${FM_TEST_STEP_SUMMARY:-}" ] \
    || policy_env+=("GITHUB_STEP_SUMMARY=$FM_TEST_STEP_SUMMARY")
  [ -z "${FM_TEST_RUN_ID:-}" ] || policy_env+=("GITHUB_RUN_ID=$FM_TEST_RUN_ID")
  [ -z "${FM_TEST_FAST_LANE_BASE:-}" ] \
    || policy_env+=("FM_CI_FAST_LANE_BASE=$FM_TEST_FAST_LANE_BASE")
  env -u HERDR_SESSION -u FM_HERDR_LAB_PROTECTED_SESSION \
    -u FM_CHROME_BIN -u FM_LINT_JOBS \
    -u GITHUB_STEP_SUMMARY -u GITHUB_RUN_ID -u FM_CI_FAST_LANE_BASE \
    "${policy_env[@]+"${policy_env[@]}"}" \
    PATH="$fakebin:$PATH" \
    FM_CI_CALLS="$calls" \
    FM_CI_LINT_ENV="$calls.lint-env" \
    FM_CI_SUITE_ENV="$calls.suite-env" \
    FM_CI_INSTALL_CALLS="$calls.install" \
    FM_CI_HERDR_CALLS="$calls.herdr" \
    FM_TEST_INSTALL_FIXTURES="$fakebin.install" \
    FM_TEST_HERDR_STATE="$calls.herdr-running" \
    GITHUB_ACTIONS=true \
    RUNNER_NAME=water-7 \
    RUNNER_OS=Linux \
    RUNNER_ARCH=X64 \
    GITHUB_REPOSITORY=pedromuller-del/firstmate \
    RUNNER_TEMP="$(dirname "$calls")" \
    SHELL=/usr/sbin/nologin \
    LC_ALL=C LANG=C \
    GIT_AUTHOR_NAME='Firstmate CI' \
    GIT_AUTHOR_EMAIL=firstmate-ci@users.noreply.github.com \
    GIT_COMMITTER_NAME='Firstmate CI' \
    GIT_COMMITTER_EMAIL=firstmate-ci@users.noreply.github.com \
    "$repo/bin/fm-ci.sh"
}

test_policy_runs_every_family_serially() {
  local tmp repo fakebin calls expected
  tmp=$(fm_test_tmproot fm-ci-water7)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  FM_CI_FAST_LANE_BASE='' run_policy_fixture "$repo" "$fakebin" "$calls" \
    || fail "Water 7 command policy rejected its valid host fixture"
  expected=$(cat <<'EOF'
lint
test-run --check-coverage
test-run --jobs 2 --lane portable-parallel-1
test-run --lane portable-parallel-2
test-run --list-lanes
test-run --lane portable-serial-1of4
test-run --lane portable-serial-2of4
test-run --lane portable-serial-3of4
test-run --lane portable-serial-4of4
test-run --family real-herdr-gated --fail-on-gate-skip herdr not found
EOF
)
  [ "$(cat "$calls")" = "$expected" ] \
    || fail "Water 7 command policy changed its complete serial order: $(cat "$calls")"
  pass "the command owner runs lint, coverage, portable-parallel-1 with --jobs 2, serial remainder lanes, then real Herdr"
}

test_policy_requires_a_regular_claude_pointer() {
  local tmp repo fakebin calls out rc
  tmp=$(fm_test_tmproot fm-ci-water7-pointer)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  rm "$repo/CLAUDE.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  rc=0
  out=$(run_policy_fixture "$repo" "$fakebin" "$calls" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Water 7 command policy accepted a CLAUDE.md symlink"
  assert_contains "$out" 'CLAUDE.md must be a regular @AGENTS.md pointer' \
    "symlink refusal did not name the regular pointer contract"
  [ ! -e "$calls" ] || fail "an invalid CLAUDE.md pointer reached the test suite"

  rm "$repo/CLAUDE.md"
  printf '%s\n' '@OTHER.md' > "$repo/CLAUDE.md"
  rc=0
  out=$(run_policy_fixture "$repo" "$fakebin" "$calls" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Water 7 command policy accepted a non-canonical pointer"
  assert_contains "$out" 'CLAUDE.md must contain the canonical @AGENTS.md pointer' \
    "non-canonical pointer refusal did not name the exact pointer contract"
  pass "the command owner requires CLAUDE.md to be a regular canonical pointer"
}

test_workflow_invariant_step_executes_the_regular_claude_pointer_contract() {
  local tmp repo command out rc
  tmp=$(fm_test_tmproot fm-ci-workflow-pointer)
  repo="$tmp/repo"
  mkdir -p "$repo/.claude" "$repo/.agents/skills"
  printf '%s\n' 'Project memory.' > "$repo/AGENTS.md"
  printf '%s\n' \
    '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->' \
    '@AGENTS.md' > "$repo/CLAUDE.md"
  ln -s ../.agents/skills "$repo/.claude/skills"
  git -C "$repo" init -q
  command=$(python3 - "$ROOT/.github/workflows/ci.yml" <<'PY'
import sys
import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = workflow["jobs"]["invariants"]["steps"]
print(next(step["run"] for step in steps if step.get("name") == "Compatibility pointers must stay intact"), end="")
PY
  ) || fail "could not extract the hosted invariant step"
  out=$(cd "$repo" && bash -c "$command" 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 0 ] || fail "hosted invariant step rejected the canonical pointer: rc=$rc out=$out"

  rm "$repo/CLAUDE.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  rc=0
  out=$(cd "$repo" && bash -c "$command" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "hosted invariant step accepted a CLAUDE.md symlink"
  assert_contains "$out" 'CLAUDE.md must be a regular @AGENTS.md pointer' \
    "hosted symlink refusal did not name the regular pointer contract"

  rm "$repo/CLAUDE.md"
  printf '%s\n' '@OTHER.md' > "$repo/CLAUDE.md"
  rc=0
  out=$(cd "$repo" && bash -c "$command" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "hosted invariant step accepted a non-canonical pointer"
  assert_contains "$out" 'CLAUDE.md must contain the canonical @AGENTS.md pointer' \
    "hosted non-canonical pointer refusal did not name the exact pointer contract"
  pass "the hosted invariant step executes the regular canonical CLAUDE.md pointer contract"
}

test_policy_publishes_nonblocking_timing_summary() {
  local tmp repo fakebin calls summary
  tmp=$(fm_test_tmproot fm-ci-water7-summary)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  summary="$tmp/summary.md"
  make_policy_fixture "$repo" "$fakebin"
  FM_TEST_STEP_SUMMARY="$summary" FM_TEST_RUN_ID=9876 run_policy_fixture "$repo" "$fakebin" "$calls" \
    || fail "Water 7 command policy rejected its valid summary fixture"
  assert_contains "$(cat "$summary")" '| portable-parallel-1 | 101 ms |' \
    "summary omitted the first lane timing"
  assert_contains "$(cat "$summary")" '| real-herdr-gated | 404 ms |' \
    "summary omitted the Herdr lane timing"
  [ "$(grep -c '^| [0-9][0-9]* | tests/test-' "$summary")" -eq 10 ] \
    || fail "summary did not contain exactly ten slowest tests"
  assert_contains "$(cat "$summary")" 'Tool bootstrap:' "summary omitted tool bootstrap timing"
  assert_contains "$(cat "$summary")" 'GitHub run id: 9876' "summary omitted the GitHub run id"
  assert_contains "$(cat "$calls")" 'test-run --aggregate-json' \
    "summary did not use the existing aggregate timing owner"
  # The job summary is generated GitHub-Flavored Markdown, so assert its block
  # structure rather than bare substrings: a table only ends at a blank line, so
  # a bootstrap or run-id line without one renders as another lane row.
  python3 - "$summary" <<'PY' || fail "the published summary is not a well-formed GFM timing report"
import sys

blocks = [
    block.splitlines()
    for block in open(sys.argv[1], encoding="utf-8").read().split("\n\n")
    if block.strip()
]
tables = [block for block in blocks if block[0].startswith("|")]
assert len(tables) == 2, blocks

lanes, slowest = tables
assert lanes[0].split("|")[1:3] == [" Lane ", " Total "], lanes[0]
lane_rows = lanes[2:]
assert [row.split("|")[1].strip() for row in lane_rows] == [
    "portable-parallel-1",
    "portable-parallel-2",
    "portable-serial-1of4",
    "portable-serial-2of4",
    "portable-serial-3of4",
    "portable-serial-4of4",
    "real-herdr-gated",
], lane_rows
assert [row.split("|")[2].strip() for row in lane_rows] == [
    "101 ms",
    "202 ms",
    "301 ms",
    "302 ms",
    "303 ms",
    "304 ms",
    "404 ms",
], lane_rows
assert len(slowest[2:]) == 10, slowest

facts = [line for block in blocks if not block[0].startswith("|") for line in block]
bootstrap = [line for line in facts if line.startswith("Tool bootstrap: ")]
assert len(bootstrap) == 1, facts
assert bootstrap[0].split()[2].isdigit() and bootstrap[0].endswith(" ms"), bootstrap
assert [line for line in facts if line == "GitHub run id: 9876"], facts
PY
  pass "Water 7 publishes the compact lane timing summary"
}

test_policy_publishes_the_summary_without_github_run_metadata() {
  local tmp repo fakebin calls summary
  tmp=$(fm_test_tmproot fm-ci-water7-summary-no-run-id)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  summary="$tmp/summary.md"
  make_policy_fixture "$repo" "$fakebin"
  # A summary file with no GITHUB_RUN_ID beside it: the report still publishes
  # and names the missing metadata rather than emitting a blank or partial run.
  FM_TEST_STEP_SUMMARY="$summary" run_policy_fixture "$repo" "$fakebin" "$calls" \
    || fail "Water 7 command policy rejected a run without GitHub run metadata"
  python3 - "$summary" <<'PY' || fail "the report lost its shape when GitHub run metadata was absent"
import sys

blocks = [
    block.splitlines()
    for block in open(sys.argv[1], encoding="utf-8").read().split("\n\n")
    if block.strip()
]
lanes, slowest = [block for block in blocks if block[0].startswith("|")]
assert [row.split("|")[1].strip() for row in lanes[2:]] == [
    "portable-parallel-1",
    "portable-parallel-2",
    "portable-serial-1of4",
    "portable-serial-2of4",
    "portable-serial-3of4",
    "portable-serial-4of4",
    "real-herdr-gated",
], lanes
assert len(slowest[2:]) == 10, slowest
facts = [line for block in blocks if not block[0].startswith("|") for line in block]
assert [line for line in facts if line.startswith("Tool bootstrap: ")], facts
assert [line for line in facts if line.startswith("GitHub run id: ")] == [
    "GitHub run id: unavailable"
], facts
PY
  pass "the summary names absent GitHub run metadata instead of publishing a blank"
}

test_policy_summary_failure_does_not_fail_delivery() {
  local tmp repo fakebin calls summary rc
  tmp=$(fm_test_tmproot fm-ci-water7-summary-failure)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  summary="$tmp/summary-dir"
  mkdir "$summary"
  make_policy_fixture "$repo" "$fakebin"
  rc=0
  out=$(FM_TEST_STEP_SUMMARY="$summary" run_policy_fixture "$repo" "$fakebin" "$calls" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an optional summary write failure wedged the policy"
  assert_contains "$out" 'fm-ci: could not publish optional GitHub step summary' \
    "the failing publish path did not report that it stepped aside"
  assert_contains "$out" "fm-ci: could not write the GitHub step summary $summary" \
    "the publish failure discarded the evidence naming what could not be written"
  assert_not_contains "$out" 'Traceback (most recent call last)' \
    "the publish failure dumped a Python traceback into an otherwise green job log"
  assert_contains "$(cat "$calls")" 'test-run --family real-herdr-gated' \
    "the policy did not finish its lanes before the optional summary failed"
  pass "Water 7 steps aside when optional summary publication fails"
}

test_policy_delivers_when_a_lane_timing_artifact_cannot_be_written() {
  local tmp repo fakebin calls summary out rc
  tmp=$(fm_test_tmproot fm-ci-water7-artifact-failure)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  summary="$tmp/summary.md"
  make_policy_fixture "$repo" "$fakebin"
  rc=0
  out=$(FM_TEST_STEP_SUMMARY="$summary" FM_TEST_RUN_ID=9876 \
    FM_TEST_LANE_ARTIFACT_FAIL=lane=portable-serial-2of4 \
    run_policy_fixture "$repo" "$fakebin" "$calls" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an optional lane timing artifact failure wedged a green policy: $out"
  assert_contains "$out" 'could not write timing artifact' \
    "the lost optional timing artifact was not reported by the lane that lost it"
  assert_contains "$out" 'fm-ci: could not publish optional GitHub step summary' \
    "the policy did not report that it stepped aside from an incomplete lane set"
  assert_not_contains "$out" 'Traceback (most recent call last)' \
    "an incomplete lane set dumped a Python traceback into an otherwise green job log"
  assert_contains "$(cat "$calls")" 'test-run --family real-herdr-gated' \
    "a lost optional timing artifact stopped the remaining lanes"
  [ ! -s "$summary" ] \
    || fail "the report was published from an incomplete lane set: $(cat "$summary")"
  pass "a lane that loses its optional timing artifact still delivers its green verdict"
}

test_policy_fails_when_a_lane_suite_fails_under_the_summary() {
  local tmp repo fakebin calls summary out rc
  tmp=$(fm_test_tmproot fm-ci-water7-lane-failure)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  summary="$tmp/summary.md"
  make_policy_fixture "$repo" "$fakebin"
  rc=0
  out=$(FM_TEST_STEP_SUMMARY="$summary" FM_TEST_RUN_ID=9876 \
    FM_TEST_LANE_SUITE_FAIL=lane=portable-parallel-2 \
    run_policy_fixture "$repo" "$fakebin" "$calls" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the optional timing path swallowed a failing lane suite: $out"
  assert_not_contains "$(cat "$calls")" 'test-run --lane portable-serial' \
    "the policy continued past a failing lane"
  [ ! -s "$summary" ] \
    || fail "a failing lane still published a timing report: $(cat "$summary")"
  pass "a failing lane suite still fails the policy while the summary is enabled"
}

test_policy_runs_lint_serially() {
  local tmp repo fakebin calls
  tmp=$(fm_test_tmproot fm-ci-water7-serial-lint)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  run_policy_fixture "$repo" "$fakebin" "$calls" \
    || fail "Water 7 command policy rejected its valid host fixture"
  [ "$(cat "$calls.lint-env")" = "FM_LINT_JOBS=1" ] \
    || fail "the CI path did not invoke lint through the lint owner's serial mode: $(cat "$calls.lint-env")"
  pass "the command owner runs lint serially to bound concurrent ShellCheck memory"
}

test_policy_runs_pr_fast_lane_before_complete_suite() {
  local tmp repo fakebin calls expected
  tmp=$(fm_test_tmproot fm-ci-water7-fast-lane)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  FM_TEST_FAST_LANE_BASE=base-sha run_policy_fixture "$repo" "$fakebin" "$calls" \
    || fail "Water 7 command policy rejected its valid PR fast-lane fixture"
  expected=$(cat <<'EOF'
lint
test-run --check-coverage
test-run --changed --base base-sha --fail-on-gate-skip herdr not found
test-run --jobs 2 --lane portable-parallel-1
test-run --lane portable-parallel-2
test-run --list-lanes
test-run --lane portable-serial-1of4
test-run --lane portable-serial-2of4
test-run --lane portable-serial-3of4
test-run --lane portable-serial-4of4
test-run --family real-herdr-gated --fail-on-gate-skip herdr not found
EOF
)
  [ "$(cat "$calls")" = "$expected" ] \
    || fail "PR fast lane was not run before the complete serial merge gate: $(cat "$calls")"
  pass "the PR fast lane reports before the complete serial merge gate"
}

test_policy_refuses_semantically_unsafe_systemd_limits() {
  local tmp repo fakebin calls out rc
  tmp=$(fm_test_tmproot fm-ci-water7-limits)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  rc=0
  out=$(FM_TEST_TASKS_MAX=32 run_policy_fixture "$repo" "$fakebin" "$calls" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Water 7 command policy accepted TasksMax=32"
  assert_contains "$out" "TasksMax must be at least 512" \
    "systemd limit refusal did not name the semantic TasksMax boundary"
  [ ! -e "$calls" ] || fail "unsafe systemd limits reached the test suite"
  pass "the command owner refuses unsafe semantic systemd limits before tests"
}

test_policy_refuses_a_cpu_quota_below_its_own_concurrency() {
  local tmp repo fakebin calls out rc
  tmp=$(fm_test_tmproot fm-ci-water7-cpu)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  rc=0
  out=$(FM_TEST_CPU_QUOTA=1s run_policy_fixture "$repo" "$fakebin" "$calls" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Water 7 command policy accepted CPUQuotaPerSecUSec=1s while running --jobs 2"
  assert_contains "$out" "CPUQuotaPerSecUSec must be at least 2" \
    "CPU quota refusal did not name the concurrency boundary the policy depends on"
  [ ! -e "$calls" ] || fail "a CPU quota below the policy's own concurrency reached the test suite"
  pass "the command owner refuses a CPU quota that cannot serve its own --jobs 2 lane"
}

test_policy_refuses_a_missing_test_dependency() {
  local tmp repo fakebin calls out rc
  tmp=$(fm_test_tmproot fm-ci-water7-dependency)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  rm -f "$fakebin/rg"
  fm_test_hide_host_commands "$fakebin" rg
  rc=0
  out=$(run_policy_fixture "$repo" "$fakebin" "$calls" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Water 7 command policy ran without ripgrep"
  assert_contains "$out" "rg is required on Water 7" \
    "missing dependency refusal did not name ripgrep"
  [ ! -e "$calls" ] || fail "a missing test dependency reached the suite"
  pass "the command owner refuses before tests when a required host dependency is absent"
}

test_policy_uses_only_bounded_ci_bootstrap() {
  local tmp repo fakebin calls expected_shell herdr_calls install_calls suite_env
  tmp=$(fm_test_tmproot fm-ci-water7-readiness)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  FM_TEST_HERDR_RUNNING=false run_policy_fixture "$repo" "$fakebin" "$calls" \
    || fail "Water 7 command policy did not start its down dedicated controller"
  herdr_calls=$(cat "$calls.herdr")
  assert_contains "$herdr_calls" 'herdr server --session fm-ci-water7' \
    "down-controller bootstrap did not start the dedicated CI controller"
  assert_not_contains "$herdr_calls" 'default' \
    "bounded CI bootstrap touched the default Herdr session"
  assert_not_contains "$herdr_calls" 'session stop' \
    "bounded CI bootstrap stopped a Herdr session"
  assert_not_contains "$herdr_calls" 'server stop' \
    "bounded CI bootstrap stopped a Herdr server"
  assert_not_contains "$herdr_calls" 'session delete' \
    "bounded CI bootstrap deleted a Herdr session"

  : > "$calls.herdr"
  FM_TEST_HERDR_RUNNING=true run_policy_fixture "$repo" "$fakebin" "$calls" \
    || fail "Water 7 command policy rejected its already-running controller"
  herdr_calls=$(cat "$calls.herdr")
  assert_not_contains "$herdr_calls" 'herdr server ' \
    "already-running controller path started a second Herdr server"
  assert_not_contains "$herdr_calls" 'default' \
    "already-running controller path touched the default Herdr session"

  suite_env=$(sort -u < "$calls.suite-env")
  expected_shell=$(command -v bash)
  expected_suite_env=$(cat <<EOF
FM_CHROME_BIN=$(dirname "$calls")/fm-ci-tools/chrome
SHELL=$expected_shell|HERDR_SESSION=|FM_HERDR_LAB_PROTECTED_SESSION=fm-ci-water7
EOF
)
  [ "$suite_env" = "$expected_suite_env" ] \
    || fail "the suite did not inherit the usable Bash shell and explicit dedicated protected controller: $suite_env"

  tmp=$(fm_test_tmproot fm-ci-water7-installers)
  repo="$tmp/repo"
  fakebin="$tmp/fakebin"
  calls="$tmp/calls"
  make_policy_fixture "$repo" "$fakebin"
  sed 's/version: 0.11.0/version: 0.10.0/' "$fakebin/shellcheck" > "$fakebin/shellcheck.old"
  mv "$fakebin/shellcheck.old" "$fakebin/shellcheck"
  sed 's/herdr 0.8.0/herdr 0.7.5/' "$fakebin/herdr" > "$fakebin/herdr.old"
  mv "$fakebin/herdr.old" "$fakebin/herdr"
  chmod +x "$fakebin/shellcheck" "$fakebin/herdr"
  run_policy_fixture "$repo" "$fakebin" "$calls" \
    || fail "Water 7 command policy did not bootstrap its pinned tools"
  install_calls=$(cat "$calls.install")
  [ "$install_calls" = "shellcheck
herdr
chrome" ] || fail "bounded bootstrap did not use exactly the three tracked installers: $install_calls"
  pass "the command owner only starts its explicit dedicated controller when down"
}

test_workflows_use_hosted_slim_ci_with_a_self_hosted_fallback
test_herdr_installer_matches_the_presentation_floor
test_body_compliance_command_distinguishes_signed_from_unsigned_bodies
test_body_compliance_polls_live_pr_body_when_opened_payload_is_stale
test_workflow_invariant_step_executes_the_regular_claude_pointer_contract
test_policy_runs_every_family_serially
test_policy_requires_a_regular_claude_pointer
test_policy_runs_lint_serially
test_policy_runs_pr_fast_lane_before_complete_suite
test_policy_publishes_nonblocking_timing_summary
test_policy_publishes_the_summary_without_github_run_metadata
test_policy_summary_failure_does_not_fail_delivery
test_policy_delivers_when_a_lane_timing_artifact_cannot_be_written
test_policy_fails_when_a_lane_suite_fails_under_the_summary
test_policy_refuses_semantically_unsafe_systemd_limits
test_policy_refuses_a_cpu_quota_below_its_own_concurrency
test_policy_uses_only_bounded_ci_bootstrap
test_policy_refuses_a_missing_test_dependency
