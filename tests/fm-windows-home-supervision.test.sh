#!/usr/bin/env bash
# Focused regression coverage for mode-ambiguous operational homes.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-windows-home-supervision)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_STAT=$(command -v stat)
GOOD_HEAD=0123456789abcdef0123456789abcdef01234567
CHANGED_HEAD=abcdef0123456789abcdef0123456789abcdef01
URL=https://github.com/o/r/pull/7

make_case() {
  local name=$1 dir=$TMP_ROOT/$1
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' 'endpoint_task_id=task-a' \
    "worktree=$dir/wt" 'project=project' 'kind=ship' 'mode=local-only'
  printf '%s\n' "$dir"
}

make_ambiguous_stat() {
  local fakebin=$1
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */.fm-state-capability.*) exit 1 ;; esac
done
exec "$FM_TEST_REAL_STAT" "$@"
SH
  chmod +x "$fakebin/stat"
}

make_gh_axi() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:?}"
emit() { printf 'api_response:\n  body: "%s"\n  truncated: false\n' "$1"; }
if [ "${1:-}" = api ]; then
  endpoint=${2:-}
  [ "${FM_TEST_GH_CASE:-good}" = command-failure ] && exit 1
  case "$endpoint" in
    /repos/o/r/pulls/7)
      case "${FM_TEST_GH_CASE:-good}" in
        missing) emit "https://github.com/o/r/pull/7\t$GOOD_HEAD\topen\tfalse\ttrue" ;;
        multiple) emit "https://github.com/o/r/pull/7\t$GOOD_HEAD\topen\tfalse\ttrue\tclean\textra" ;;
        changed-head) emit "https://github.com/o/r/pull/7\t$CHANGED_HEAD\topen\tfalse\ttrue\tclean" ;;
        unstable) emit "https://github.com/o/r/pull/7\t$GOOD_HEAD\topen\tfalse\ttrue\tunstable" ;;
        closed) emit "https://github.com/o/r/pull/7\t$GOOD_HEAD\tclosed\tfalse\ttrue\tclean" ;;
        *) emit "https://github.com/o/r/pull/7\t$GOOD_HEAD\topen\tfalse\ttrue\tclean" ;;
      esac
      ;;
    /repos/o/r/commits/*/status)
      case "${FM_TEST_GH_CASE:-good}" in
        red) emit 'failure\t1' ;;
        pending) emit 'pending\t1' ;;
        missing-status) emit '' ;;
        *) emit 'success\t1' ;;
      esac
      ;;
    /repos/o/r/commits/*/check-runs)
      case "${FM_TEST_GH_CASE:-good}" in
        incomplete) emit '1\tin_progress\tsuccess' ;;
        skipped) emit '1\tcompleted\tskipped' ;;
        ambiguous) emit '1\tbogus\tsuccess' ;;
        red) emit '1\tcompleted\tfailure' ;;
        *) emit '1\tcompleted\tsuccess' ;;
      esac
      ;;
    *) exit 1 ;;
  esac
elif [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then
  printf 'pr merge\n' >> "${FM_TEST_GH_LOG:?}"
else
  exit 1
fi
SH
  chmod +x "$fakebin/gh-axi"
}

run_data_only() {
  local dir=$1
  shift
  env GOOD_HEAD="$GOOD_HEAD" CHANGED_HEAD="$CHANGED_HEAD" \
    FM_TEST_REAL_STAT="$REAL_STAT" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" "$@"
}

assert_no_data_only_artifacts() {
  local state=$1 path
  for path in "$state"/*.check.sh "$state"/*.check-trust "$state"/*.pr-poll \
    "$state"/*.pr-poll-registration "$state"/*.pr-poll-retirement \
    "$state"/x-watch.check.sh "$state"/.pr-check-quarantine \
    "$state"/.pr-check-migration.log "$state"/.pr-check-migration-v1 \
    "$state"/.pr-check-migration-scan-v1; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    fail "data-only path created executable/check artifact: $path"
  done
}

record_data_only() {
  local dir=$1
  FM_TEST_GH_CASE=good run_data_only "$dir" "$ROOT/bin/fm-pr-check.sh" task-a "$URL" \
    > "$dir/record.out" 2> "$dir/record.err" \
    || fail "data-only PR recording failed: $(cat "$dir/record.err")"
  grep -qxF "pr=$URL" "$dir/home/state/task-a.meta" || fail "canonical URL was not recorded"
  grep -qxF "pr_head=$GOOD_HEAD" "$dir/home/state/task-a.meta" || fail "validated head was not recorded"
  assert_no_data_only_artifacts "$dir/home/state"
}

test_capability_and_secure_mode() {
  local dir state
  dir=$(make_case secure)
  state="$dir/home/state"
  . "$ROOT/bin/fm-state-capability-lib.sh"
  fm_state_mode_detect "$state"
  [ "$FM_STATE_MODE" = secure ] || fail "ordinary filesystem was not detected as secure"
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_write_meta "$state/secure-id.meta" 'window=fm-secure-id' 'pr=https://github.com/o/r/pull/7'
  fm_pr_poll_prepare "$state" secure-id github "$URL" github.com o/r 7 "$ROOT/bin/fm-pr-poll.sh" \
    || fail "secure mode no longer prepares the authenticated poll"
  fm_pr_poll_publish_prepared || fail "secure mode did not publish the authenticated poll"
  [ -f "$state/secure-id.check.sh" ] || fail "secure mode lost its executable poll"

  dir=$(make_case ambiguous)
  make_ambiguous_stat "$dir/fakebin"
  FM_TEST_REAL_STAT="$REAL_STAT" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1"; fm_state_mode_detect "$2"; printf "%s\\n" "$FM_STATE_MODE"' \
    _ "$ROOT/bin/fm-state-capability-lib.sh" "$dir/home/state" > "$dir/mode.out"
  grep -qxF data-only "$dir/mode.out" || fail "ambiguous mode reporting did not select data-only"
  pass "capability detection preserves secure mode and selects data-only on ambiguity"
}

test_data_only_startup() {
  local dir out
  dir=$(make_case startup)
  make_ambiguous_stat "$dir/fakebin"
  make_gh_axi "$dir/fakebin"
  : > "$dir/gh.log"
  out=$(env FM_TEST_REAL_STAT="$REAL_STAT" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-bootstrap.sh" 2> "$dir/bootstrap.err")
  printf '%s\n' "$out" > "$dir/bootstrap.out"
  grep -q '^BOOTSTRAP_INFO: data-only supervision is active because ' "$dir/bootstrap.out" \
    || fail "data-only startup did not emit BOOTSTRAP_INFO"
  ! grep -q '^PR_CHECK_MIGRATION:' "$dir/bootstrap.out" || fail "migration ran in data-only mode"
  assert_no_data_only_artifacts "$dir/home/state"
  pass "data-only startup uses BOOTSTRAP_INFO and creates no executable artifacts"
}

test_refusal_and_no_execution() {
  local dir state marker rc out
  dir=$(make_case refusal)
  state="$dir/home/state"
  make_ambiguous_stat "$dir/fakebin"
  make_gh_axi "$dir/fakebin"
  : > "$dir/gh.log"
  marker="$dir/executed"
  printf '#!/usr/bin/env bash\nprintf executed > %s\n' "$marker" > "$state/task-a.check.sh"
  chmod 700 "$state/task-a.check.sh"
  set +e
  run_data_only "$dir" "$ROOT/bin/fm-pr-check.sh" task-a "$URL" > /dev/null 2> "$dir/refuse.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pre-existing check artifact was accepted"
  [ ! -e "$marker" ] || fail "pre-existing check artifact was executed"
  ! grep -q 'api ' "$dir/gh.log" || fail "pre-existing check refusal queried GitHub"
  set +e
  out=$(run_data_only "$dir" "$ROOT/bin/fm-check-register.sh" task-a 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && grep -q 'data-only supervision refuses' <<< "$out" || fail "custom check did not refuse"
  set +e
  out=$(FMX_PAIRING_TOKEN=token run_data_only "$dir" "$ROOT/bin/fm-x-poll.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && grep -q 'data-only supervision refuses' <<< "$out" || fail "X polling did not refuse"
  [ -f "$state/task-a.check.sh" ] || fail "pre-existing check artifact was removed"
  pass "pre-existing checks, custom checks, and X polling refuse without execution"
}

test_inspection_and_revalidation() {
  local dir rc scenario
  dir=$(make_case merge)
  make_ambiguous_stat "$dir/fakebin"
  make_gh_axi "$dir/fakebin"
  : > "$dir/gh.log"
  record_data_only "$dir"
  FM_TEST_GH_CASE=good run_data_only "$dir" "$ROOT/bin/fm-pr-inspect.sh" "$URL" \
    --expected-head "$GOOD_HEAD" --require-green > "$dir/inspect.out" \
    || fail "direct GitHub inspection failed"
  grep -qxF checks=green "$dir/inspect.out" || fail "green checks were not reported"
  FM_TEST_GH_CASE=good run_data_only "$dir" "$ROOT/bin/fm-pr-merge.sh" task-a "$URL" \
    > /dev/null 2> "$dir/merge.err" || fail "authorized pre-merge revalidation failed"
  grep -q '^pr merge$' "$dir/gh.log" || fail "successful revalidation did not reach merge"
  for scenario in changed-head red incomplete skipped ambiguous unstable command-failure; do
    dir=$(make_case "revalidate-$scenario")
    make_ambiguous_stat "$dir/fakebin"
    make_gh_axi "$dir/fakebin"
    : > "$dir/gh.log"
    record_data_only "$dir"
    set +e
    FM_TEST_GH_CASE=$scenario run_data_only "$dir" "$ROOT/bin/fm-pr-merge.sh" task-a "$URL" \
      > /dev/null 2> "$dir/merge.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$scenario revalidation was accepted"
    ! grep -q '^pr merge$' "$dir/gh.log" || fail "$scenario revalidation reached merge"
  done
  pass "direct GitHub status inspection and pre-merge revalidation fail closed"
}

test_identity_adversaries() {
  local dir state rc
  dir=$(make_case identity)
  state="$dir/home/state"
  make_ambiguous_stat "$dir/fakebin"
  make_gh_axi "$dir/fakebin"
  ln -s "$state/task-a.meta" "$state/task-a-link.meta"
  set +e
  run_data_only "$dir" "$ROOT/bin/fm-pr-check.sh" task-a-link "$URL" >/dev/null 2> "$dir/link.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlink metadata was accepted"
  ln "$state/task-a.meta" "$state/task-a-second-link.meta"
  set +e
  run_data_only "$dir" "$ROOT/bin/fm-pr-check.sh" task-a-second-link "$URL" >/dev/null 2> "$dir/hard-link.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "multi-link metadata was accepted"
  set +e
  "$ROOT/bin/fm-pr-inspect.sh" 'https://github.com/o/r/pull/../7' >/dev/null 2> "$dir/url.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed PR URL was accepted"
  pass "symlink, multi-link, and malformed-URL identity paths fail closed"
}

test_capability_and_secure_mode
test_data_only_startup
test_refusal_and_no_execution
test_inspection_and_revalidation
test_identity_adversaries
