#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, declarative runtime-gate evidence,
# proven-isolated --jobs, timing markers, JSON artifacts, coverage guard, and
# aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

run_in_new_process_group() {
  local python=$1 cwd=$2 stdout_path=$3 stderr_path=$4
  shift 4
  "$python" - "$cwd" "$stdout_path" "$stderr_path" "$@" <<'PY'
import os
import signal
import subprocess
import sys

cwd, stdout_path, stderr_path, *command = sys.argv[1:]
with open(stdout_path, "w", encoding="utf-8") as out, open(stderr_path, "w", encoding="utf-8") as err:
    child = subprocess.Popen(
        command,
        cwd=cwd,
        stdout=out,
        stderr=err,
        start_new_session=True,
    )
    try:
        rc = child.wait(timeout=5)
    except BaseException:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        raise
print(rc)
PY
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
  local listed line
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
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
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
  local tmp repo out json journal run_dir
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  journal="$tmp/journal"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && /bin/bash bin/fm-test-run.sh --changed --base HEAD \
    --progress-journal "$journal" --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
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
  run_dir=$(journal_run_dir "$journal")
  assert_journal_run "$run_dir/run.json" passed 0 1 serial \
    || { rm -rf "$tmp"; fail "empty selection did not finalize its zero-worker plan"; }
  if find "$run_dir/events" "$run_dir/states" -type f -print | grep -q .; then
    rm -rf "$tmp"
    fail "empty selection created an unplanned worker record"
  fi
  rm -rf "$tmp"
  pass "empty changed selection emits summaries and a terminal zero-worker plan"
}

test_empty_selection_preserves_disabled_fast_path() {
  local tmp repo out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty-disabled.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && TMPDIR="$tmp/missing" /bin/bash bin/fm-test-run.sh \
    --changed --base HEAD --jobs 2 2>"$tmp/err") \
    || { cat "$tmp/err"; rm -rf "$tmp"; fail "disabled empty selection must not require runner temp state"; }
  [ "$out" = "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0" ] \
    || { rm -rf "$tmp"; fail "disabled empty selection changed its summary: $out"; }
  rm -rf "$tmp"
  pass "empty disabled selection exits before journal runner setup"
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
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified runtime_gate=none gate_requirement=none$' "$out" \
    || fail "BEGIN line missing runtime gate contract: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_GATE .+ runtime=none requirement=none outcome=exercised$' "$out" \
    || fail "gate marker missing exercised evidence: $(grep '^FM_TEST_GATE' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false gate_outcome=exercised$' "$out" \
    || fail "END line missing typed gate outcome: $(grep '^FM_TEST_END' "$out")"
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
assert doc["scripts"][0]["runtime_gate"] == "none"
assert doc["scripts"][0]["gate_requirement"] == "none"
assert doc["scripts"][0]["gate_outcome"] == "exercised"
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_quoting_and_platform_temp_paths() {
  local tmp repo fixture json out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-quoted.XXXXXX")
  repo="$tmp/repo with spaces"
  fixture="$repo/fixture with spaces.test.sh"
  json="$tmp/artifact with spaces/timing.json"
  mkdir -p "$repo/bin"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'ok - quoted fixture\n'
SH
  chmod +x "$fixture"
  out=$(cd "$repo" && ./bin/fm-test-run.sh --json "$json" "$fixture") \
    || { rm -rf "$tmp"; fail "runner rejected a script or artifact path containing spaces"; }
  assert_contains "$out" "FM_TEST_SUMMARY total=1 failed=0" "quoted path summary"
  [ -f "$json" ] || { rm -rf "$tmp"; fail "quoted JSON path was not created"; }
  rm -rf "$tmp"
  pass "quoting, temporary paths, and platform stat fallback stay portable"
}

test_stock_bash_wrapper_pins_nested_runner() {
  local tmp fixture out
  [ -n "${FM_STOCK_BASH_VERSION:-}" ] || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-stock-bash.XXXXXX")
  fixture="$tmp/interpreter.test.sh"
  out="$tmp/out"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
if [ "$BASH_VERSION" != "$FM_STOCK_BASH_VERSION" ]; then
  printf 'not ok - expected nested runner Bash %s, got %s\n' "$FM_STOCK_BASH_VERSION" "$BASH_VERSION"
  exit 1
fi
printf 'ok - nested runner used stock Bash %s\n' "$BASH_VERSION"
SH
  chmod +x "$fixture"
  "$RUNNER" "$fixture" >"$out" 2>&1 \
    || { cat "$out"; rm -rf "$tmp"; fail "stock Bash wrapper did not pin the runner interpreter"; }
  assert_contains "$(cat "$out")" "FM_TEST_SUMMARY total=1 failed=0" "stock Bash nested runner summary"
  rm -rf "$tmp"
  pass "stock Bash wrapper pins nested runner invocations to the verified interpreter"
}

test_parallel_child_can_signal_immediately() {
  local tmp repo runner fixture evidence child_pid rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-pretrap.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fixture=tests/fm-brief.test.sh
  evidence="$tmp/evidence"
  mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$runner"
  cat >"$repo/$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$SCHED_EVIDENCE/child.pid"
kill -TERM "$PPID"
while :; do
  sleep 1
done
SH
  chmod +x "$runner" "$repo/$fixture"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$fixture" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "signaled parallel fixture should aggregate as failure, got $rc"; }
  child_pid=$(cat "$evidence/child.pid" 2>/dev/null || true)
  [ -n "$child_pid" ] || { rm -rf "$tmp"; fail "immediate-signal fixture never started"; }
  if kill -0 "$child_pid" 2>/dev/null; then
    rm -rf "$tmp"
    fail "immediate child signal escaped worker cleanup"
  fi
  rm -rf "$tmp"
  pass "parallel workers own signals before launching test children"
}

test_interrupt_drains_serial_cleanup() {
  local tmp fixture child_pid runner_pid rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-serial-signal.XXXXXX")
  fixture="$tmp/serial.test.sh"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
set -e
cleanup_done=
cleanup() {
  [ -z "$cleanup_done" ] || return
  printf 'serial cleanup diagnostic\n'
  printf 'released\n' >"$SCHED_EVIDENCE/resource.released"
  cleanup_done=1
}
trap 'cleanup; exit 0' TERM
trap cleanup EXIT
printf '%s\n' "$$" >"$SCHED_EVIDENCE/child.pid"
while :; do
  sleep 1
done
SH
  chmod +x "$fixture"
  SCHED_EVIDENCE="$tmp" "$RUNNER" "$fixture" >"$tmp/out" 2>"$tmp/err" &
  runner_pid=$!
  child_pid=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$tmp/child.pid" ]; then
      child_pid=$(cat "$tmp/child.pid")
      break
    fi
    sleep 0.1
  done
  [ -n "$child_pid" ] || { kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true; rm -rf "$tmp"; fail "serial signal fixture never started"; }
  kill -TERM "$runner_pid"
  set +e
  wait "$runner_pid"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { rm -rf "$tmp"; fail "serial runner TERM exit should be 143, got $rc"; }
  grep -Fq 'serial cleanup diagnostic' "$tmp/out" \
    || { rm -rf "$tmp"; fail "serial cleanup diagnostic was not drained"; }
  [ "$(cat "$tmp/resource.released" 2>/dev/null || true)" = "released" ] \
    || { rm -rf "$tmp"; fail "serial cleanup did not release its resource"; }
  if kill -0 "$child_pid" 2>/dev/null; then
    rm -rf "$tmp"
    fail "runner TERM left its serial child alive"
  fi
  rm -rf "$tmp"
  pass "serial cleanup drains diagnostics before releasing tee"
}

test_interrupt_cleans_parallel_process_tree() {
  local tmp repo runner fixture evidence child_pid descendant_pid runner_pid waited rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-signal.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fixture=tests/fm-brief.test.sh
  evidence="$tmp/evidence"
  mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  mkfifo "$evidence/term-ignored"
  cp "$RUNNER" "$runner"
  cat >"$repo/$fixture" <<'SH'
#!/usr/bin/env bash
(
  trap '' TERM
  : >"$SCHED_EVIDENCE/descendant.ready"
  IFS= read -r _ <"$SCHED_EVIDENCE/term-ignored"
) &
descendant_pid=$!
while [ ! -e "$SCHED_EVIDENCE/descendant.ready" ]; do
  sleep 0.01
done
printf '%s\n' "$$" >"$SCHED_EVIDENCE/child.pid"
printf '%s\n' "$descendant_pid" >"$SCHED_EVIDENCE/descendant.pid"
while :; do
  sleep 1
done
SH
  chmod +x "$runner" "$repo/$fixture"
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$fixture" >"$tmp/out" 2>"$tmp/err" &
  runner_pid=$!
  child_pid=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$evidence/child.pid" ]; then
      child_pid=$(cat "$evidence/child.pid")
      break
    fi
    sleep 0.1
  done
  [ -n "$child_pid" ] || { kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true; rm -rf "$tmp"; fail "signal fixture never started"; }
  descendant_pid=$(cat "$evidence/descendant.pid" 2>/dev/null || true)
  [ -n "$descendant_pid" ] || { kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true; rm -rf "$tmp"; fail "descendant fixture never started"; }
  kill -TERM "$runner_pid"
  waited=0
  while kill -0 "$runner_pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$runner_pid" 2>/dev/null; then
    kill -KILL "$runner_pid" "$child_pid" "$descendant_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    rm -rf "$tmp"
    fail "runner TERM hung on a TERM-ignoring descendant"
  fi
  set +e
  wait "$runner_pid"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { rm -rf "$tmp"; fail "runner TERM exit should be 143, got $rc"; }
  if kill -0 "$child_pid" 2>/dev/null; then
    rm -rf "$tmp"
    fail "runner TERM left its worker child alive"
  fi
  if kill -0 "$descendant_pid" 2>/dev/null; then
    rm -rf "$tmp"
    fail "runner TERM left its worker descendant alive"
  fi
  rm -rf "$tmp"
  pass "signals escalate and terminate complete parallel worker process trees"
}

test_interrupt_waits_for_parallel_cleanup() {
  local tmp repo runner fixture evidence child_pid runner_pid rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-synchronous.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fixture=tests/fm-brief.test.sh
  evidence="$tmp/evidence"
  mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$runner"
  cat >"$repo/$fixture" <<'SH'
#!/usr/bin/env bash
finish_cleanup() {
  sleep 0.2
  printf 'done\n' >"$SCHED_EVIDENCE/cleanup.done"
  exit 0
}
trap finish_cleanup TERM
printf '%s\n' "$$" >"$SCHED_EVIDENCE/child.pid"
while :; do
  sleep 1
done
SH
  chmod +x "$runner" "$repo/$fixture"
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$fixture" >"$tmp/out" 2>"$tmp/err" &
  runner_pid=$!
  child_pid=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$evidence/child.pid" ]; then
      child_pid=$(cat "$evidence/child.pid")
      break
    fi
    sleep 0.1
  done
  [ -n "$child_pid" ] || { kill "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true; rm -rf "$tmp"; fail "synchronous cleanup fixture never started"; }
  kill -TERM "$runner_pid"
  set +e
  wait "$runner_pid"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { rm -rf "$tmp"; fail "synchronous cleanup TERM exit should be 143, got $rc"; }
  [ -f "$evidence/cleanup.done" ] || { rm -rf "$tmp"; fail "runner returned before child cleanup completed"; }
  if kill -0 "$child_pid" 2>/dev/null; then
    rm -rf "$tmp"
    fail "runner returned before the cleanup child exited"
  fi
  rm -rf "$tmp"
  pass "signal handling completes child cleanup before returning"
}

test_completed_parallel_worker_drains_process_group() {
  local tmp repo runner fixture evidence descendant_pid state rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-completed-worker.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  fixture=tests/fm-brief.test.sh
  evidence="$tmp/evidence"
  mkdir -p "$repo/bin" "$repo/tests" "$evidence"
  cp "$RUNNER" "$runner"
  cat >"$repo/$fixture" <<'SH'
#!/usr/bin/env bash
bash -c 'trap "" HUP TERM; while :; do sleep 1; done' &
descendant_pid=$!
printf '%s\n' "$descendant_pid" >"$SCHED_EVIDENCE/descendant.pid"
printf 'ok - fixture completed while descendant remained active\n'
SH
  chmod +x "$runner" "$repo/$fixture"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$fixture" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "completed parallel fixture should pass, got $rc"; }
  assert_contains "$(cat "$tmp/out")" "FM_TEST_SUMMARY total=1 failed=0" "completed parallel fixture summary"
  descendant_pid=$(cat "$evidence/descendant.pid" 2>/dev/null || true)
  [ -n "$descendant_pid" ] || { rm -rf "$tmp"; fail "completed parallel fixture did not record its descendant"; }
  state=$(ps -o stat= -p "$descendant_pid" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
  case "$state" in
    ""|Z*) ;;
    *)
      kill -KILL "$descendant_pid" 2>/dev/null || true
      rm -rf "$tmp"
      fail "completed parallel worker left a live descendant behind (pid=$descendant_pid state=$state)"
      ;;
  esac
  rm -rf "$tmp"
  pass "completed parallel workers drain their remaining process groups"
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
  grep -Eq '^FM_TEST_GATE .+ runtime=none requirement=none outcome=legacy-skip$' "$out" \
    || fail "legacy skip must carry typed compatibility evidence: $(grep '^FM_TEST_GATE' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true gate_outcome=legacy-skip$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["scripts"][0]["gate_outcome"] == "legacy-skip"
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_runtime_gate_required_and_optional_outcomes() {
  local tmp skip_f required_out optional_out required_json exercised_out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-runtime-gate.XXXXXX")
  skip_f="$tmp/fm-backend-herdr-smoke.test.sh"
  required_out="$tmp/required.out"
  optional_out="$tmp/optional.out"
  required_json="$tmp/required.json"
  printf '#!/usr/bin/env bash\necho "ok - unit coverage"\necho "FM_TEST_RUNTIME_GATE runtime=herdr outcome=exercised"\n' >"$skip_f"
  chmod +x "$skip_f"
  "$RUNNER" --runtime-gate herdr=required "$skip_f" >"$tmp/exercised.out" 2>"$tmp/exercised.err" \
    || { rm -rf "$tmp"; fail "an exercised required Herdr gate must pass"; }
  exercised_out="$tmp/exercised.out"
  grep -Eq '^FM_TEST_GATE .+ runtime=herdr requirement=required outcome=exercised$' "$exercised_out" \
    || fail "required coverage lacks exercised evidence: $(grep '^FM_TEST_GATE' "$exercised_out")"

  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "FM_TEST_RUNTIME_GATE runtime=herdr outcome=unavailable"
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"

  set +e
  "$RUNNER" --runtime-gate herdr=required --json "$required_json" "$skip_f" >"$required_out" 2>"$tmp/required.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a skipped required Herdr gate must fail"
  grep -Eq '^FM_TEST_GATE .+ runtime=herdr requirement=required outcome=unexpectedly-skipped$' "$required_out" \
    || fail "required skip lacks typed failure evidence: $(grep '^FM_TEST_GATE' "$required_out")"
  grep -Eq '^FM_TEST_END .+ exit=1 duration_ms=[0-9]+ gate_skip=true gate_outcome=unexpectedly-skipped$' "$required_out" \
    || fail "required skip END marker is wrong: $(grep '^FM_TEST_END' "$required_out")"
  grep -Fq 'required runtime gate not exercised: runtime=herdr' "$tmp/required.err" \
    || fail "required skip diagnostic is missing: $(cat "$tmp/required.err")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
script = doc["scripts"][0]
assert script["runtime_gate"] == "herdr"
assert script["gate_requirement"] == "required"
assert script["gate_outcome"] == "unexpectedly-skipped"
assert script["exit"] == 1
' "$required_json" || { rm -rf "$tmp"; fail "required gate JSON evidence is wrong"; }

  "$RUNNER" "$skip_f" >"$optional_out" 2>"$tmp/optional.err" \
    || { rm -rf "$tmp"; fail "an unavailable optional runtime must remain successful"; }
  grep -Eq '^FM_TEST_GATE .+ runtime=herdr requirement=optional outcome=intentionally-unavailable$' "$optional_out" \
    || fail "optional runtime skip lacks typed availability evidence: $(grep '^FM_TEST_GATE' "$optional_out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true gate_outcome=intentionally-unavailable$' "$optional_out" \
    || fail "optional runtime END marker is wrong: $(grep '^FM_TEST_END' "$optional_out")"

  printf '#!/usr/bin/env bash\necho "ok - unit coverage passed before runtime skip"\n' >"$skip_f"
  set +e
  "$RUNNER" --runtime-gate herdr=required "$skip_f" >"$tmp/missing.out" 2>"$tmp/missing.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a mapped gate without explicit runtime evidence must fail"
  grep -Eq '^FM_TEST_GATE .+ runtime=herdr requirement=required outcome=unexpectedly-skipped$' "$tmp/missing.out" \
    || fail "missing runtime evidence lacks typed failure output: $(cat "$tmp/missing.out")"
  grep -Fq 'runtime gate evidence missing or invalid' "$tmp/missing.err" \
    || fail "missing runtime evidence lacks an actionable diagnostic: $(cat "$tmp/missing.err")"

  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "ok - unit coverage passed"
echo "skip: herdr not found after unit coverage"
echo "FM_TEST_RUNTIME_GATE runtime=herdr outcome=unavailable"
SH
  set +e
  "$RUNNER" --runtime-gate herdr=required "$skip_f" >"$tmp/mixed.out" 2>"$tmp/mixed.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an explicitly unavailable mixed-suite runtime must fail when required"
  grep -Eq '^FM_TEST_GATE .+ runtime=herdr requirement=required outcome=unexpectedly-skipped$' "$tmp/mixed.out" \
    || fail "mixed-suite unavailable evidence was not consumed: $(cat "$tmp/mixed.out")"
  rm -rf "$tmp"
  pass "runtime gates require explicit exercised or unavailable evidence"
}

test_runtime_gate_selection_validation_and_real_test_mapping() {
  local tmp repo fixture rc out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-runtime-selection.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  set +e
  "$RUNNER" --runtime-gate herdr=required tests/fm-lint.test.sh >"$tmp/unrelated.out" 2>"$tmp/unrelated.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "required Herdr must fail when the selection has no Herdr gate"
  grep -Fxq 'FM_TEST_GATE selection runtime=herdr requirement=required outcome=unexpectedly-skipped reason=no-selected-gate' "$tmp/unrelated.out" \
    || fail "unrelated selection lacks typed no-selected-gate evidence: $(cat "$tmp/unrelated.out")"

  set +e
  "$RUNNER" --runtime-gate herdr=required --family real-herdr-gated \
    --exclude-family real-herdr-gated >"$tmp/excluded.out" 2>"$tmp/excluded.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "required Herdr must fail after exclusions remove every Herdr gate"

  set +e
  (cd "$repo" && bin/fm-test-run.sh --runtime-gate herdr=required --changed --base HEAD) \
    >"$tmp/empty.out" 2>"$tmp/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "required Herdr must fail for an empty changed selection"
  grep -Fq 'reason=no-selected-gate' "$tmp/empty.out" \
    || fail "empty required selection lacks typed gate evidence: $(cat "$tmp/empty.out")"

  fixture="$tmp/fm-backend-orca.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - fake Orca coverage"\n' >"$fixture"
  chmod +x "$fixture"
  set +e
  "$RUNNER" --runtime-gate orca=required "$fixture" >"$tmp/orca.out" 2>"$tmp/orca.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fake-only Orca coverage must not satisfy a required Orca runtime"
  grep -Fq 'runtime=orca requirement=required outcome=unexpectedly-skipped reason=no-selected-gate' "$tmp/orca.out" \
    || fail "fake-only Orca refusal lacks typed evidence: $(cat "$tmp/orca.out")"
  "$RUNNER" --runtime-gate orca=optional "$fixture" >"$tmp/orca-optional.out" 2>"$tmp/orca-optional.err" \
    || fail "an unmatched optional Orca declaration must preserve local fake-only coverage"
  grep -Eq '^FM_TEST_BEGIN .+ family=orca runtime_gate=none gate_requirement=none$' "$tmp/orca-optional.out" \
    || fail "fake Orca suite must be unmapped from runtime evidence: $(cat "$tmp/orca-optional.out")"

  for fixture in "$tmp/fm-backend-cmux.test.sh" "$tmp/fm-backend-zellij.test.sh"; do
    printf '#!/usr/bin/env bash\necho "ok - fake runtime coverage"\n' >"$fixture"
    chmod +x "$fixture"
    out=$("$RUNNER" "$fixture") || fail "fake runtime fixture must remain ordinary coverage: $fixture"
    printf '%s\n' "$out" | grep -Eq '^FM_TEST_BEGIN .+ family=(cmux|zellij) runtime_gate=none gate_requirement=none$' \
      || fail "fake runtime suite must be unmapped from runtime evidence: $out"
  done

  rm -rf "$tmp"
  pass "required declarations validate selections and only real tests map runtimes"
}

test_runtime_gate_declaration_parser_refuses_malformed_input() {
  local tmp fixture declaration rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-runtime-gate-parse.XXXXXX")
  fixture="$tmp/fm-backend-herdr-smoke.test.sh"
  printf '#!/usr/bin/env bash\necho "ok - fixture"\n' >"$fixture"
  chmod +x "$fixture"
  for declaration in herdr herdr=must-run unknown=required '=optional'; do
    set +e
    "$RUNNER" --runtime-gate "$declaration" "$fixture" >"$tmp/out" 2>"$tmp/err"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "malformed declaration '$declaration' must exit 2, got $rc"
    grep -Eq 'malformed --runtime-gate declaration|unknown runtime gate' "$tmp/err" \
      || fail "malformed declaration '$declaration' lacks an actionable error: $(cat "$tmp/err")"
  done
  set +e
  "$RUNNER" --runtime-gate herdr=required --runtime-gate herdr=optional "$fixture" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "duplicate runtime declaration must exit 2, got $rc"
  grep -Fq "duplicate runtime gate declaration for 'herdr'" "$tmp/err" \
    || fail "duplicate declaration lacks an actionable error: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "runtime gate declaration parser rejects malformed and duplicate contracts"
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
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true gate_outcome=legacy-skip$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
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
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

journal_run_dir() {
  local journal=$1
  find "$journal/runs" -mindepth 2 -maxdepth 2 -name run.json -type f -exec dirname {} \; | head -n 1
}

assert_journal_state() {
  local path=$1 expected_state=$2 expected_worker=$3 expected_script=${4:-} expected_exit=${5:-}
  python3 - "$path" "$expected_state" "$expected_worker" "$expected_script" "$expected_exit" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    record = json.load(fh)
assert record["schema"] == 1
assert record["state"] == sys.argv[2]
assert record["worker_id"] == sys.argv[3]
assert record["run_id"]
assert record["runner_pid"] > 0
assert record["script"]
assert record["transition_ordinal"] == 2
if sys.argv[4]:
    assert record["script"] == sys.argv[4]
if sys.argv[5]:
    assert record["exit"] == int(sys.argv[5])
    assert record["duration_ms"] >= 0
PY
}

assert_journal_run() {
  local path=$1 expected_state=$2 expected_exit=$3 expected_jobs=$4 worker_prefix=$5
  shift 5
  python3 - "$path" "$expected_state" "$expected_exit" "$expected_jobs" "$worker_prefix" "$@" <<'PY'
import json
import sys

path, expected_state, expected_exit, expected_jobs, worker_prefix, *scripts = sys.argv[1:]
with open(path, encoding="utf-8") as fh:
    record = json.load(fh)
expected_workers = [
    {"worker_id": "%s-%s" % (worker_prefix, index), "script": script}
    for index, script in enumerate(scripts, start=1)
]
assert record["schema"] == 1
assert record["state"] == expected_state
assert record["run_id"]
assert record["runner_pid"] > 0
assert record["started_at"]
assert record["finished_at"]
assert record["selection"]
assert record["jobs"] == int(expected_jobs)
assert record["planned_worker_count"] == len(scripts)
assert record["planned_workers"] == expected_workers
assert record["exit"] == int(expected_exit)
PY
}

test_progress_journal_terminal_transitions_and_atomic_state() {
  local tmp journal slow fail_f timeout_f run_dir
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress.XXXXXX")
  journal="$tmp/journal"
  slow="$tmp/slow.test.sh"
  fail_f="$tmp/fail.test.sh"
  timeout_f="$tmp/timeout.test.sh"
  cat >"$slow" <<'SH'
#!/usr/bin/env bash
sleep 0.3
printf 'ok - slow pass\n'
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
printf 'not ok - expected failure\n'
exit 1
SH
  cat >"$timeout_f" <<'SH'
#!/usr/bin/env bash
printf 'not ok - conventional timeout exit\n'
exit 124
SH
  chmod +x "$slow" "$fail_f" "$timeout_f"
  python3 - "$RUNNER" "$journal" "$slow" "$fail_f" "$timeout_f" "$tmp" <<'PY' \
    || { rm -rf "$tmp"; fail "journal replacement controller failed"; }
import glob
import json
import os
import subprocess
import sys
import time

runner, journal, slow, failed, timeout, root = sys.argv[1:]
with open(os.path.join(root, "out"), "w", encoding="utf-8") as out, open(os.path.join(root, "err"), "w", encoding="utf-8") as err:
    child = subprocess.Popen(
        [runner, "--progress-journal", journal, slow, failed, timeout],
        stdout=out,
        stderr=err,
    )
    deadline = time.monotonic() + 3
    parsed = False
    while child.poll() is None:
        records = glob.glob(os.path.join(journal, "runs", "*", "run.json"))
        records += glob.glob(os.path.join(journal, "runs", "*", "states", "serial-1.json"))
        for record_path in records:
            with open(record_path, encoding="utf-8") as fh:
                json.load(fh)
            parsed = True
        if time.monotonic() >= deadline:
            child.kill()
            child.wait()
            raise SystemExit("journal run exceeded bounded replacement check")
        time.sleep(0.01)
    if child.wait() == 0:
        raise SystemExit("failure and timeout fixtures must fail the aggregate")
    if not parsed:
        raise SystemExit("journal never exposed a parseable started current-state record")
PY
  run_dir=$(journal_run_dir "$journal")
  [ -n "$run_dir" ] || { rm -rf "$tmp"; fail "progress journal did not create a run directory"; }
  assert_journal_state "$run_dir/states/serial-1.json" passed serial-1 \
    || { rm -rf "$tmp"; fail "serial pass state missing stable identity"; }
  assert_journal_state "$run_dir/states/serial-2.json" failed serial-2 \
    || { rm -rf "$tmp"; fail "serial failure state missing"; }
  assert_journal_state "$run_dir/states/serial-3.json" timed-out serial-3 \
    || { rm -rf "$tmp"; fail "serial timeout state missing"; }
  assert_journal_run "$run_dir/run.json" failed 1 1 serial "$slow" "$fail_f" "$timeout_f" \
    || { rm -rf "$tmp"; fail "failed run did not preserve its selected plan"; }
  [ -f "$run_dir/events/serial-1.1.started.json" ] \
    && [ -f "$run_dir/events/serial-1.2.passed.json" ] \
    && [ -f "$run_dir/events/serial-2.2.failed.json" ] \
    && [ -f "$run_dir/events/serial-3.2.timed-out.json" ] \
    || { rm -rf "$tmp"; fail "journal must preserve immutable terminal transitions"; }
  if find "$run_dir" -name '.*.tmp' -print | grep -q .; then
    rm -rf "$tmp"
    fail "journal left a temporary replacement record behind"
  fi
  rm -rf "$tmp"
  pass "progress journal records terminal transitions with atomically replaced state"
}

test_progress_journal_parallel_workers_preserve_transitions() {
  local tmp repo runner journal run_dir rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-parallel.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  journal="$tmp/journal"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cat >"$repo/tests/fm-brief.test.sh" <<'SH'
#!/usr/bin/env bash
sleep 0.05
printf 'ok - parallel one\n'
SH
  cat >"$repo/tests/fm-composer-lib.test.sh" <<'SH'
#!/usr/bin/env bash
sleep 0.05
printf 'ok - parallel two\n'
SH
  chmod +x "$runner" "$repo/tests/fm-brief.test.sh" "$repo/tests/fm-composer-lib.test.sh"
  set +e
  (cd "$repo" && "$runner" --jobs 2 --progress-journal "$journal" \
    tests/fm-brief.test.sh tests/fm-composer-lib.test.sh) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "parallel journal fixtures should pass"; }
  run_dir=$(journal_run_dir "$journal")
  [ "$(find "$run_dir/events" -type f | wc -l | tr -d ' ')" -eq 4 ] \
    || { rm -rf "$tmp"; fail "concurrent workers lost a durable transition"; }
  assert_journal_state "$run_dir/states/parallel-1.json" passed parallel-1 \
    || { rm -rf "$tmp"; fail "parallel worker one state missing"; }
  assert_journal_state "$run_dir/states/parallel-2.json" passed parallel-2 \
    || { rm -rf "$tmp"; fail "parallel worker two state missing"; }
  assert_journal_run "$run_dir/run.json" passed 0 2 parallel \
    tests/fm-brief.test.sh tests/fm-composer-lib.test.sh \
    || { rm -rf "$tmp"; fail "parallel run did not finalize its selected plan"; }
  rm -rf "$tmp"
  pass "progress journal preserves concurrent worker transitions"
}

test_progress_journal_ignores_malformed_prior_state() {
  local tmp journal fixture run_dir
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-malformed.XXXXXX")
  journal="$tmp/journal"
  fixture="$tmp/pass.test.sh"
  mkdir -p "$journal/runs/stale/events" "$journal/runs/stale/states"
  printf '{not json\n' >"$journal/runs/stale/states/bad.json"
  printf '{not json\n' >"$journal/runs/stale/events/bad.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'ok - pass\n'
SH
  chmod +x "$fixture"
  "$RUNNER" --progress-journal "$journal" "$fixture" >"$tmp/out" 2>"$tmp/err" \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "malformed historical journal state must not block a new run"; }
  [ "$(cat "$journal/runs/stale/states/bad.json")" = '{not json' ] \
    || { rm -rf "$tmp"; fail "malformed historical state was unexpectedly rewritten"; }
  run_dir=$(journal_run_dir "$journal")
  [ "$run_dir" != "$journal/runs/stale" ] \
    || { rm -rf "$tmp"; fail "new run reused malformed historical state"; }
  assert_journal_state "$run_dir/states/serial-1.json" passed serial-1 \
    || { rm -rf "$tmp"; fail "new run did not write a valid isolated state"; }
  rm -rf "$tmp"
  pass "progress journal ignores malformed historical state deterministically"
}

test_progress_journal_marks_abrupt_interruptions() {
  local tmp journal fixture run_dir rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-interrupt.XXXXXX")
  journal="$tmp/journal"
  fixture="$tmp/slow.test.sh"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >"$SCHED_EVIDENCE/started"
kill -TERM "$PPID"
while :; do sleep 1; done
SH
  chmod +x "$fixture"
  set +e
  SCHED_EVIDENCE="$tmp" "$RUNNER" --progress-journal "$journal" "$fixture" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { rm -rf "$tmp"; fail "interrupted runner should exit 143, got $rc"; }
  run_dir=$(journal_run_dir "$journal")
  assert_journal_state "$run_dir/states/serial-1.json" interrupted serial-1 \
    || { rm -rf "$tmp"; fail "abrupt interrupt was not journaled"; }
  [ -f "$run_dir/events/serial-1.2.interrupted.json" ] \
    || { rm -rf "$tmp"; fail "interrupted transition was not preserved"; }
  assert_journal_run "$run_dir/run.json" interrupted 143 1 serial "$fixture" \
    || { rm -rf "$tmp"; fail "interrupted run was not finalized"; }
  rm -rf "$tmp"
  pass "progress journal records abrupt interruptions before cleanup"
}

test_progress_journal_does_not_advance_state_after_event_failure() {
  local tmp journal fixture run_dir rc real_python
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-event-failure.XXXXXX")
  journal="$tmp/journal"
  fixture="$tmp/slow.test.sh"
  real_python=$(command -v python3)
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/python3" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}:${3:-}" in
  -:worker:*/events/serial-1.2.interrupted.json) exit 1 ;;
esac
exec "$REAL_PYTHON" "$@"
SH
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
kill -TERM "$PPID"
while :; do sleep 1; done
SH
  chmod +x "$tmp/bin/python3" "$fixture"
  set +e
  REAL_PYTHON="$real_python" PATH="$tmp/bin:$PATH" \
    "$RUNNER" --progress-journal "$journal" "$fixture" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "event-write failure interrupt should exit 143, got $rc"; }
  run_dir=$(journal_run_dir "$journal")
  [ ! -e "$run_dir/events/serial-1.2.interrupted.json" ] \
    || { rm -rf "$tmp"; fail "failed immutable event write unexpectedly created an event"; }
  python3 - "$run_dir/states/serial-1.json" "$fixture" <<'PY' \
    || { rm -rf "$tmp"; fail "current state advanced without its immutable event"; }
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    record = json.load(fh)
assert record["state"] == "started"
assert record["transition_ordinal"] == 1
assert record["script"] == sys.argv[2]
PY
  rm -rf "$tmp"
  pass "journal state never advances past a failed event write"
}

test_progress_journal_closes_startup_signal_windows() {
  local tmp real_python fixture journal run_dir rc repo runner
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-start-signal.XXXXXX")
  real_python=$(command -v python3)
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = - ] && [ "${2:-}" = worker ]; then
  case "${3:-}" in
    */events/"$SIGNAL_WORKER".1.started.json)
      group=$(ps -o pgid= -p "$5" | awk 'NR == 1 { gsub(/[[:space:]]/, "", $1); print $1 }')
      kill -TERM -- "-$group"
      exec "$REAL_PYTHON" "$@"
      ;;
  esac
fi
exec "$REAL_PYTHON" "$@"
SH
  chmod +x "$tmp/bin/python3"

  fixture="$tmp/serial.test.sh"
  journal="$tmp/serial-journal"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'not ok - startup signal should prevent launch\n'
exit 1
SH
  chmod +x "$fixture"
  set +e
  rc=$(SIGNAL_WORKER=serial-1 REAL_PYTHON="$real_python" PATH="$tmp/bin:$PATH" \
    run_in_new_process_group "$real_python" "$ROOT" "$tmp/serial.out" "$tmp/serial.err" \
      "$RUNNER" --progress-journal "$journal" "$fixture")
  set -e
  [ "$rc" -eq 143 ] || { cat "$tmp/serial.out" "$tmp/serial.err"; rm -rf "$tmp"; fail "serial startup signal should exit 143, got $rc"; }
  run_dir=$(journal_run_dir "$journal")
  assert_journal_state "$run_dir/states/serial-1.json" interrupted serial-1 "$fixture" \
    || { rm -rf "$tmp"; fail "serial startup signal orphaned its started worker"; }
  assert_journal_run "$run_dir/run.json" interrupted 143 1 serial "$fixture" \
    || { rm -rf "$tmp"; fail "serial startup signal did not finalize the run"; }

  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  journal="$tmp/parallel-journal"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cat >"$repo/tests/fm-brief.test.sh" <<'SH'
#!/usr/bin/env bash
printf 'not ok - startup signal should prevent launch\n'
exit 1
SH
  chmod +x "$runner" "$repo/tests/fm-brief.test.sh"
  set +e
  rc=$(SIGNAL_WORKER=parallel-1 REAL_PYTHON="$real_python" PATH="$tmp/bin:$PATH" \
    run_in_new_process_group "$real_python" "$repo" "$tmp/parallel.out" "$tmp/parallel.err" \
      "$runner" --jobs 2 --progress-journal "$journal" tests/fm-brief.test.sh)
  set -e
  [ "$rc" -eq 143 ] || { cat "$tmp/parallel.out" "$tmp/parallel.err"; rm -rf "$tmp"; fail "parallel startup signal should exit 143, got $rc"; }
  run_dir=$(journal_run_dir "$journal")
  assert_journal_state "$run_dir/states/parallel-1.json" interrupted parallel-1 tests/fm-brief.test.sh \
    || { rm -rf "$tmp"; fail "parallel startup signal orphaned its started worker"; }
  assert_journal_run "$run_dir/run.json" interrupted 143 2 parallel tests/fm-brief.test.sh \
    || { rm -rf "$tmp"; fail "parallel startup signal did not finalize the run"; }
  rm -rf "$tmp"
  pass "progress journal closes serial and parallel startup signal windows"
}

test_progress_journal_defers_initialization_signal_until_started() {
  local tmp journal fixture run_dir rc real_python
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-init-signal.XXXXXX")
  journal="$tmp/journal"
  fixture="$tmp/not-run.test.sh"
  real_python=$(command -v python3)
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = - ] && [ "${2:-}" = sync-directories ]; then
  printf 'ready\n' >"$SYNC_EVIDENCE"
  sleep 0.2
  exec "$REAL_PYTHON" "$@"
fi
if [ "${1:-}" = - ] && [ "${2:-}" = run ] && [ "${7:-}" = started ]; then
  "$REAL_PYTHON" "$@"
  rc=$?
  cp "$3" "$STARTED_EVIDENCE"
  exit "$rc"
fi
exec "$REAL_PYTHON" "$@"
SH
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'not ok - initialization signal should prevent launch\n'
exit 1
SH
  chmod +x "$tmp/bin/python3" "$fixture"
  rc=$(REAL_PYTHON="$real_python" STARTED_EVIDENCE="$tmp/started.json" \
    SYNC_EVIDENCE="$tmp/sync-ready" PATH="$tmp/bin:$PATH" \
    "$real_python" - "$RUNNER" "$journal" "$fixture" "$tmp" <<'PY'
import os
import signal
import subprocess
import sys
import time

runner, journal, fixture, root = sys.argv[1:]
with open(os.path.join(root, "out"), "w", encoding="utf-8") as out, open(os.path.join(root, "err"), "w", encoding="utf-8") as err:
    child = subprocess.Popen(
        [runner, "--progress-journal", journal, fixture],
        stdout=out,
        stderr=err,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 3
        ready = os.path.join(root, "sync-ready")
        while not os.path.exists(ready):
            if child.poll() is not None:
                raise SystemExit("runner exited before the directory sync helper")
            if time.monotonic() >= deadline:
                raise SystemExit("directory sync helper never became ready")
            time.sleep(0.01)
        os.killpg(child.pid, signal.SIGTERM)
        rc = child.wait(timeout=5)
    except BaseException:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        raise
    print(rc)
PY
  ) || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "process-group signal controller failed"; }
  [ "$rc" -eq 143 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "initialization signal should exit 143, got $rc"; }
  [ -f "$tmp/started.json" ] \
    || { rm -rf "$tmp"; fail "initialization signal exited before the started record was durable"; }
  python3 - "$tmp/started.json" <<'PY' \
    || { rm -rf "$tmp"; fail "initialization signal did not preserve the durable started state"; }
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    record = json.load(fh)
assert record["state"] == "started"
PY
  run_dir=$(journal_run_dir "$journal")
  [ -n "$run_dir" ] || { rm -rf "$tmp"; fail "initialization signal orphaned the durable run directory"; }
  assert_journal_run "$run_dir/run.json" interrupted 143 1 serial "$fixture" \
    || { rm -rf "$tmp"; fail "initialization signal did not finalize the durable run"; }
  ! grep -Fq 'initialization signal should prevent launch' "$tmp/out" \
    || { rm -rf "$tmp"; fail "initialization signal launched a selected worker"; }
  rm -rf "$tmp"
  pass "progress journal shields initialization helpers until started state is durable"
}

test_progress_journal_preserves_post_terminal_signal_outcome() {
  local tmp journal fixture run_dir rc real_python
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-terminal-signal.XXXXXX")
  journal="$tmp/journal"
  fixture="$tmp/pass.test.sh"
  real_python=$(command -v python3)
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/python3" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}:${3:-}" in
  -:worker:*/events/serial-1.2.passed.json)
    "$REAL_PYTHON" "$@"
    rc=$?
    kill -TERM "$5"
    exit "$rc"
    ;;
esac
exec "$REAL_PYTHON" "$@"
SH
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'ok - completed before signal\n'
SH
  chmod +x "$tmp/bin/python3" "$fixture"
  set +e
  REAL_PYTHON="$real_python" PATH="$tmp/bin:$PATH" \
    "$RUNNER" --progress-journal "$journal" "$fixture" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "post-terminal signal should exit 143, got $rc"; }
  run_dir=$(journal_run_dir "$journal")
  assert_journal_state "$run_dir/states/serial-1.json" passed serial-1 "$fixture" 0 \
    || { rm -rf "$tmp"; fail "post-terminal signal regressed completed worker state"; }
  [ ! -e "$run_dir/events/serial-1.2.interrupted.json" ] \
    || { rm -rf "$tmp"; fail "post-terminal signal created a conflicting interruption"; }
  assert_journal_run "$run_dir/run.json" interrupted 143 1 serial "$fixture" \
    || { rm -rf "$tmp"; fail "post-terminal signal did not finalize the run"; }
  rm -rf "$tmp"
  pass "progress journal keeps terminal worker outcomes monotonic on signal"
}

test_progress_journal_publishes_adjudicated_outcome_before_bookkeeping() {
  local tmp fixture journal run_dir rc repo runner
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-adjudicated-signal.XXXXXX")
  fixture="$tmp/serial.test.sh"
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/mv" <<'SH'
#!/usr/bin/env bash
case "${FAKE_MV_MODE:-signal}:${2:-}" in
  fail:*/families.tsv) exit 1 ;;
esac
/bin/mv "$@"
rc=$?
case "${FAKE_MV_MODE:-signal}:${2:-}" in
  signal:*/families.tsv) kill -TERM "$PPID" ;;
esac
exit "$rc"
SH
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'ok - raw child passed\nskip: injected gate\n'
SH
  chmod +x "$tmp/bin/mv" "$fixture"

  journal="$tmp/serial-journal"
  set +e
  PATH="$tmp/bin:$PATH" "$RUNNER" --progress-journal "$journal" \
    --fail-on-gate-skip 'injected gate' "$fixture" >"$tmp/serial.out" 2>"$tmp/serial.err"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { cat "$tmp/serial.out" "$tmp/serial.err"; rm -rf "$tmp"; fail "serial bookkeeping signal should exit 143, got $rc"; }
  run_dir=$(journal_run_dir "$journal")
  assert_journal_state "$run_dir/states/serial-1.json" failed serial-1 "$fixture" 1 \
    || { rm -rf "$tmp"; fail "serial bookkeeping signal lost the adjudicated failure"; }

  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  journal="$tmp/parallel-journal"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$runner"
  cp "$fixture" "$repo/tests/fm-brief.test.sh"
  chmod +x "$runner" "$repo/tests/fm-brief.test.sh"
  set +e
  (cd "$repo" && PATH="$tmp/bin:$PATH" "$runner" --jobs 2 \
    --progress-journal "$journal" --fail-on-gate-skip 'injected gate' tests/fm-brief.test.sh) \
    >"$tmp/parallel.out" 2>"$tmp/parallel.err"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { cat "$tmp/parallel.out" "$tmp/parallel.err"; rm -rf "$tmp"; fail "parallel bookkeeping signal should exit 143, got $rc"; }
  run_dir=$(journal_run_dir "$journal")
  assert_journal_state "$run_dir/states/parallel-1.json" failed parallel-1 tests/fm-brief.test.sh 1 \
    || { rm -rf "$tmp"; fail "parallel cleanup inferred raw child success instead of the adjudicated failure"; }

  journal="$tmp/bookkeeping-failure-journal"
  set +e
  FAKE_MV_MODE=fail PATH="$tmp/bin:$PATH" "$RUNNER" --progress-journal "$journal" \
    "$fixture" >"$tmp/failure.out" 2>"$tmp/failure.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { cat "$tmp/failure.out" "$tmp/failure.err"; rm -rf "$tmp"; fail "bookkeeping failure should exit 1, got $rc"; }
  run_dir=$(journal_run_dir "$journal")
  assert_journal_state "$run_dir/states/serial-1.json" passed serial-1 "$fixture" 0 \
    || { rm -rf "$tmp"; fail "bookkeeping failure left the adjudicated worker at started"; }
  assert_journal_run "$run_dir/run.json" failed 1 1 serial "$fixture" \
    || { rm -rf "$tmp"; fail "bookkeeping failure did not finalize the failed run"; }
  rm -rf "$tmp"
  pass "journal persists adjudicated outcomes before bookkeeping"
}

test_progress_journal_terminal_publication_failure_changes_only_green_exit() {
  local tmp python_path pass_fixture interrupt_fixture journal rc run_dir
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-terminal-publication.XXXXXX")
  python_path="$tmp/python"
  pass_fixture="$tmp/pass.test.sh"
  interrupt_fixture="$tmp/interrupt.test.sh"
  mkdir -p "$python_path"
  cat >"$python_path/sitecustomize.py" <<'PY'
import os
import stat
import sys

if len(sys.argv) > 6 and sys.argv[1] == "run" and sys.argv[6] == os.environ.get("FAIL_RUN_STATE"):
    real_fsync = os.fsync

    def fail_directory_fsync(fd):
        if stat.S_ISDIR(os.fstat(fd).st_mode):
            raise OSError("injected directory fsync failure")
        real_fsync(fd)

    os.fsync = fail_directory_fsync
PY
  cat >"$pass_fixture" <<'SH'
#!/usr/bin/env bash
printf 'ok - completed before publication failure\n'
SH
  cat >"$interrupt_fixture" <<'SH'
#!/usr/bin/env bash
kill -TERM "$PPID"
while :; do sleep 1; done
SH
  chmod +x "$pass_fixture" "$interrupt_fixture"

  journal="$tmp/pass-journal"
  set +e
  FAIL_RUN_STATE=passed PYTHONPATH="$python_path" \
    "$RUNNER" --progress-journal "$journal" "$pass_fixture" >"$tmp/pass.out" 2>"$tmp/pass.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { cat "$tmp/pass.out" "$tmp/pass.err"; rm -rf "$tmp"; fail "terminal publication failure left a green exit"; }
  grep -Fq 'injected directory fsync failure' "$tmp/pass.err" \
    || { cat "$tmp/pass.err"; rm -rf "$tmp"; fail "green run did not surface its terminal publication failure"; }
  run_dir=$(journal_run_dir "$journal")
  assert_journal_run "$run_dir/run.json" passed 0 1 serial "$pass_fixture" \
    || { rm -rf "$tmp"; fail "terminal replacement did not precede its failed durability barrier"; }

  journal="$tmp/interrupt-journal"
  set +e
  FAIL_RUN_STATE=interrupted PYTHONPATH="$python_path" \
    "$RUNNER" --progress-journal "$journal" "$interrupt_fixture" >"$tmp/interrupt.out" 2>"$tmp/interrupt.err"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { cat "$tmp/interrupt.out" "$tmp/interrupt.err"; rm -rf "$tmp"; fail "terminal publication failure replaced interrupt exit with $rc"; }
  grep -Fq 'injected directory fsync failure' "$tmp/interrupt.err" \
    || { cat "$tmp/interrupt.err"; rm -rf "$tmp"; fail "interrupted run did not surface its terminal publication failure"; }
  rm -rf "$tmp"
  pass "terminal publication failure changes only an otherwise-green exit"
}

test_progress_journal_requires_durable_run_directory_chain() {
  local tmp journal fixture rc real_python run_dir
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-directory-barrier.XXXXXX")
  journal="$tmp/existing/new-a/new-b/journal"
  fixture="$tmp/pass.test.sh"
  real_python=$(command -v python3)
  mkdir -p "$tmp/bin" "$tmp/existing"
  cat >"$tmp/bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = - ] && [ "${2:-}" = sync-directories ]; then
  shift 2
  printf '%s\n' "$@" >"$BARRIER_EVIDENCE"
  exit 73
fi
exec "$REAL_PYTHON" "$@"
SH
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'not ok - initialization barrier should prevent launch\n'
exit 1
SH
  chmod +x "$tmp/bin/python3" "$fixture"
  set +e
  BARRIER_EVIDENCE="$tmp/barriers" REAL_PYTHON="$real_python" PATH="$tmp/bin:$PATH" \
    "$RUNNER" --progress-journal "$journal" "$fixture" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "directory barrier failure should fail initialization with 2, got $rc"; }
  grep -Fq 'could not make progress journal durable' "$tmp/err" \
    || { cat "$tmp/err"; rm -rf "$tmp"; fail "directory barrier failure was not actionable"; }
  run_dir=$(find "$journal/runs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [ -n "$run_dir" ] || { rm -rf "$tmp"; fail "directory barrier fixture did not publish a run directory"; }
  [ "$(sed -n '1p' "$tmp/barriers")" = "$run_dir/events" ] \
    && [ "$(sed -n '2p' "$tmp/barriers")" = "$run_dir/states" ] \
    && [ "$(sed -n '3p' "$tmp/barriers")" = "$run_dir" ] \
    && [ "$(sed -n '4p' "$tmp/barriers")" = "$journal/runs" ] \
    && [ "$(sed -n '5p' "$tmp/barriers")" = "$journal" ] \
    && [ "$(sed -n '6p' "$tmp/barriers")" = "$tmp/existing/new-a/new-b" ] \
    && [ "$(sed -n '7p' "$tmp/barriers")" = "$tmp/existing/new-a" ] \
    && [ "$(sed -n '8p' "$tmp/barriers")" = "$tmp/existing" ] \
    || { cat "$tmp/barriers"; rm -rf "$tmp"; fail "directory barrier omitted the published run chain"; }
  [ ! -e "$run_dir/run.json" ] \
    || { rm -rf "$tmp"; fail "run state published after its directory barrier failed"; }
  rm -rf "$tmp"
  pass "progress journal requires the published run directory chain to be durable"
}

test_progress_journal_restores_caller_umask() {
  local tmp journal fixture timing fixture_mode timing_mode
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-umask.XXXXXX")
  journal="$tmp/journal"
  fixture="$tmp/pass.test.sh"
  timing="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
: >"$SCHED_EVIDENCE/fixture-created"
printf 'ok - caller umask preserved\n'
SH
  chmod +x "$fixture"
  (umask 022 && SCHED_EVIDENCE="$tmp" "$RUNNER" --progress-journal "$journal" \
    --json "$timing" "$fixture") >"$tmp/out" 2>"$tmp/err" \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "umask fixture should pass"; }
  fixture_mode=$(stat -c %a "$tmp/fixture-created" 2>/dev/null || stat -f %Lp "$tmp/fixture-created")
  timing_mode=$(stat -c %a "$timing" 2>/dev/null || stat -f %Lp "$timing")
  [ "$fixture_mode" = 644 ] \
    || { rm -rf "$tmp"; fail "journal changed test-created file mode to $fixture_mode"; }
  [ "$timing_mode" = 644 ] \
    || { rm -rf "$tmp"; fail "journal changed timing artifact mode to $timing_mode"; }
  rm -rf "$tmp"
  pass "progress journal restores the caller umask"
}

test_progress_journal_disabled_mode_has_no_filesystem_effect() {
  local tmp fixture absent
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-progress-disabled.XXXXXX")
  fixture="$tmp/pass.test.sh"
  absent="$tmp/not-created"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
printf 'ok - disabled journal pass\n'
SH
  chmod +x "$fixture"
  "$RUNNER" "$fixture" >"$tmp/out" 2>"$tmp/err" \
    || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "disabled journal fixture should pass"; }
  [ ! -e "$absent" ] || { rm -rf "$tmp"; fail "runner created progress state without --progress-journal"; }
  grep -Fq 'FM_TEST_SUMMARY total=1 failed=0' "$tmp/out" \
    || { rm -rf "$tmp"; fail "disabled journal changed normal summary output"; }
  rm -rf "$tmp"
  pass "progress journal is fully disabled unless selected"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_empty_selection_emits_summary
test_empty_selection_preserves_disabled_fast_path
test_timing_markers_and_json
test_quoting_and_platform_temp_paths
test_stock_bash_wrapper_pins_nested_runner
test_parallel_child_can_signal_immediately
test_interrupt_drains_serial_cleanup
test_interrupt_cleans_parallel_process_tree
test_interrupt_waits_for_parallel_cleanup
test_completed_parallel_worker_drains_process_group
test_aggregate_exit_behavior
test_gate_skip_accounting
test_runtime_gate_required_and_optional_outcomes
test_runtime_gate_selection_validation_and_real_test_mapping
test_runtime_gate_declaration_parser_refuses_malformed_input
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_shard_lane_refusals
test_jobs_requires_proven_isolated
test_jobs_parallel_scheduler_and_failure_propagation
test_aggregate_json
test_progress_journal_terminal_transitions_and_atomic_state
test_progress_journal_parallel_workers_preserve_transitions
test_progress_journal_ignores_malformed_prior_state
test_progress_journal_marks_abrupt_interruptions
test_progress_journal_does_not_advance_state_after_event_failure
test_progress_journal_closes_startup_signal_windows
test_progress_journal_defers_initialization_signal_until_started
test_progress_journal_preserves_post_terminal_signal_outcome
test_progress_journal_publishes_adjudicated_outcome_before_bookkeeping
test_progress_journal_terminal_publication_failure_changes_only_green_exit
test_progress_journal_requires_durable_run_directory_chain
test_progress_journal_restores_caller_umask
test_progress_journal_disabled_mode_has_no_filesystem_effect
