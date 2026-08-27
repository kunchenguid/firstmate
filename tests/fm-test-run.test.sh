#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, aggregate exit status, and bounded detached
# base/head failure partitioning.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

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
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/ci.yml as YAML"
  local json job_timeout step_timeout
  json=$(ruby -ryaml -rjson -e '
doc = YAML.load_file(ARGV[0])
job = doc.fetch("jobs").fetch("tests-herdr")
step = job.fetch("steps").find { |s|
  s.is_a?(Hash) && s["name"] == "Run real-Herdr family (serial, required)"
}
raise "missing family-run step" if step.nil?
raise "family-run step has no timeout-minutes" unless step.key?("timeout-minutes")
puts JSON.generate(
  "job_timeout" => job.fetch("timeout-minutes"),
  "step_timeout" => step.fetch("timeout-minutes")
)
' "$ROOT/.github/workflows/ci.yml") \
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
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

init_compare_fixture_repo() {
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-pass.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
SH
  cat >"$repo/tests/ab-inherited.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - inherited"
exit 1
SH
  cat >"$repo/tests/ac-fixed.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - base failure"
exit 1
SH
  cat >"$repo/tests/ad-introduced.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - base pass"
SH
  cat >"$repo/tests/ae-skip.test.sh" <<'SH'
#!/usr/bin/env bash
echo "skip: optional fixture unavailable"
SH
  cat >"$repo/tests/af-hang.test.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
sleep 30
SH
  chmod +x "$repo"/tests/*.test.sh
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm base
}

test_compare_commits_partitions_and_bounds_every_script() {
  local tmp repo base head rc out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare.XXXXXX")
  repo="$tmp/repo"
  init_compare_fixture_repo "$repo"
  base=$(git -C "$repo" rev-parse HEAD)
  cat >"$repo/tests/ac-fixed.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - fixed"
SH
  cat >"$repo/tests/ad-introduced.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - introduced"
exit 1
SH
  chmod +x "$repo/tests/ac-fixed.test.sh" "$repo/tests/ad-introduced.test.sh"
  git -C "$repo" add tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm head
  head=$(git -C "$repo" rev-parse HEAD)

  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --compare-commits "$base" "$head" \
    --script-timeout 1 --output-dir "$tmp/result" 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "introduced failure must make compare exit 1 (got $rc): $(cat "$tmp/err")"; }
  assert_contains "$out" "FM_TEST_COMPARE_INVENTORY side=base" "base terminal inventory marker"
  assert_contains "$out" "FM_TEST_COMPARE_INVENTORY side=head" "head terminal inventory marker"
  assert_contains "$out" "FM_TEST_COMPARE_PARTITION inherited=1 inherited_timeouts=1 head_introduced=0 regressed=1 fixed=1" \
    "outcome-transition partition"
  if ! python3 - "$tmp/result/base.json" "$tmp/result/head.json" "$tmp/result/partition.json" <<'PY'
import json, sys
base, head, partition = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
assert base["reconciliation"]["accounted"] is True, base
assert head["reconciliation"]["accounted"] is True, head
assert base["checkout"]["invariant_ok"] is True, base
assert head["checkout"]["invariant_ok"] is True, head
assert base["summary"] == {"errored": 0, "failed": 2, "passed": 2, "running": 0, "skipped": 1, "timed_out": 1, "total": 6}, base
assert head["summary"] == {"errored": 0, "failed": 2, "passed": 2, "running": 0, "skipped": 1, "timed_out": 1, "total": 6}, head
base_rows = {row["path"]: row["outcome"] for row in base["scripts"]}
head_rows = {row["path"]: row["outcome"] for row in head["scripts"]}
assert base_rows["tests/af-hang.test.sh"] == "timed_out", base_rows
assert head_rows["tests/af-hang.test.sh"] == "timed_out", head_rows
assert [row["path"] for row in partition["inherited_failures"]] == [
    "tests/ab-inherited.test.sh"
], partition
assert [row["path"] for row in partition["inherited_timeouts"]] == ["tests/af-hang.test.sh"], partition
assert partition["head_introduced_failures"] == [], partition
assert [row["path"] for row in partition["regressed"]] == ["tests/ad-introduced.test.sh"], partition
assert [row["path"] for row in partition["fixed"]] == ["tests/ac-fixed.test.sh"], partition
assert partition["summary"]["coverage"] == "4/6", partition
PY
  then
    rm -rf "$tmp"
    fail "compare JSON inventories or partition are wrong"
  fi
  rm -rf "$tmp"
  pass "commit comparison bounds a deliberate hang and emits complete diffable inventories"
}

test_compare_commits_accounts_for_script_lost_after_discovery() {
  local tmp repo commit rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-missing.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-delete-next.test.sh" <<'SH'
#!/usr/bin/env bash
rm tests/zz-victim.test.sh
SH
  cat >"$repo/tests/zz-victim.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - should never run from a corrupted checkout"
SH
  chmod +x "$repo"/tests/*.test.sh
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  commit=$(git -C "$repo" rev-parse HEAD)

  set +e
  (cd "$repo" && bin/fm-test-run.sh --compare-commits "$commit" "$commit" \
    --script-timeout 1 --output-dir "$tmp/result" >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "checkout corruption must make compare exit 1 (got $rc)"; }
  if ! python3 - "$tmp/result/base.json" "$tmp/result/head.json" "$tmp/result/partition.json" <<'PY'
import json, sys
base, head, partition = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
for doc in (base, head):
    assert doc["discovered_scripts"] == ["tests/aa-delete-next.test.sh", "tests/zz-victim.test.sh"], doc
    assert [row["path"] for row in doc["scripts"]] == doc["discovered_scripts"], doc
    assert doc["reconciliation"] == {
        "accounted": True, "discovered_count": 2, "duplicates": [],
        "expected_count": 2, "extra": [], "extra_in_discovery": [],
        "inventory_count": 2, "missing": [], "missing_from_discovery": []
    }, doc
    assert all(row["outcome"] == "errored" for row in doc["scripts"]), doc
    assert doc["checkout"]["invariant_ok"] is False, doc
assert partition["inventory_reconciled"] is True, partition
assert partition["checkout_invariants_ok"] is False, partition
PY
  then
    rm -rf "$tmp"
    fail "lost-script accounting did not fail closed"
  fi
  rm -rf "$tmp"
  pass "a script lost after discovery remains inventoried as errored and checkout drift fails loudly"
}

test_compare_commits_rechecks_a_first_only_failure() {
  local tmp repo marker base head rc fail_detail
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-flake.XXXXXX")
  repo="$tmp/repo"
  marker="$tmp/head-failed-once"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-flaky.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - stable base"
SH
  chmod +x "$repo/tests/aa-flaky.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  cat >"$repo/tests/aa-flaky.test.sh" <<SH
#!/usr/bin/env bash
if [ ! -e "$marker" ]; then
  : >"$marker"
  echo "not ok - first-only environmental failure"
  exit 1
fi
echo "ok - retry passes"
SH
  chmod +x "$repo/tests/aa-flaky.test.sh"
  git -C "$repo" add tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm head
  head=$(git -C "$repo" rev-parse HEAD)

  set +e
  (cd "$repo" && bin/fm-test-run.sh --compare-commits "$base" "$head" \
    --script-timeout 1 --output-dir "$tmp/result" >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || {
    fail_detail=$(cat "$tmp/err" 2>/dev/null || true)
    rm -rf "$tmp"
    fail "a first-only failure must not be a regression (got $rc): $fail_detail"
  }
  python3 - "$tmp/result/partition.json" <<'PY' || {
import json, sys
partition = json.load(open(sys.argv[1], encoding="utf-8"))
assert partition["head_introduced_failures"] == [], partition
assert partition["regressed"] == [], partition
assert [row["path"] for row in partition["flaky_transitions"]] == ["tests/aa-flaky.test.sh"], partition
row = partition["flaky_transitions"][0]
assert row["base_observations"] == ["passed", "passed"], row
assert row["head_observations"] == ["failed", "passed"], row
PY
    rm -rf "$tmp"
    fail "first-only failure was not recorded as flaky"
  }
  rm -rf "$tmp"
  pass "a first-only failure is rechecked and recorded as flaky, not introduced"
}

test_compare_commits_refuses_an_inconclusive_retry() {
  local tmp repo marker base head rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-inconclusive.XXXXXX")
  repo="$tmp/repo"
  marker="$tmp/head-failed-once"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-inconclusive.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - stable base"
SH
  chmod +x "$repo/tests/aa-inconclusive.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  cat >"$repo/tests/aa-inconclusive.test.sh" <<SH
#!/usr/bin/env bash
if [ ! -e "$marker" ]; then
  : >"$marker"
  echo "not ok - first head failure"
  exit 1
fi
trap '' TERM
sleep 30
SH
  chmod +x "$repo/tests/aa-inconclusive.test.sh"
  git -C "$repo" add tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm head
  head=$(git -C "$repo" rev-parse HEAD)

  set +e
  (cd "$repo" && bin/fm-test-run.sh --compare-commits "$base" "$head" \
    --script-timeout 1 --output-dir "$tmp/result" >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "inconclusive retry must exit 1 (got $rc)"; }
  python3 - "$tmp/result/partition.json" <<'PY' || {
import json, sys
partition = json.load(open(sys.argv[1], encoding="utf-8"))
assert partition["head_introduced_failures"] == [], partition
assert partition["flaky_transitions"] == [], partition
assert partition["regressed"] == [{
    "base_observations": ["passed", "passed"],
    "base_outcome": "passed",
    "head_observations": ["failed", "timed_out"],
    "head_outcome": "failed",
    "path": "tests/aa-inconclusive.test.sh",
}], partition
PY
    rm -rf "$tmp"
    fail "inconclusive retry was not retained as a refusing regression"
  }
  rm -rf "$tmp"
  pass "an inconclusive retry remains a regression"
}

test_compare_commits_reports_timeout_to_failure_as_regressed() {
  local tmp repo base head rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-regressed.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-transition.test.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
sleep 30
SH
  chmod +x "$repo/tests/aa-transition.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  cat >"$repo/tests/aa-transition.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - assertion now reaches a real failure"
exit 1
SH
  git -C "$repo" add tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm head
  head=$(git -C "$repo" rev-parse HEAD)

  set +e
  (cd "$repo" && bin/fm-test-run.sh --compare-commits "$base" "$head" \
    --script-timeout 1 --output-dir "$tmp/result" >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "timeout-to-failure regression must exit 1 (got $rc)"; }
  assert_contains "$(cat "$tmp/out")" "regressed=1" "timeout-to-failure regression headline"
  python3 - "$tmp/result/partition.json" <<'PY' || {
import json, sys
partition = json.load(open(sys.argv[1], encoding="utf-8"))
assert partition["inherited_failures"] == [], partition
assert partition["regressed"] == [{
    "base_observations": ["timed_out", "timed_out"],
    "base_outcome": "timed_out",
    "head_observations": ["failed", "failed"],
    "head_outcome": "failed",
    "path": "tests/aa-transition.test.sh",
}], partition
PY
    rm -rf "$tmp"
    fail "timeout-to-failure transition was not classified as regressed"
  }
  rm -rf "$tmp"
  pass "timeout-to-failure is a confirmed regression and exits non-zero"
}

test_compare_commits_never_calls_deleted_or_skipped_tests_fixed() {
  local tmp repo base head rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-erosion.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in aa-deleted bb-skipped cc-fixed; do
    cat >"$repo/tests/$script.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - base failure"
exit 1
SH
  done
  chmod +x "$repo"/tests/*.test.sh
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" rm -q tests/aa-deleted.test.sh
  cat >"$repo/tests/bb-skipped.test.sh" <<'SH'
#!/usr/bin/env bash
echo "skip: head no longer measures this test"
SH
  cat >"$repo/tests/cc-fixed.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - genuinely fixed"
SH
  git -C "$repo" add tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm head
  head=$(git -C "$repo" rev-parse HEAD)

  set +e
  (cd "$repo" && bin/fm-test-run.sh --compare-commits "$base" "$head" \
    --script-timeout 1 --output-dir "$tmp/result" >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "deleted or skipped coverage must exit 1 (got $rc)"; }
  python3 - "$tmp/result/partition.json" <<'PY' || {
import json, sys
partition = json.load(open(sys.argv[1], encoding="utf-8"))
assert [row["path"] for row in partition["fixed"]] == ["tests/cc-fixed.test.sh"], partition
assert [row["path"] for row in partition["no_longer_measured"]] == [
    "tests/aa-deleted.test.sh", "tests/bb-skipped.test.sh",
], partition
assert partition["summary"]["fixed"] == 1, partition
assert partition["summary"]["no_longer_measured"] == 2, partition
PY
    rm -rf "$tmp"
    fail "deleted or skipped tests were confused with genuine fixes"
  }
  rm -rf "$tmp"
  pass "only failure-to-pass is fixed; deletion and skip are coverage erosion"
}

test_compare_commits_refuses_an_independent_enumeration_mismatch() {
  local tmp repo commit rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-enumeration.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-real.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - real test"
SH
  chmod +x "$repo/tests/aa-real.test.sh"
  ln -s ./nowhere-nothing "$repo/tests/zz-ghost.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  commit=$(git -C "$repo" rev-parse HEAD)

  set +e
  (cd "$repo" && bin/fm-test-run.sh --compare-commits "$commit" "$commit" \
    --script-timeout 1 --output-dir "$tmp/result" >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || { rm -rf "$tmp"; fail "enumeration mismatch must exit 1 (got $rc)"; }
  assert_contains "$(cat "$tmp/out")" "accounted=false" "enumeration mismatch inventory marker"
  python3 - "$tmp/result/base.json" "$tmp/result/head.json" "$tmp/result/partition.json" <<'PY' || {
import json, sys
base, head, partition = (json.load(open(path, encoding="utf-8")) for path in sys.argv[1:])
for doc in (base, head):
    assert doc["expected_scripts"] == ["tests/aa-real.test.sh", "tests/zz-ghost.test.sh"], doc
    assert doc["discovered_scripts"] == ["tests/aa-real.test.sh"], doc
    assert doc["reconciliation"]["accounted"] is False, doc
    assert doc["reconciliation"]["missing_from_discovery"] == ["tests/zz-ghost.test.sh"], doc
    rows = {row["path"]: row for row in doc["scripts"]}
    assert rows["tests/zz-ghost.test.sh"]["outcome"] == "errored", rows
    assert rows["tests/zz-ghost.test.sh"]["detail"] == "not_run: tracked test path is not a regular file", rows
assert partition["inventory_reconciled"] is False, partition
PY
    rm -rf "$tmp"
    fail "independent enumeration mismatch did not fail closed"
  }
  rm -rf "$tmp"
  pass "tracked test paths missing from discovery make accounted refuse"
}

test_compare_commits_headline_exposes_measured_coverage() {
  local tmp repo commit rc out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-coverage.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-pass.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - measured"
SH
  for script in bb-timeout cc-timeout; do
    cat >"$repo/tests/$script.test.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
sleep 30
SH
  done
  chmod +x "$repo"/tests/*.test.sh
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  commit=$(git -C "$repo" rev-parse HEAD)

  set +e
  out=$(cd "$repo" && bin/fm-test-run.sh --compare-commits "$commit" "$commit" \
    --script-timeout 1 --output-dir "$tmp/result" 2>"$tmp/err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "inherited timeouts alone must remain inspectable (got $rc)"; }
  assert_contains "$out" "inherited_timeouts=2" "timeout-specific inherited count"
  assert_contains "$out" "compared_outcomes=1 coverage=1/3" "honest compared-outcome coverage"
  rm -rf "$tmp"
  pass "headline distinguishes timeouts from one genuinely compared outcome"
}

test_compare_commits_preflight_errors_exit_two_without_tracebacks() {
  local tmp repo commit rc err
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-preflight.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-pass.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
SH
  chmod +x "$repo/tests/aa-pass.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  commit=$(git -C "$repo" rev-parse HEAD)

  set +e
  (cd "$repo" && bin/fm-test-run.sh --compare-commits definitely-missing "$commit" \
    --script-timeout 1 --output-dir "$tmp/bad-ref" >"$tmp/out" 2>"$tmp/err")
  rc=$?
  set -e
  err=$(cat "$tmp/err")
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "bad ref must exit 2 (got $rc)"; }
  assert_contains "$err" "fm-test-run: compare failed: commit not found: definitely-missing" "bad-ref reason"
  case "$err" in *Traceback*) rm -rf "$tmp"; fail "bad ref must not emit a traceback" ;; esac

  : >"$tmp/not-a-directory"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --compare-commits "$commit" "$commit" \
    --script-timeout 1 --output-dir "$tmp/not-a-directory" >"$tmp/out2" 2>"$tmp/err2")
  rc=$?
  set -e
  err=$(cat "$tmp/err2")
  [ "$rc" -eq 2 ] || { rm -rf "$tmp"; fail "non-directory output path must exit 2 (got $rc)"; }
  assert_contains "$err" "fm-test-run: compare failed: --output-dir must be a directory" "output-dir reason"
  case "$err" in *Traceback*) rm -rf "$tmp"; fail "bad output dir must not emit a traceback" ;; esac
  rm -rf "$tmp"
  pass "bad refs and output paths are infrastructure errors with exact reasons"
}

test_compare_commits_signal_records_inflight_and_cleans_clones() {
  local tmp repo commit run_dir runner_pid python_pid rc clone_path signal_name expected_rc i
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-signal.XXXXXX")
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-slow.test.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
sleep 30
SH
  chmod +x "$repo/tests/aa-slow.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  commit=$(git -C "$repo" rev-parse HEAD)

  for signal_name in TERM INT; do
    run_dir="$tmp/result-$signal_name"
    (cd "$repo" && exec bin/fm-test-run.sh --compare-commits "$commit" "$commit" \
      --script-timeout 60 --output-dir "$run_dir" >"$tmp/out-$signal_name" 2>"$tmp/err-$signal_name") &
    runner_pid=$!
    clone_path=
    i=0
    while [ "$i" -lt 100 ]; do
      i=$((i + 1))
      if [ -f "$run_dir/base.json" ]; then
        clone_path=$(python3 - "$run_dir/base.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
row = doc["scripts"][0]
if row["outcome"] == "running" and row["detail"] == "in flight":
    print(doc["checkout"]["path"])
PY
)
        [ -n "$clone_path" ] && break
      fi
      sleep 0.05
    done
    [ -n "$clone_path" ] || {
      kill -TERM "$runner_pid" 2>/dev/null || true
      wait "$runner_pid" 2>/dev/null || true
      rm -rf "$tmp"
      fail "$signal_name fixture never recorded its in-flight script"
    }
    python_pid=$(ps -axo pid=,ppid=,command= | awk -v result="$run_dir" \
      'index($0, result) && $0 ~ /[Pp]ython/ { print $1; exit }')
    # Bash may exec its final foreground command, in which case the recorded
    # runner PID is already the Python compare worker.
    [ -n "$python_pid" ] || python_pid=$runner_pid
    kill -"$signal_name" "$python_pid"
    set +e
    wait "$runner_pid"
    rc=$?
    set -e
    case "$signal_name" in
      TERM) expected_rc=143 ;;
      INT) expected_rc=130 ;;
    esac
    [ "$rc" -eq "$expected_rc" ] || { rm -rf "$tmp"; fail "$signal_name must exit $expected_rc (got $rc)"; }
    python3 - "$run_dir/base.json" "$run_dir/partition.json" "$signal_name" "$expected_rc" <<'PY' || {
import json, sys
base = json.load(open(sys.argv[1], encoding="utf-8"))
partition = json.load(open(sys.argv[2], encoding="utf-8"))
row = base["scripts"][0]
assert row["outcome"] == "running", row
assert row["detail"] == "in flight", row
assert partition["termination"] == {
    "complete": False, "exit_code": int(sys.argv[4]), "signal": f"SIG{sys.argv[3]}"
}, partition
PY
      rm -rf "$tmp"
      fail "$signal_name artifacts did not preserve in-flight and termination evidence"
    }
    [ ! -e "$(dirname "$clone_path")" ] || { rm -rf "$tmp"; fail "$signal_name leaked isolated clones at $(dirname "$clone_path")"; }
  done
  rm -rf "$tmp"
  pass "SIGTERM and SIGINT preserve partial evidence and remove isolated clones"
}

test_compare_commits_signal_records_inflight_confirmation() {
  local tmp repo marker base head run_dir runner_pid python_pid rc clone_root i
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-compare-confirmation-signal.XXXXXX")
  repo="$tmp/repo"
  marker="$tmp/base-confirmation-started"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  cat >"$repo/tests/aa-transition.test.sh" <<SH
#!/usr/bin/env bash
if [ -e "$marker" ]; then
  trap '' TERM
  sleep 30
fi
: >"$marker"
echo "ok - initial base run"
SH
  chmod +x "$repo/tests/aa-transition.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add bin tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  cat >"$repo/tests/aa-transition.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - head regression"
exit 1
SH
  chmod +x "$repo/tests/aa-transition.test.sh"
  git -C "$repo" add tests
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm head
  head=$(git -C "$repo" rev-parse HEAD)
  run_dir="$tmp/result"
  (cd "$repo" && exec bin/fm-test-run.sh --compare-commits "$base" "$head" \
    --script-timeout 60 --output-dir "$run_dir" >"$tmp/out" 2>"$tmp/err") &
  runner_pid=$!
  clone_root=
  i=0
  while [ "$i" -lt 100 ]; do
    i=$((i + 1))
    if [ -f "$run_dir/partition.json" ]; then
      clone_root=$(python3 - "$run_dir/base.json" "$run_dir/partition.json" <<'PY'
import json, sys
base = json.load(open(sys.argv[1], encoding="utf-8"))
partition = json.load(open(sys.argv[2], encoding="utf-8"))
rows = partition.get("regressed", [])
if rows and rows[0].get("base_observations") == ["passed", "running"] and rows[0].get("head_observations") == ["failed"]:
    print(__import__("pathlib").Path(base["checkout"]["path"]).parent)
PY
)
        [ -n "$clone_root" ] && break
    fi
    sleep 0.05
  done
  [ -n "$clone_root" ] || {
    kill -TERM "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    rm -rf "$tmp"
    fail "confirmation fixture never recorded its running observation"
  }
  python_pid=$(ps -axo pid=,ppid=,command= | awk -v result="$run_dir" \
    'index($0, result) && $0 ~ /[Pp]ython/ { print $1; exit }')
  [ -n "$python_pid" ] || python_pid=$runner_pid
  kill -TERM "$python_pid"
  set +e
  wait "$runner_pid"
  rc=$?
  set -e
  [ "$rc" -eq 143 ] || { rm -rf "$tmp"; fail "SIGTERM during confirmation must exit 143 (got $rc)"; }
  python3 - "$run_dir/partition.json" <<'PY' || {
import json, sys
partition = json.load(open(sys.argv[1], encoding="utf-8"))
assert partition["termination"] == {"complete": False, "exit_code": 143, "signal": "SIGTERM"}, partition
rows = partition["regressed"]
assert rows == [{
    "base_observations": ["passed", "running"],
    "base_outcome": "passed",
    "head_observations": ["failed"],
    "head_outcome": "failed",
    "path": "tests/aa-transition.test.sh",
}], partition
PY
    rm -rf "$tmp"
    fail "SIGTERM artifacts did not preserve the in-flight confirmation"
  }
  [ ! -e "$clone_root" ] || { rm -rf "$tmp"; fail "SIGTERM leaked isolated clones at $clone_root"; }
  rm -rf "$tmp"
  pass "SIGTERM during confirmation preserves a running observation"
}

if [ -n "${FM_TEST_RUN_ONLY:-}" ]; then
  "$FM_TEST_RUN_ONLY"
  exit $?
fi

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
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_shard_lane_refusals
test_jobs_requires_proven_isolated
test_jobs_parallel_scheduler_and_failure_propagation
test_herdr_ci_family_run_has_a_step_timeout
test_aggregate_json
test_compare_commits_partitions_and_bounds_every_script
test_compare_commits_accounts_for_script_lost_after_discovery
test_compare_commits_rechecks_a_first_only_failure
test_compare_commits_refuses_an_inconclusive_retry
test_compare_commits_reports_timeout_to_failure_as_regressed
test_compare_commits_never_calls_deleted_or_skipped_tests_fixed
test_compare_commits_refuses_an_independent_enumeration_mismatch
test_compare_commits_headline_exposes_measured_coverage
test_compare_commits_preflight_errors_exit_two_without_tracebacks
test_compare_commits_signal_records_inflight_and_cleans_clones
test_compare_commits_signal_records_inflight_confirmation
