#!/usr/bin/env bash
# Tests for fm-runner-health-check.sh, the GitHub Actions runner health watch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-runner-health-check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-runner-health-check)
REPOSITORY=connectwithclayton/toolroll
LABEL=toolroll-mac

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

make_fake_gh_axi() {
  local name=$1 fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/$name")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u

[ "${1:-}" = api ] || exit 9
[ "${2:-}" = "/repos/${FAKE_GH_AXI_REPOSITORY}/actions/runners" ] || exit 9

case "${FAKE_GH_AXI_MODE:-answer}" in
  auth-error) exit 1 ;;
  slow) sleep "${FAKE_GH_AXI_SLEEP:-10}" ;;
  malformed)
    printf 'not an API response\n'
    exit 0
    ;;
esac

query=
full=0
paginate=0
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq)
      [ "$#" -ge 2 ] || exit 9
      query=$2
      shift 2
      ;;
    --full)
      full=1
      shift
      ;;
    --paginate)
      paginate=1
      shift
      ;;
    *) exit 9 ;;
  esac
done
[ -n "$query" ] && [ "$full" -eq 1 ] || exit 9
if [ "${FAKE_GH_AXI_MODE:-answer}" = pagination ]; then
  [ "$paginate" -eq 1 ] || exit 9
  body_one=$(jq -r "$query" "$FAKE_GH_AXI_RESPONSE/page-1.json") || exit 9
  body_two=$(jq -r "$query" "$FAKE_GH_AXI_RESPONSE/page-2.json") || exit 9
  printf 'api_response:\n'
  printf '  body: "%s\\n%s"\n' "$body_one" "$body_two"
  printf '  truncated: false\n'
  exit 0
fi
body=$(jq -r "$query" "$FAKE_GH_AXI_RESPONSE") || exit 9
printf 'api_response:\n'
printf '  body: %s\n' "$body"
printf '  truncated: false\n'
if [ "${FAKE_GH_AXI_MODE:-answer}" = malformed-trailing ]; then
  printf 'diagnostic: unexpected trailing output\n'
fi
SH
  chmod 0755 "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

write_runners() {
  local file=$1 status=$2 busy=${3:-false}
  cat > "$file" <<JSON
{"runners":[{"name":"toolroll-mac","status":"$status","busy":$busy,"labels":[{"name":"self-hosted"},{"name":"macOS"},{"name":"ARM64"},{"name":"toolroll-mac"}]}]}
JSON
}

write_no_matching_runner() {
  local file=$1
  cat > "$file" <<'JSON'
{"runners":[{"name":"another-runner","status":"online","busy":false,"labels":[{"name":"self-hosted"},{"name":"another-label"}]}]}
JSON
}

run_check() {
  local home=$1 fakebin=$2 response=$3 out=$4
  shift 4
  local status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" \
    FAKE_GH_AXI_REPOSITORY="$REPOSITORY" FAKE_GH_AXI_RESPONSE="$response" \
    "$@" "$CHECK" check "$REPOSITORY" "$LABEL" > "$out" 2>&1 || status=$?
  expect_code 0 "$status" "runner health check exit"
}

expect_reported() {
  local home=$1 expected=$2 actual
  actual=$(sed -n 's/^reported=//p' "$home/state/.runner-health")
  [ "$actual" = "$expected" ] || fail "expected recorded finding '$expected', got '$actual'"
}

test_online_runner_is_silent_even_when_busy() {
  local home fakebin response out
  home=$(make_home online)
  fakebin=$(make_fake_gh_axi online)
  response="$home/runners.json"
  out="$home/out.txt"

  write_runners "$response" online false
  run_check "$home" "$fakebin" "$response" "$out"
  [ ! -s "$out" ] || fail "an idle online runner produced a report: $(cat "$out")"

  write_runners "$response" online true
  run_check "$home" "$fakebin" "$response" "$out"
  [ ! -s "$out" ] || fail "a busy online runner produced a report: $(cat "$out")"
  expect_reported "$home" ''
  pass "an online runner is healthy and silent whether idle or busy"
}

test_offline_runner_reports_once_and_reports_again_after_recovery() {
  local home fakebin response out report
  home=$(make_home outage)
  fakebin=$(make_fake_gh_axi outage)
  response="$home/runners.json"
  out="$home/out.txt"

  write_runners "$response" offline false
  run_check "$home" "$fakebin" "$response" "$out"
  report=$(cat "$out")
  assert_contains "$report" "runner health: $REPOSITORY runner label $LABEL is offline" "the first offline result was not reported"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the outage report was not exactly one line"
  expect_reported "$home" offline

  run_check "$home" "$fakebin" "$response" "$out"
  [ ! -s "$out" ] || fail "the same outage was reported twice: $(cat "$out")"

  write_runners "$response" online false
  run_check "$home" "$fakebin" "$response" "$out"
  [ ! -s "$out" ] || fail "recovery produced a report: $(cat "$out")"
  expect_reported "$home" ''

  write_runners "$response" offline false
  run_check "$home" "$fakebin" "$response" "$out"
  assert_contains "$(cat "$out")" "is offline" "an outage returning after recovery was suppressed"
  pass "one outage reports once, recovery is silent, and a later outage reports again"
}

test_missing_label_is_a_distinct_once_only_finding() {
  local home fakebin response out
  home=$(make_home missing)
  fakebin=$(make_fake_gh_axi missing)
  response="$home/runners.json"
  out="$home/out.txt"

  write_no_matching_runner "$response"
  run_check "$home" "$fakebin" "$response" "$out"
  assert_contains "$(cat "$out")" "has no registered runner with label $LABEL" "a missing runner label was not reported"
  expect_reported "$home" missing
  run_check "$home" "$fakebin" "$response" "$out"
  [ ! -s "$out" ] || fail "the same missing-label finding was reported twice: $(cat "$out")"
  pass "a missing runner registration is reported once and distinguished from offline"
}

test_api_failures_are_silent_and_do_not_clear_an_outage() {
  local home fakebin response out
  home=$(make_home unavailable)
  fakebin=$(make_fake_gh_axi unavailable)
  response="$home/runners.json"
  out="$home/out.txt"

  write_runners "$response" offline false
  run_check "$home" "$fakebin" "$response" "$out"
  expect_reported "$home" offline

  run_check "$home" "$fakebin" "$response" "$out" FAKE_GH_AXI_MODE=auth-error
  [ ! -s "$out" ] || fail "an API authentication failure produced a runner report: $(cat "$out")"
  expect_reported "$home" offline

  run_check "$home" "$fakebin" "$response" "$out" FAKE_GH_AXI_MODE=malformed
  [ ! -s "$out" ] || fail "a malformed API response produced a runner report: $(cat "$out")"
  expect_reported "$home" offline

  run_check "$home" "$fakebin" "$response" "$out"
  [ ! -s "$out" ] || fail "an unavailable poll made the same outage look new: $(cat "$out")"
  pass "network, authentication, and malformed responses stay silent without changing known health"
}

test_paginated_api_results_are_aggregated_before_verdict() {
  local home fakebin response out
  home=$(make_home pagination)
  fakebin=$(make_fake_gh_axi pagination)
  response="$home/pages"
  out="$home/out.txt"
  mkdir -p "$response"
  write_runners "$response/page-1.json" offline false
  write_runners "$response/page-2.json" online true

  run_check "$home" "$fakebin" "$response" "$out" FAKE_GH_AXI_MODE=pagination
  [ ! -s "$out" ] || fail "an online runner on a later page was reported unavailable: $(cat "$out")"
  expect_reported "$home" ''
  pass "paginated runner pages are aggregated before deciding health"
}

test_malformed_envelope_with_trailing_diagnostics_is_silent() {
  local home fakebin response out
  home=$(make_home malformed-envelope)
  fakebin=$(make_fake_gh_axi malformed-envelope)
  response="$home/runners.json"
  out="$home/out.txt"
  write_runners "$response" offline false

  run_check "$home" "$fakebin" "$response" "$out" FAKE_GH_AXI_MODE=malformed-trailing
  [ ! -s "$out" ] || fail "a response with trailing diagnostics produced a health report: $(cat "$out")"
  assert_absent "$home/state/.runner-health" "a malformed response wrote a health verdict"
  pass "a valid-looking envelope with trailing diagnostics is rejected"
}

test_api_timeout_finishes_inside_the_watcher_bound() {
  local home fakebin response out before after elapsed
  home=$(make_home timeout)
  fakebin=$(make_fake_gh_axi timeout)
  response="$home/runners.json"
  out="$home/out.txt"
  write_runners "$response" offline false

  before=$(date +%s)
  run_check "$home" "$fakebin" "$response" "$out" \
    FAKE_GH_AXI_MODE=slow FAKE_GH_AXI_SLEEP=10 FM_RUNNER_HEALTH_PROBE_SECS=1 FM_CHECK_TIMEOUT=5
  after=$(date +%s)
  elapsed=$((after - before))
  [ "$elapsed" -le 3 ] || fail "the bounded API poll took ${elapsed}s inside a 5s watcher bound"
  [ ! -s "$out" ] || fail "a timed-out API poll produced a runner report: $(cat "$out")"
  assert_absent "$home/state/.runner-health" "a timed-out API poll wrote a health verdict"
  pass "a timed-out API poll fails quietly and finishes inside the watcher bound"
}

test_target_validation_refuses_unsafe_or_ambiguous_values() {
  local home fakebin status
  home=$(make_home validation)
  fakebin=$(make_fake_gh_axi validation)

  status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" "$CHECK" check toolroll "$LABEL" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "repository without owner exit"
  status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" "$CHECK" check "$REPOSITORY" 'label with spaces' >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unsafe label exit"
  status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" FM_RUNNER_HEALTH_PROBE_SECS=99 \
    "$CHECK" check "$REPOSITORY" "$LABEL" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "oversized probe bound exit"
  pass "invalid targets and probe bounds refuse instead of reaching the API"
}

test_arm_registers_a_targeted_shim_and_disarm_removes_it() {
  local home fakebin response out status mode
  home=$(make_home arm)
  fakebin=$(make_fake_gh_axi arm)
  response="$home/runners.json"
  out="$home/out.txt"
  write_runners "$response" offline false

  status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" "$CHECK" arm "$REPOSITORY" "$LABEL" >/dev/null || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/runner-health.check.sh" "arm did not write the runner-health shim"
  assert_present "$home/state/runner-health.check-trust" "arm did not bind the runner-health shim"
  mode=$(stat -c %a "$home/state/runner-health.check.sh" 2>/dev/null || stat -f %Lp "$home/state/runner-health.check.sh")
  [ "$mode" = 700 ] || fail "the runner-health shim mode was $mode instead of 700"
  assert_grep 'fm-custom-check-v1' "$home/state/runner-health.check-trust" "the runner-health trust binding has the wrong schema"

  status=0
  (cd / && env -u FM_HOME PATH="$fakebin:$PATH" \
    FAKE_GH_AXI_REPOSITORY="$REPOSITORY" FAKE_GH_AXI_RESPONSE="$response" \
    "$home/state/runner-health.check.sh" > "$out" 2>&1) || status=$?
  expect_code 0 "$status" "armed shim exit"
  assert_contains "$(cat "$out")" "$REPOSITORY runner label $LABEL is offline" "the shim lost its named repository or label"

  FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/runner-health.check.sh" "disarm left the runner-health shim"
  assert_absent "$home/state/runner-health.check-trust" "disarm left the runner-health trust binding"
  assert_absent "$home/state/.runner-health" "disarm left the runner-health report record"
  pass "arm registers the named target and disarm removes every watch artifact"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home fakebin target status
  home=$(make_home symlink)
  fakebin=$(make_fake_gh_axi symlink)
  target="$home/not-the-shim"
  printf 'do not replace me\n' > "$target"
  ln -s "$target" "$home/state/runner-health.check.sh"

  status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" "$CHECK" arm "$REPOSITORY" "$LABEL" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over symlink exit"
  [ "$(cat "$target")" = 'do not replace me' ] || fail "arm followed the shim symlink"
  assert_absent "$home/state/runner-health.check-trust" "arm registered a refused shim"
  pass "arm refuses a symlink instead of writing outside the private state file"
}

test_arm_and_disarm_refuse_a_symlinked_state_directory() {
  local home fakebin target status
  home=$(make_home symlinked-state)
  fakebin=$(make_fake_gh_axi symlinked-state)
  target="$home/state-target"
  mkdir -p "$target"
  printf 'do not delete me\n' > "$target/runner-health.check.sh"
  mv "$home/state" "$home/state-real"
  ln -s "$target" "$home/state"

  status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" "$CHECK" arm "$REPOSITORY" "$LABEL" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm with symlinked state exit"
  [ "$(cat "$target/runner-health.check.sh")" = 'do not delete me' ] \
    || fail "arm removed an artifact through a symlinked state directory"

  status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" "$CHECK" disarm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "disarm with symlinked state exit"
  [ "$(cat "$target/runner-health.check.sh")" = 'do not delete me' ] \
    || fail "disarm removed an artifact through a symlinked state directory"
  [ -L "$home/state" ] || fail "symlinked state directory was replaced"
  pass "arm and disarm refuse a symlinked state directory without cleanup"
}

test_armed_check_reaches_the_existing_watcher() {
  local home fakebin response out err status
  home=$(make_home watcher)
  fakebin=$(make_fake_gh_axi watcher)
  response="$home/runners.json"
  out="$home/out.txt"
  err="$home/err.txt"
  write_runners "$response" offline false
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  env FM_HOME="$home" PATH="$fakebin:$PATH" "$CHECK" arm "$REPOSITORY" "$LABEL" >/dev/null \
    || fail "could not arm the runner-health check"

  status=0
  env FM_HOME="$home" PATH="$fakebin:$PATH" \
    FAKE_GH_AXI_REPOSITORY="$REPOSITORY" FAKE_GH_AXI_RESPONSE="$response" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=5 \
    "$CHECKPOINT" --seconds 10 > "$out" 2> "$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "the runner outage did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" "runner health: $REPOSITORY runner label $LABEL is offline" "the wake lost the runner outage report"
  pass "the armed runner-health check reaches the existing watcher wake path"
}

test_online_runner_is_silent_even_when_busy
test_offline_runner_reports_once_and_reports_again_after_recovery
test_missing_label_is_a_distinct_once_only_finding
test_api_failures_are_silent_and_do_not_clear_an_outage
test_paginated_api_results_are_aggregated_before_verdict
test_malformed_envelope_with_trailing_diagnostics_is_silent
test_api_timeout_finishes_inside_the_watcher_bound
test_target_validation_refuses_unsafe_or_ambiguous_values
test_arm_registers_a_targeted_shim_and_disarm_removes_it
test_arm_refuses_a_symlink_at_the_shim_path
test_arm_and_disarm_refuse_a_symlinked_state_directory
test_armed_check_reaches_the_existing_watcher
