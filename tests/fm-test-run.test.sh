#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of serial behavior
# suite selection, timing markers, JSON artifacts, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures and --list, not
# the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"
CI="$ROOT/.github/workflows/ci.yml"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh "$ROOT"/tests/*.test.py; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every behavior test once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh|tests/*.test.py) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-captain-translation-contract.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-no-mistakes-required-workflow.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-fleet-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/unmapped-source.sh"
  printf '# .agents/skills/example/SKILL.md\n' >>"$repo/tests/fm-captain-translation-contract.test.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
  mkdir -p "$repo/.github/workflows"
  printf 'baseline\n' > "$repo/.github/workflows/no-mistakes-required.yml"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  assert_contains "$listed" "tests/fm-fleet-snapshot.test.sh" "shared helper selects the fork's fleet snapshot contract"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf 'changed\n' >>"$repo/.github/workflows/no-mistakes-required.yml"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-no-mistakes-required-workflow.test.sh" \
    "required workflow changes must select semantic workflow replay"
  git -C "$repo" add .github/workflows/no-mistakes-required.yml
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm workflow-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-captain-translation-contract.test.sh" "skill source selects contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

test_empty_selection_emits_summary() {
  local tmp repo out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  [ "$out" = "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0" ] \
    || fail "empty selection summary is missing or non-deterministic: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"] == {"duration_ms": 0, "failed": 0, "skipped_gate": 0, "total": 0}
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f fakebin rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/tee" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 7
SH
  chmod +x "$fakebin/tee"
  set +e
  PATH="$fakebin:$PATH" "$RUNNER" "$pass_f" >"$tmp/out3.txt" 2>"$tmp/err3.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "runner must fail when evidence tee fails"; }
  grep -q 'could not retain output' "$tmp/err3.txt" \
    || { rm -rf "$tmp"; fail "runner did not report evidence tee failure"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_fail_on_any_gate_skip() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-any-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "diagnostic: preparing optional condition"
echo "ok - skip: optional condition"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-any-gate-skip "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-any-gate-skip must reject every gate skip"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-any-gate-skip"
  grep -q 'required gate reported a skip' "$tmp/err.txt" \
    || fail "runner must log the any-skip failure"
  rm -rf "$tmp"
  pass "fail-on-any-gate-skip scans every output line and converts every gate skip into failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-send-secondmate-marker-herdr-e2e.test.sh' \
    || fail "family real-herdr-gated must include credential-free marker/send coverage"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-eventwait.test.py' \
    || fail "family real-herdr-gated must include Python eventwait coverage"
  listed=$("$RUNNER" --list --all --exclude-family live-harness-optin)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-send-secondmate-marker-herdr-e2e.test.sh' \
    || fail "credential-free marker/send coverage must not remain live-harness opt-in"
  pass "exclude-family drops the named primary family after selection"
}

test_ci_and_docs_call_the_owner() {
  local ci_json config_json status
  ci_json=$(python3 "$ROOT/tests/workflow-contract.py" "$CI")
  config_json=$(python3 "$ROOT/tests/workflow-contract.py" "$ROOT/.no-mistakes.yaml")
  CI_JSON="$ci_json" python3 - <<'PY'
import json
import os
import shlex

ci = json.loads(os.environ["CI_JSON"])
def command_args(job, name):
    found = []
    for step in ci["jobs"][job].get("steps", []):
        run = step.get("run", "").replace("\\\n", " ")
        for line in run.splitlines():
            try:
                tokens = shlex.split(line, comments=True)
            except ValueError:
                continue
            for index, token in enumerate(tokens):
                if token == name or token.endswith("/" + name):
                    found.append(tokens[index:])
    return found

assert command_args("lint", "fm-lint.sh")
portable_runner = command_args("tests", "fm-test-run.sh")
assert any(
    "--all" in args
    and "--exclude-family" in args
    and args[args.index("--exclude-family") + 1] == "real-herdr-gated"
    for args in portable_runner
)
assert ci["jobs"]["tests"]["timeout-minutes"] == 25
herdr_runner = command_args("tests-herdr", "fm-test-run.sh")
assert any(
    "--family" in args
    and args[args.index("--family") + 1] == "real-herdr-gated"
    and "--fail-on-any-gate-skip" in args
    for args in herdr_runner
)
assert command_args("tests-herdr", "fm-install-herdr.sh")
assert command_args("tests-herdr", "fm-install-treehouse.sh")
assert command_args("tests-herdr", "fm-herdr-ci-cleanup.sh")
assert all(job.get("continue-on-error") is not True for job in ci["jobs"].values())
assert all("max-attempts" not in job.get("strategy", {}) for job in ci["jobs"].values())
assert all(
    step.get("continue-on-error") is not True
    for job in ci["jobs"].values()
    for step in job.get("steps", [])
)
PY
  status=$?
  expect_code 0 "$status" "CI semantic assertions must pass"
  CONFIG_JSON="$config_json" python3 - <<'PY'
import json
import os

config = json.loads(os.environ["CONFIG_JSON"])
assert config["commands"]["test"] == "bash bin/fm-run-behavior-tests.sh"
PY
  status=$?
  expect_code 0 "$status" "the gate must delegate tests to the canonical runner"
  pass "semantic CI and gate configuration use the one-owner runner"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_fail_on_gate_skip_token
test_fail_on_any_gate_skip
test_exclude_family
test_ci_and_docs_call_the_owner
