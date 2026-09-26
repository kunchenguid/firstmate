#!/usr/bin/env bash
# Behavior tests for CI test-evidence log verification.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-ci-test-evidence.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-test-evidence)

# The fake replays gh-axi 0.1.35 transcripts: api rows arrive in an
# `api_response:` envelope and job logs in a `run_log:` envelope whose tail is
# cut at 20000 chars, with the whole log saved at `full_log`.
make_fixture() {
  local dir=$1
  mkdir -p "$dir/fakebin" "$dir/tmp"
  printf 'Integration tests\tRun unit\t\357\273\2772026-09-12T22:06:35.2761040Z ======== 50 passed, 3 skipped in 5.00s ========\nIntegration tests\tRun integration\t2026-09-12T22:07:05.2761040Z ======== 120 passed in 30.00s ========\n' > "$dir/full-12.log"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
fixture=${0%/fakebin/gh-axi}
body() { printf '%s\n' 'api_response:' "  body: $1" '  truncated: false'; }
log() { printf '%s\n' 'run_log:' "  run: \"$1\"" '  mode: log' "  output: $2" '  truncated: false'; }
case "$1 ${2:-}" in
  'api '*)
    case " $* " in *' --full '*) ;; *) exit 1 ;; esac
    case "$2" in
      /repos/acme/market-pulse/pulls/458) body '"head\th458"' ;;
      '/repos/acme/market-pulse/actions/runs?event=pull_request&head_sha=h458&per_page=100') body '"run\t101"' ;;
      '/repos/acme/market-pulse/actions/runs/101/jobs?per_page=100') body '"job\t2026-09-13T10:00:00Z\t101\t11\tIntegration tests\tsuccess\njob\t2026-09-13T10:00:00Z\t101\t17\tBackend - Unit Tests\tsuccess\njob\t2026-09-13T10:00:00Z\t101\t18\tMCP - Build, Type Check & Tests\tsuccess"' ;;
      /repos/acme/market-pulse/pulls/459) body '"head\th459"' ;;
      '/repos/acme/market-pulse/actions/runs?event=pull_request&head_sha=h459&per_page=100') body '"run\t201\nrun\t202"' ;;
      '/repos/acme/market-pulse/actions/runs/201/jobs?per_page=100') body '"job\t2026-09-13T10:00:00Z\t201\t11\tIntegration tests\tsuccess"' ;;
      '/repos/acme/market-pulse/actions/runs/202/jobs?per_page=100') body '"job\t2026-09-13T11:00:00Z\t202\t22\tIntegration tests\tskipped"' ;;
      /repos/acme/market-pulse/pulls/460) body '"head\th460"' ;;
      '/repos/acme/market-pulse/actions/runs?event=pull_request&head_sha=h460&per_page=100') body '"run\t302\nrun\t301"' ;;
      '/repos/acme/market-pulse/actions/runs/301/jobs?per_page=100') body '"job\t2026-09-13T10:00:00Z\t301\t31\tIntegration tests\tskipped\njob\t2026-09-13T10:00:00Z\t301\t17\tBackend - Unit Tests\tsuccess"' ;;
      '/repos/acme/market-pulse/actions/runs/302/jobs?per_page=100') body '"job\t2026-09-13T11:00:00Z\t302\t11\tIntegration tests\tsuccess"' ;;
      '/repos/acme/repo/actions/runs/481/jobs?per_page=100') body '"job\t2026-09-13T10:00:00Z\t481\t12\tIntegration tests\tsuccess\njob\t2026-09-13T10:00:00Z\t481\t13\tBrowser tests\tsuccess\njob\t2026-09-13T10:00:00Z\t481\t14\tCollection tests\tfailure\njob\t2026-09-13T10:00:00Z\t481\t15\tGo tests\tsuccess\njob\t2026-09-13T10:00:00Z\t481\t16\tStill running\t\njob\t2026-09-13T10:00:00Z\t481\t19\tMobile - Type Check & Tests\tsuccess\njob\t2026-09-13T10:00:00Z\t481\t20\tWeb - Lint, Type Check & Build\tsuccess\njob\t2026-09-13T10:00:05Z\t481\t21\tWeb - E2E Tests (Playwright)\tsuccess\njob\t2026-09-13T10:00:00Z\t481\t22\tBackend - Unit Tests\tfailure\njob\t2026-09-13T10:00:00Z\t481\t23\tMCP - Build, Type Check & Tests\tfailure"' ;;
      /repos/double-d-labs/go-easy-homie/pulls/481) body '"head\tf555c27acbe817beed5ea54d8aa8639d3a77d83f"' ;;
      '/repos/double-d-labs/go-easy-homie/actions/runs?event=pull_request&head_sha=f555c27acbe817beed5ea54d8aa8639d3a77d83f&per_page=100') body '"run\t34721814954\nrun\t34721814948\nrun\t34721814926"' ;;
      '/repos/double-d-labs/go-easy-homie/actions/runs/34721814954/jobs?per_page=100') body '"job\t2026-09-12T22:06:28Z\t34721814954\t103628992346\tMCP - Build, Type Check & Tests\tsuccess"' ;;
      '/repos/double-d-labs/go-easy-homie/actions/runs/34721814948/jobs?per_page=100') body '"job\t2026-09-12T22:06:28Z\t34721814948\t103628992350\tWeb Security Scan\tsuccess\njob\t2026-09-12T22:06:28Z\t34721814948\t103628992409\tMobile Security Scan\tsuccess\njob\t2026-09-12T22:06:28Z\t34721814948\t103628992421\tBackend Security Scan\tsuccess\njob\t2026-09-12T22:06:29Z\t34721814948\t103628992427\tSecrets Detection\tsuccess"' ;;
      '/repos/double-d-labs/go-easy-homie/actions/runs/34721814926/jobs?per_page=100') body '"job\t2026-09-12T22:06:28Z\t34721814926\t103628992271\tDetect changed packages\tsuccess\njob\t2026-09-12T22:06:29Z\t34721814926\t103628992751\tWeb - Lint, Type Check & Build\tskipped\njob\t2026-09-12T22:06:29Z\t34721814926\t103628992888\tBackend - Lint, Type Check & Build\tskipped\njob\t2026-09-12T22:06:29Z\t34721814926\t103628992957\tBackend - Unit Tests\tskipped\njob\t2026-09-12T22:06:29Z\t34721814926\t103628993171\tWeb - E2E Tests (Playwright)\tskipped\njob\t2026-09-12T22:06:29Z\t34721814926\t103628993607\tMobile - Type Check & Tests\tskipped\njob\t2026-09-12T22:06:37Z\t34721814926\t103629008439\tDevelop slim - Web lint & type check (tests run locally)\tsuccess\njob\t2026-09-12T22:06:37Z\t34721814926\t103629008440\tDevelop slim - Backend lint & type check (tests run locally)\tsuccess\njob\t2026-09-12T22:06:37Z\t34721814926\t103629008448\tDevelop slim - Mobile type check (tests run locally)\tsuccess\njob\t2026-09-12T22:07:34Z\t34721814926\t103629129467\tCI gate\tsuccess"' ;;
      *) exit 1 ;;
    esac
    ;;
  'run view')
    case " $* " in
      *' --job 11 '*) log "$2" '"Integration tests\tRun tests\t2026-09-12T22:06:35.2761040Z ======== 2366 passed in 40.00s ========\n"' ;;
      *' --job 12 '*)
        full_log=$(mktemp -d "${TMPDIR:-/tmp}/gh-axi-logs-XXXXXX")/$2-job-12-log.log
        cp "$fixture/full-12.log" "$full_log"
        printf '%s\n' 'run_log:' "  run: \"$2\"" '  mode: log' \
          '  output: "Integration tests\tRun integration\t2026-09-12T22:07:05.2761040Z ======== 120 passed in 30.00s ========\n"' \
          '  truncated: true' '  original_length: 33797' "  full_log: $full_log" \
          'help[1]:' "  Output shows the last 20000 of 33797 chars; full log saved to $full_log - grep it for earlier context"
        ;;
      *' --job 13 '*) log "$2" '"Browser tests\tRun tests\t2026-09-12T22:06:35.2761040Z ======== 8 passed, 1 deselected in 1.00s ========\n"' ;;
      *' --job 14 '*) log "$2" '"Collection tests\tRun tests\t2026-09-12T22:06:35.2761040Z ======== 2 errors in 0.30s ========\n"' ;;
      *' --job 15 '*) log "$2" '"Go tests\tRun tests\t2026-09-12T22:06:35.2761040Z ok  \tgithub.com/acme/repo/pkg\t0.412s\nGo tests\tRun tests\t2026-09-12T22:06:35.2761040Z FM_TEST_EVIDENCE executed=40 skipped=0 deselected=0\n"' ;;
      *' --job 17 '*) log "$2" '"Backend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:58:21.0266236Z Test Suites: 80 passed, 80 total\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:58:21.0267051Z Tests:       1890 passed, 1890 total\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:58:21.0267835Z Snapshots:   5 passed, 5 total\n"' ;;
      *' --job 18 '*) log "$2" '"MCP - Build, Type Check & Tests\tUNKNOWN STEP\t2026-09-13T20:42:38.6908315Z ^[[2m Test Files ^[[22m ^[[1m^[[32m12 passed^[[39m^[[22m^[[90m (12)^[[39m\nMCP - Build, Type Check & Tests\tUNKNOWN STEP\t2026-09-13T20:42:38.6909613Z ^[[2m      Tests ^[[22m ^[[1m^[[32m97 passed^[[39m^[[22m^[[90m (97)^[[39m\n"' ;;
      *' --job 19 '*) log "$2" '"Mobile - Type Check & Tests\tUNKNOWN STEP\t2026-09-13T12:57:01.7588573Z Test Suites: 1 skipped, 94 passed, 94 of 95 total\nMobile - Type Check & Tests\tUNKNOWN STEP\t2026-09-13T12:57:01.7589455Z Tests:       2 skipped, 1 todo, 1645 passed, 1648 total\n"' ;;
      *' --job 20 '*) log "$2" '"Web - Lint, Type Check & Build\tUNKNOWN STEP\t2026-09-13T12:56:35.0233409Z ^[[2m Test Files ^[[22m ^[[1m^[[32m75 passed^[[39m^[[22m^[[90m (75)^[[39m\nWeb - Lint, Type Check & Build\tUNKNOWN STEP\t2026-09-13T12:56:35.0255846Z ^[[2m      Tests ^[[22m ^[[1m^[[32m1770 passed^[[39m^[[22m^[[2m | ^[[22m^[[33m7 skipped^[[39m^[[90m (1777)^[[39m\n"' ;;
      *' --job 21 '*) log "$2" '"Web - E2E Tests (Playwright)\tUNKNOWN STEP\t2026-09-13T19:59:38.1052000Z   1 interrupted\nWeb - E2E Tests (Playwright)\tUNKNOWN STEP\t2026-09-13T19:59:38.1052500Z     [chromium] › e2e/search.spec.ts:40:3 › filters homes by price\nWeb - E2E Tests (Playwright)\tUNKNOWN STEP\t2026-09-13T19:59:38.1053000Z   2 flaky\nWeb - E2E Tests (Playwright)\tUNKNOWN STEP\t2026-09-13T19:59:38.1053500Z     [chromium] › e2e/booking.spec.ts:12:5 › books a home\nWeb - E2E Tests (Playwright)\tUNKNOWN STEP\t2026-09-13T19:59:38.1054278Z   3 skipped\nWeb - E2E Tests (Playwright)\tUNKNOWN STEP\t2026-09-13T19:59:38.1054731Z   99 passed (2.3m)\nWeb - E2E Tests (Playwright)\tUNKNOWN STEP\t2026-09-13T19:59:38.1078774Z ##[notice]  3 skipped\n  99 passed (2.3m)\nWeb - E2E Tests (Playwright)\tUNKNOWN STEP\t2026-09-13T19:59:38.1279903Z Post job cleanup.\n"' ;;
      *' --job 22 '*) log "$2" '"Backend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:57:40.1000000Z FAIL src/__tests__/broken.test.ts\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:57:40.1000001Z   ● Test suite failed to run\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:57:40.1000002Z     Cannot find module '"'"'./does-not-exist'"'"' from '"'"'broken.test.ts'"'"'\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:58:21.0260000Z ^[[1mSummary of all failing tests^[[22m\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:58:21.0260001Z FAIL src/__tests__/broken.test.ts\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:58:21.0260002Z   ^[[1m● ^[[22mTest suite failed to run\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:58:21.0266236Z Test Suites: 1 failed, 79 passed, 80 total\nBackend - Unit Tests\tUNKNOWN STEP\t2026-09-13T12:58:21.0267051Z Tests:       1850 passed, 1850 total\n"' ;;
      *' --job 23 '*) log "$2" '"MCP - Build, Type Check & Tests\tUNKNOWN STEP\t2026-09-13T20:42:38.6900000Z ⎯⎯⎯⎯⎯⎯ Failed Suites 1 ⎯⎯⎯⎯⎯⎯⎯\nMCP - Build, Type Check & Tests\tUNKNOWN STEP\t2026-09-13T20:42:38.6900001Z  FAIL  src/broken.test.ts [ src/broken.test.ts ]\nMCP - Build, Type Check & Tests\tUNKNOWN STEP\t2026-09-13T20:42:38.6908315Z ^[[2m Test Files ^[[22m ^[[1m^[[31m1 failed^[[39m^[[22m^[[2m | ^[[22m^[[1m^[[32m11 passed^[[39m^[[22m^[[90m (12)^[[39m\nMCP - Build, Type Check & Tests\tUNKNOWN STEP\t2026-09-13T20:42:38.6909613Z ^[[2m      Tests ^[[22m ^[[1m^[[32m97 passed^[[39m^[[22m^[[90m (97)^[[39m\nMCP - Build, Type Check & Tests\tUNKNOWN STEP\t2026-09-13T20:42:38.6910000Z ^[[2m     Errors ^[[22m ^[[1m^[[31m1 error^[[39m^[[22m\n"' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi"
}

local_check() {
  env -u GITHUB_ACTIONS -u CI "$CHECK" "$@"
}

test_positive_pr_is_silent() {
  local dir out rc
  dir="$TMP_ROOT/positive"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --pr https://github.com/acme/market-pulse/pull/458 --required-job 'Integration tests' \
    --required-job 'Backend - Unit Tests' --required-job 'MCP - Build, Type Check & Tests' 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "positive PR exit=$rc: $out"
  [ -z "$out" ] || fail "positive PR printed despite complete evidence: $out"
  pass 'positive single-run PR is silent with pytest, Jest, and Vitest executed tests and zero skipped/deselected'
}

test_go_easy_homie_pr_481_skipped_jobs_are_red() {
  local dir out rc job
  dir="$TMP_ROOT/pr-481"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --pr https://github.com/double-d-labs/go-easy-homie/pull/481 \
    --required-job 'Web - Lint, Type Check & Build' --required-job 'Backend - Lint, Type Check & Build' \
    --required-job 'Backend - Unit Tests' --required-job 'Web - E2E Tests (Playwright)' \
    --required-job 'Mobile - Type Check & Tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "PR 481 exit=$rc: $out"
  for job in 'Web - Lint, Type Check & Build' 'Backend - Lint, Type Check & Build' 'Backend - Unit Tests' 'Web - E2E Tests (Playwright)' 'Mobile - Type Check & Tests'; do
    assert_contains "$out" "$job executed=0 skipped=unknown" "skipped PR 481 job $job was not a violation"
  done
  pass 'go-easy-homie PR 481 rejects its five skipped jobs'
}

test_most_recent_skipped_execution_stays_red() {
  local dir out rc
  dir="$TMP_ROOT/recent-skipped"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --pr https://github.com/acme/market-pulse/pull/459 --required-job 'Integration tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "most recent skipped job exit=$rc: $out"
  assert_contains "$out" 'Integration tests executed=0 skipped=unknown' 'older measured execution hid the most recent skipped one'
  pass 'most recent skipped execution of a required job stays red'
}

test_superseded_runs_do_not_stay_red() {
  local dir out rc
  dir="$TMP_ROOT/superseded"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --pr https://github.com/acme/market-pulse/pull/460 --required-job 'Integration tests' --required-job 'Backend - Unit Tests' 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "superseded run exit=$rc: $out"
  [ -z "$out" ] || fail "superseded skipped execution or partial newer run changed the verdict: $out"
  pass 'each required job uses its most recent execution across runs for the head commit'
}

test_log_evidence_violations_are_red() {
  local dir out rc
  dir="$TMP_ROOT/negative"
  make_fixture "$dir"
  out=$(TMPDIR="$dir/tmp" PATH="$dir/fakebin:$PATH" local_check --run https://github.com/acme/repo/actions/runs/481 --required-job 'Integration tests' \
    --required-job 'Browser tests' --required-job 'Collection tests' --required-job 'Go tests' \
    --required-job 'Mobile - Type Check & Tests' --required-job 'Web - Lint, Type Check & Build' \
    --required-job 'Web - E2E Tests (Playwright)' --required-job 'Backend - Unit Tests' \
    --required-job 'MCP - Build, Type Check & Tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "negative run exit=$rc: $out"
  assert_contains "$out" 'Integration tests executed=170 skipped=3 deselected=0' 'skip count before the truncated log tail was not a violation'
  assert_contains "$out" 'Browser tests executed=8 skipped=0 deselected=1' 'deselected count was not a violation'
  assert_contains "$out" 'Collection tests errors=2' 'collection errors were not a distinct violation'
  assert_contains "$out" 'Collection tests executed=0' 'collection errors were counted as executed tests'
  assert_contains "$out" 'not measured: required job Go tests' 'unsupported runner output or a self-declared marker was accepted as evidence'
  assert_contains "$out" 'Mobile - Type Check & Tests executed=1645 skipped=3 deselected=0' 'Jest skipped and todo tests were not a violation'
  assert_contains "$out" 'Web - Lint, Type Check & Build executed=1770 skipped=7 deselected=0' 'Vitest skipped tests were not a violation'
  assert_contains "$out" 'Web - E2E Tests (Playwright) executed=101 skipped=3 deselected=0' 'Playwright flaky tests were not executed evidence or skipped tests were not counted once'
  assert_contains "$out" 'Web - E2E Tests (Playwright) interrupted=1 (' 'Playwright interrupted tests were dropped'
  assert_contains "$out" 'Backend - Unit Tests errors=1 (' 'Jest suite that failed to run was not one distinct errored measurement'
  assert_contains "$out" 'MCP - Build, Type Check & Tests errors=2 (' 'Vitest failed suite and error summary were not errored measurements'
  [ -z "$(ls -A "$dir/tmp")" ] || fail "gh-axi full logs were left in TMPDIR: $(ls -A "$dir/tmp")"
  pass 'skipped, deselected, errored, and unmeasured logs fail despite green conclusions without leaking full logs'
}

test_absent_required_job_is_red() {
  local dir out rc
  dir="$TMP_ROOT/absent"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --run https://github.com/acme/repo/actions/runs/481 --required-job 'Missing tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "absent job exit=$rc: $out"
  assert_contains "$out" 'absent: required job Missing tests' 'absent job was not named'
  pass 'absent required job fails rather than trusting other green checks'
}

test_unreadable_log_is_local_notice_but_ci_failure() {
  local dir out rc
  dir="$TMP_ROOT/unreadable-log"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --run https://github.com/acme/repo/actions/runs/481 --required-job 'Still running' --required-job 'Browser tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "local unreadable log with a violation exit=$rc: $out"
  assert_contains "$out" 'not checked: required job Still running log could not be read' 'local unreadable log was not scoped'
  assert_contains "$out" 'Browser tests executed=8 skipped=0 deselected=1' 'unreadable log stopped later required jobs'
  out=$(PATH="$dir/fakebin:$PATH" local_check --run https://github.com/acme/repo/actions/runs/481 --required-job 'Still running' 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "local unreadable log exit=$rc: $out"
  out=$(PATH="$dir/fakebin:$PATH" GITHUB_ACTIONS=true "$CHECK" --run https://github.com/acme/repo/actions/runs/481 --required-job 'Still running' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "CI unreadable log exit=$rc: $out"
  assert_contains "$out" 'unverified: required job Still running log could not be read' 'CI unreadable log did not fail closed'
  pass 'unreadable log keeps earlier violations locally and fails closed in CI'
}

test_unavailable_read_is_local_notice_but_ci_failure() {
  local out rc path
  path=$(fm_test_base_path_sans "$PATH" gh-axi)
  out=$(PATH="$path" local_check --run https://github.com/acme/repo/actions/runs/9 --required-job tests 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "local unavailable exit=$rc: $out"
  assert_contains "$out" 'not checked: GitHub Actions evidence could not be read because gh-axi is unavailable' 'local unavailable read was not scoped'
  out=$(PATH="$path" GITHUB_ACTIONS=true "$CHECK" --run https://github.com/acme/repo/actions/runs/9 --required-job tests 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "CI unavailable exit=$rc: $out"
  assert_contains "$out" 'unverified: GitHub Actions evidence could not be read because gh-axi is unavailable' 'CI unavailable read did not fail closed'
  pass 'unavailable evidence is usable locally and fail-closed in CI'
}

test_positive_pr_is_silent
test_go_easy_homie_pr_481_skipped_jobs_are_red
test_most_recent_skipped_execution_stays_red
test_superseded_runs_do_not_stay_red
test_log_evidence_violations_are_red
test_absent_required_job_is_red
test_unreadable_log_is_local_notice_but_ci_failure
test_unavailable_read_is_local_notice_but_ci_failure
