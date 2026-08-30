#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_ensure_pyyaml || fail "python3 PyYAML is required to parse workflow policy"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_pyyaml_vendor_is_offline_without_package_commands() {
  local vendor="$ROOT/tests/fixtures/vendor/pyyaml-6.0.2" tmp fakebin
  [ -f "$vendor/LICENSE" ] || fail "vendored PyYAML is missing upstream LICENSE"
  [ -f "$vendor/UPSTREAM" ] || fail "vendored PyYAML is missing digest provenance"
  assert_grep 'sdist_sha256=' "$vendor/UPSTREAM" \
    "vendored PyYAML must record the upstream sdist digest"
  if grep -Eq 'pip install|pip3 install' "$ROOT/tests/lib.sh"; then
    fail "fm_ensure_pyyaml must not invoke a package installer during tests"
  fi
  PYTHONNOUSERSITE=1 PYTHONPATH="$vendor" python3 - <<'PY' \
    || fail "hermetic PyYAML vendor could not parse workflow YAML offline"
import sys

import yaml

assert any("fixtures/vendor/pyyaml-6.0.2" in p for p in sys.path)
assert yaml.safe_load("jobs:\n  lint:\n    runs-on: ubuntu-latest\n") == {
    "jobs": {"lint": {"runs-on": "ubuntu-latest"}}
}
PY
  tmp=$(fm_test_tmproot fm-pyyaml-offline)
  fakebin=$(fm_fakebin "$tmp")
  for tool in pip pip3; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
printf 'package installer must not run during fm_ensure_pyyaml\n' >&2
exit 99
SH
    chmod +x "$fakebin/$tool"
  done
  PATH="$fakebin:$PATH" PYTHONNOUSERSITE=1 PYTHONPATH='' \
    bash -c '
      ROOT="'"$ROOT"'"
      # shellcheck source=tests/lib.sh
      . "$ROOT/tests/lib.sh"
      fm_ensure_pyyaml
    ' || fail "fm_ensure_pyyaml must succeed from the pinned vendor without package commands"
  pass "workflow-policy tests use pinned offline PyYAML with upstream provenance"
}

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
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
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line pr_forge
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pr_forge=$("$RUNNER" --list --family pr-forge)
  assert_contains "$pr_forge" "tests/fm-check-register.test.sh" \
    "pr-forge family must include custom-check lifecycle coverage"
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
  local repo=$1 script opencode_plugin
  mkdir -p "$repo/bin" "$repo/tests" "$repo/.opencode/plugins"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-bearings-board-render.test.sh \
    fm-no-mistakes-required.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh \
    fm-model-usage.test.sh \
    fm-memory-doctor.test.sh \
    fm-pending-reply.test.sh \
    fm-procevent.test.sh \
    fm-public-followup.test.sh \
    fm-slack-captain-channel.test.sh \
    fm-slack-socket.test.sh \
    fm-x-mode.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  # A behavior-area fixture extracted out of a suite: only the helper names the
  # shared source, and only the suite names the helper.
  printf '#!/usr/bin/env bash\n# drives bin/fm-fixture-shared.sh\n' \
    >"$repo/tests/fixture-helpers.sh"
  printf '# tests/fixture-helpers.sh\n' >>"$repo/tests/fm-pr-merge.test.sh"
  : >"$repo/bin/fm-fixture-shared.sh"
  # Single-file fixtures kept directly under tests/fixtures/: one named by a
  # suite, one named by nothing.
  mkdir -p "$repo/tests/fixtures"
  : >"$repo/tests/fixtures/flat-named.golden"
  : >"$repo/tests/fixtures/flat-orphan.golden"
  printf '# tests/fixtures/flat-named.golden\n' >>"$repo/tests/fm-brief.test.sh"
  mkdir -p "$repo/tests/assets"
  : >"$repo/tests/assets/board-render-harness.mjs"
  printf '# tests/assets/board-render-harness.mjs\n' >>"$repo/tests/fm-bearings-board-render.test.sh"
  : >"$repo/bin/fm-no-mistakes-required-verifier.py"
  printf '# bin/fm-no-mistakes-required-verifier.py\n' >>"$repo/tests/fm-no-mistakes-required.test.sh"
  mkdir -p "$repo/tests/fixtures/vendor/pyyaml-6.0.2"
  : >"$repo/tests/fixtures/vendor/pyyaml-6.0.2/LICENSE"
  printf '# tests/fixtures/vendor/pyyaml-6.0.2\n' >>"$repo/tests/fm-no-mistakes-required.test.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-launch-axis-lib.sh"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/fm-model-usage.mjs"
  : >"$repo/bin/fm-x-lib.sh"
  : >"$repo/bin/fm-public-followup-lib.sh"
  : >"$repo/bin/fm-procevent-lib.sh"
  : >"$repo/bin/fm-slack-lib.sh"
  : >"$repo/bin/fm-pending-reply-lib.sh"
  : >"$repo/bin/unmapped-source.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  printf '{}\n' >"$repo/.backpassrc.json"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  # Keep the path split so this regression proves the explicit path map instead
  # of satisfying the runner's source-reference scan with its own test text.
  opencode_plugin="$repo/.opencode/plugins/fm-primary-"
  : >"${opencode_plugin}cd-check.js"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc opencode_plugin
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
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

  printf '\n' >>"$repo/bin/fm-launch-axis-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend.test.sh" "launch-axis changes select backend coverage"
  assert_contains "$listed" "tests/fm-brief.test.sh" "launch-axis changes select pure contract coverage"
  git -C "$repo" add bin/fm-launch-axis-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm launch-axis-change

  printf '\n' >>"$repo/bin/fm-model-usage.mjs"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-model-usage.test.sh" "usage reader changes select their own contract coverage"
  git -C "$repo" add bin/fm-model-usage.mjs
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm usage-reader-change

  printf '\n' >>"$repo/bin/fm-x-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-x-mode.test.sh" "X owner changes preserve X-mode coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" "X owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" "X owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-x-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm x-owner-change

  printf '\n' >>"$repo/bin/fm-public-followup-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-public-followup.test.sh" \
    "public-followup owner changes preserve public-followup coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" \
    "public-followup owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "public-followup owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-public-followup-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm public-followup-owner-change

  printf '\n' >>"$repo/bin/fm-procevent-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-procevent.test.sh" \
    "process-event owner changes preserve process-event coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" \
    "process-event owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "process-event owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-procevent-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm procevent-owner-change

  printf '\n' >>"$repo/bin/fm-slack-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-slack-captain-channel.test.sh" \
    "Slack owner changes preserve Slack coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" \
    "Slack owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "Slack owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-slack-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm slack-owner-change

  printf '\n' >>"$repo/bin/fm-pending-reply-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pending-reply.test.sh" \
    "pending-reply owner changes preserve pending-reply coverage"
  assert_contains "$listed" "tests/fm-memory-doctor.test.sh" \
    "pending-reply owner changes select memory-doctor coverage"
  assert_contains "$listed" "tests/fm-session-start.test.sh" \
    "pending-reply owner changes select bootstrap coverage"
  git -C "$repo" add bin/fm-pending-reply-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm pending-reply-owner-change

  printf '\n' >>"$repo/bin/fm-fixture-shared.sh"
  set +e
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>"$tmp/helper-err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "source named only by a shared fixture must stay mapped: $(cat "$tmp/helper-err")"
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" \
    "source named only by a shared fixture selects the suites sourcing that fixture"
  git -C "$repo" add bin/fm-fixture-shared.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture-shared-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf ' { }\n' >"$repo/.backpassrc.json"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" \
    "Backpass configuration changes select pure contract coverage"
  git -C "$repo" add .backpassrc.json
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm backpass-config-change

  opencode_plugin="$repo/.opencode/plugins/fm-primary-"
  printf '\n' >>"${opencode_plugin}cd-check.js"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" \
    "OpenCode cd adapter changes select cd-guard coverage"
  git -C "$repo" add .opencode
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm opencode-cd-adapter-change

  printf '\n' >>"$repo/tests/fixtures/flat-named.golden"
  set +e
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD 2>"$tmp/flat-err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "a single-file fixture named by a suite must stay mapped: $(cat "$tmp/flat-err")"
  assert_contains "$listed" "tests/fm-brief.test.sh" \
    "a single-file fixture selects the suite that names it"
  git -C "$repo" add tests/fixtures/flat-named.golden
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm flat-fixture-change

  printf '\n' >>"$repo/tests/fixtures/flat-orphan.golden"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a single-file fixture no suite names must fail closed, got $rc"
  grep -Fq 'no changed-test mapping for source path: tests/fixtures/flat-orphan.golden' "$tmp/err" \
    || fail "unnamed single-file fixture failure is not actionable: $(cat "$tmp/err")"
  git -C "$repo" add tests/fixtures/flat-orphan.golden
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm flat-orphan-change

  printf '\n' >>"$repo/tests/assets/board-render-harness.mjs"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-bearings-board-render.test.sh" \
    "the board-render harness selects its consuming render suite"
  git -C "$repo" add tests/assets/board-render-harness.mjs
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm board-render-harness-change

  printf '\n' >>"$repo/bin/fm-no-mistakes-required-verifier.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-no-mistakes-required.test.sh" \
    "the verifier fixture selects its consuming contract suite"
  git -C "$repo" add bin/fm-no-mistakes-required-verifier.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm verifier-fixture-change

  printf '\n' >>"$repo/tests/fixtures/vendor/pyyaml-6.0.2/LICENSE"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-no-mistakes-required.test.sh" \
    "a nested fixture selects a suite naming its fixture ancestor"
  git -C "$repo" add tests/fixtures/vendor/pyyaml-6.0.2/LICENSE
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm nested-fixture-change

  rm "$repo/tests/fixtures/vendor/pyyaml-6.0.2/LICENSE"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-no-mistakes-required.test.sh" \
    "a deleted nested fixture selects its suite through the existing parent"
  git -C "$repo" add -u -- tests/fixtures/vendor/pyyaml-6.0.2/LICENSE
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm deleted-nested-fixture-change

  mkdir -p "$repo/rejected"
  printf 'night report\n' >"$repo/gnhf-night-report.md"
  printf 'rejected candidate\n' >"$repo/rejected/1-candidate.md"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "tracked autonomous-run artifacts must select no family instead of failing closed: $(cat "$tmp/err")"
  git -C "$repo" add gnhf-night-report.md rejected
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm run-artifact-change

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

test_unwritable_timing_artifact_keeps_the_suite_verdict() {
  local tmp fixture red out err json rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-artifact.XXXXXX")
  fixture="$tmp/ok.test.sh"
  red="$tmp/red.test.sh"
  out="$tmp/out.txt"
  err="$tmp/err.txt"
  # A path whose parent is a regular file can never be created or written.
  : >"$tmp/blocked"
  json="$tmp/blocked/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  cat >"$red" <<'SH'
#!/usr/bin/env bash
echo "not ok - fixture"
exit 1
SH
  chmod +x "$fixture" "$red"

  rc=0
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] \
    || { rm -rf "$tmp"; fail "an unwritable timing artifact reclassified a green run: rc=$rc"; }
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=0 ' "$out" \
    || { rm -rf "$tmp"; fail "the green run lost its verdict trailer: $(cat "$out")"; }
  assert_contains "$(cat "$err")" "could not write timing artifact: $json" \
    "the contained artifact failure was not reported"
  [ ! -e "$json" ] || { rm -rf "$tmp"; fail "an artifact appeared at an unwritable path"; }

  rc=0
  "$RUNNER" --json "$json" "$red" >"$out" 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] \
    || { rm -rf "$tmp"; fail "a contained artifact failure also swallowed a failing script"; }
  grep -Eq '^FM_TEST_SUMMARY total=1 failed=1 ' "$out" \
    || { rm -rf "$tmp"; fail "the red run lost its verdict trailer: $(cat "$out")"; }
  rm -rf "$tmp"
  pass "an unwritable timing artifact is reported without changing the suite verdict"
}

test_lane_selection_grammar_is_the_published_lane_label() {
  local tmp repo runner proven
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-selection.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  # fm-daemon is neither proven-isolated nor Herdr-gated, so it is the whole
  # portable serial remainder here; the smoke suite is the whole Herdr family.
  printf '#!/usr/bin/env bash\necho "ok - serial fixture"\n' >"$repo/tests/fm-daemon.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - herdr fixture"\n' \
    >"$repo/tests/fm-backend-herdr-smoke.test.sh"
  chmod +x "$runner" "$repo/tests/fm-daemon.test.sh" "$repo/tests/fm-backend-herdr-smoke.test.sh"
  # The proven-isolated members of portable-parallel-1, so the one production
  # lane that runs with bounded in-lane parallelism can be selected for real.
  while IFS= read -r proven; do
    printf '#!/usr/bin/env bash\necho "ok - proven fixture"\n' >"$repo/$proven"
    chmod +x "$repo/$proven"
  done < <("$RUNNER" --list --lane portable-parallel-1)

  (cd "$repo" && bin/fm-test-run.sh --lane portable-serial --json "$tmp/lane.json") >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "a lane-selected run over a green fixture must pass"; }
  (cd "$repo" && bin/fm-test-run.sh --lane portable-serial \
    --fail-on-gate-skip 'herdr not found' --json "$tmp/lane-suffix.json") >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "a lane-selected run with a gate-skip token must pass"; }
  (cd "$repo" && bin/fm-test-run.sh --family real-herdr-gated \
    --fail-on-gate-skip 'herdr not found' --json "$tmp/family.json") >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "a family-selected run with a gate-skip token must pass"; }
  (cd "$repo" && bin/fm-test-run.sh --jobs 2 --lane portable-parallel-1 \
    --json "$tmp/jobs.json") >/dev/null 2>&1 \
    || { rm -rf "$tmp"; fail "a bounded-parallel lane run over green fixtures must pass"; }

  # bin/fm-ci.sh labels each row of the published Water 7 timing table by reading
  # this emitted selection as <kind>=<name>[;<suffix>...]. The exact strings are
  # pinned at the emitter, so changing the grammar fails this suite instead of
  # silently mislabelling a job summary.
  python3 -c '
import json, sys
lane, lane_suffix, family, jobs = (
    json.load(open(path, encoding="utf-8"))["selection"] for path in sys.argv[1:]
)
assert lane == "lane=portable-serial", lane
assert lane_suffix == "lane=portable-serial;fail-on-gate-skip=herdr not found", lane_suffix
assert family == "family=real-herdr-gated;fail-on-gate-skip=herdr not found", family
assert jobs == "lane=portable-parallel-1;jobs=2", jobs
' "$tmp/lane.json" "$tmp/lane-suffix.json" "$tmp/family.json" "$tmp/jobs.json" \
    || { rm -rf "$tmp"; fail "the emitted selection no longer carries the lane label fm-ci.sh publishes"; }
  rm -rf "$tmp"
  pass "the emitted selection pins the lane label the job summary publishes"
}

test_aggregate_json_contains_an_unusable_input() {
  local tmp out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggmissing.XXXXXX")
  printf '%s\n' '{"run_id": "a", "selection": "lane=portable-serial", "summary": {"total": 0, "failed": 0, "skipped_gate": 0, "duration_ms": 0}, "scripts": []}' \
    >"$tmp/a.json"
  rc=0
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/absent.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "aggregating a never-written lane artifact must fail"; }
  assert_contains "$out" "aggregate input not found: $tmp/absent.json" \
    "the missing aggregate input was not named"
  assert_not_contains "$out" 'Traceback (most recent call last)' \
    "a missing aggregate input raised a Python traceback into the job log"
  [ ! -e "$tmp/out.json" ] \
    || { rm -rf "$tmp"; fail "a partial aggregate was written from an incomplete lane set"; }

  printf '%s' '{"run_id": "a", "selection": "lane=portab' >"$tmp/truncated.json"
  rc=0
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/truncated.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "aggregating a truncated lane artifact must fail"; }
  assert_contains "$out" "aggregate input is not valid timing JSON: $tmp/truncated.json" \
    "the unparsable aggregate input was not named"
  assert_not_contains "$out" 'Traceback (most recent call last)' \
    "a truncated aggregate input raised a Python traceback into the job log"
  rm -rf "$tmp"
  pass "a missing or unparsable aggregate input is reported without a traceback"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
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
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_serial_runner_sanitizes_firstmate_overrides() {
  local tmp fixture out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-env.XXXXXX")
  fixture="$tmp/env.test.sh"
  out="$tmp/out.txt"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
if env | grep -Eq '^(FM_HOME|FM_STATE_OVERRIDE|FM_DATA_OVERRIDE|FM_ROOT_OVERRIDE|FM_PROJECTS_OVERRIDE|FM_CONFIG_OVERRIDE|FM_BACKEND)='; then
  echo "not ok - inherited Firstmate override reached serial test"
  exit 1
fi
echo "ok - serial test environment is isolated"
SH
  chmod +x "$fixture"
  FM_HOME=/tmp/inherited-home \
    FM_STATE_OVERRIDE=/tmp/inherited-state \
    FM_DATA_OVERRIDE=/tmp/inherited-data \
    FM_ROOT_OVERRIDE=/tmp/inherited-root \
    FM_PROJECTS_OVERRIDE=/tmp/inherited-projects \
    FM_CONFIG_OVERRIDE=/tmp/inherited-config \
    FM_BACKEND=inherited-backend \
    "$RUNNER" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "serial runner leaked a Firstmate override"; }
  grep -Fq 'ok - serial test environment is isolated' "$out" \
    || { rm -rf "$tmp"; fail "serial environment fixture did not run"; }
  rm -rf "$tmp"
  pass "serial runner sanitizes Firstmate overrides"
}

test_gate_skip_accounting_under_unsupported_inherited_locale() {
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
  LC_ALL=fm_TEST_INVALID_LOCALE LANG=fm_TEST_INVALID_LOCALE \
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
  pass "gate-skip accounting survives an unsupported inherited locale"
}

# The runner replaces an unusable inherited locale so children never warn into
# the protocol stream, but the replacement must still decode UTF-8: the suite
# asserts on multibyte content (composer glyphs, the U+2063 injection sentinel,
# codepoint-bounded text), and a byte-oriented locale makes every ${#s}/${s:0:1}
# in those assertions count bytes instead.
test_inherited_locale_replacement_keeps_utf8_text_semantics() {
  local tmp probe out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-locale.XXXXXX")
  probe="$tmp/locale.test.sh"
  cat >"$probe" <<'SH'
#!/usr/bin/env bash
s='❯x'
printf 'chars=%s first=%s\n' "${#s}" "${s:0:1}"
SH
  chmod +x "$probe"
  out=$(LC_ALL=fm_TEST_INVALID_LOCALE LANG=fm_TEST_INVALID_LOCALE \
    "$RUNNER" "$probe" 2>/dev/null) \
    || { rm -rf "$tmp"; fail "the locale probe fixture must run"; }
  rm -rf "$tmp"
  if [ "$(env LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" = UTF-8 ] \
    || [ "$(env LC_ALL=en_US.UTF-8 locale charmap 2>/dev/null)" = UTF-8 ]; then
    assert_contains "$out" 'chars=2 first=❯' \
      "the replacement locale must read ❯ as one character"
  else
    # No UTF-8 locale exists here, so the documented C fallback is correct.
    assert_contains "$out" 'chars=4' "the C fallback must still be a working locale"
  fi
  pass "an unusable inherited locale is replaced by the host's best UTF-8 locale"
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
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-focus-flash-e2e.test.sh' \
    || fail "family real-herdr-gated must list focus-flash e2e"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-focus-flash-e2e.test.sh' \
    && fail "portable lanes must not include real-Herdr focus-flash e2e"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local lanes count serial shard listed union dups shard_lane total cap
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two portable serial shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^portable-serial-1of${count}\$" \
    || fail "shard lane names must carry the shard count ${count}: $lanes"

  serial=$("$RUNNER" --list --lane portable-serial | LC_ALL=C sort)
  union=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="portable-serial-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane")
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "portable serial shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$serial" ] \
    || fail "portable serial shards must exactly cover the portable serial lane"

  # Every shard carries a real share of the lane, so no degenerate partition
  # leaves one runner doing nearly all of the work the split exists to spread.
  total=$(printf '%s\n' "$serial" | wc -l | tr -d ' ')
  cap=$((total * 6 / 10))
  shard=1
  while [ "$shard" -le "$count" ]; do
    listed=$("$RUNNER" --list --lane "portable-serial-${shard}of${count}" | wc -l | tr -d ' ')
    [ "$listed" -ge 2 ] \
      || fail "portable-serial-${shard}of${count} holds only $listed script(s)"
    [ "$listed" -le "$cap" ] \
      || fail "portable-serial-${shard}of${count} holds $listed of $total scripts"
    shard=$((shard + 1))
  done

  # Assignment is deterministic across invocations.
  [ "$("$RUNNER" --list --lane "portable-serial-1of${count}")" = \
    "$("$RUNNER" --list --lane "portable-serial-1of${count}")" ] \
    || fail "portable serial shard membership must be deterministic"
  pass "portable serial shards are a deterministic disjoint cover of the serial lane"
}

test_portable_serial_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

test_jobs_requires_proven_isolated() {
  local tmp rc shard_lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-watcher-lock.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on watcher-lock must refuse, got $rc"
  # Sharding across runners never relaxes the serial rule inside one shard.
  shard_lane=$("$RUNNER" --list-lanes | grep -m1 '^portable-serial-[0-9]*of[0-9]*$')
  set +e
  "$RUNNER" --jobs 2 --lane "$shard_lane" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_herdr_ci_family_run_has_a_step_timeout() {
  # The required Herdr lane's hang tripwire is the family-run *step* bound, not
  # the 75-minute job cap. Parse the workflow as YAML so nested `with.name`
  # artifact keys cannot masquerade as the step contract.
  local json job_timeout step_timeout
  json=$(python3 - "$ROOT/.github/workflows/ci.yml" <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as workflow:
    job = yaml.safe_load(workflow)["jobs"]["tests-herdr"]
step = next(
    step
    for step in job["steps"]
    if step.get("name") == "Run real-Herdr family (serial, required)"
)
print(json.dumps({
    "job_timeout": job["timeout-minutes"],
    "step_timeout": step["timeout-minutes"],
}))
PY
  ) \
    || fail "could not parse tests-herdr timeouts from ci.yml"
  job_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["job_timeout"])' <<<"$json") \
    || fail "could not read job timeout from parsed workflow"
  step_timeout=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["step_timeout"])' <<<"$json") \
    || fail "could not read step timeout from parsed workflow"
  [ "$job_timeout" = 75 ] \
    || fail "tests-herdr job backstop must stay 75 minutes, got $job_timeout"
  [ "$step_timeout" = 20 ] \
    || fail "family-run step timeout must be 20 minutes, got $step_timeout"
  [ "$step_timeout" -lt "$job_timeout" ] \
    || fail "family-run step timeout must be below the job backstop"
  pass "Herdr CI family-run step times out at 20 min under a 75 min job backstop"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
# Fields bin/fm-ci.sh renders into the Water 7 job summary. They are pinned here,
# at the owner that emits them, so renaming one fails this suite instead of
# silently emptying a published report.
assert [lane["selection"] for lane in doc["lanes"]]==[
    "lane=portable-parallel-1", "lane=portable-serial"], doc["lanes"]
assert [lane["summary"]["duration_ms"] for lane in doc["lanes"]]==[1000, 2000], doc["lanes"]
assert [(row["path"], row["duration_ms"]) for row in doc["slowest"]]==[
    ("tests/b.test.sh", 1500),
    ("tests/a.test.sh", 1000),
    ("tests/c.test.sh", 500),
], doc["slowest"]
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_empty_selection_emits_summary
test_timing_markers_and_json
test_unwritable_timing_artifact_keeps_the_suite_verdict
test_lane_selection_grammar_is_the_published_lane_label
test_pyyaml_vendor_is_offline_without_package_commands
test_aggregate_json_contains_an_unusable_input
test_aggregate_exit_behavior
test_serial_runner_sanitizes_firstmate_overrides
test_gate_skip_accounting_under_unsupported_inherited_locale
test_inherited_locale_replacement_keeps_utf8_text_semantics
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_shard_lane_refusals
test_jobs_requires_proven_isolated
test_jobs_parallel_scheduler_and_failure_propagation
test_herdr_ci_family_run_has_a_step_timeout
test_aggregate_json
