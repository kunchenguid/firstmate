#!/usr/bin/env bash
# Fixture-home contract for bin/fm-smoke.sh: a broken wake stage prints the exact
# fail line and exits nonzero; a stubbed passing lab run exits 0 with no orphans.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SMOKE="$ROOT/bin/fm-smoke.sh"
TMP_ROOT=$(fm_test_tmproot fm-smoke)

install_stubs() {  # <home> <wake-mode: broken|ok>
  local home=$1 mode=$2 bin="$1/fakebin" state="$1/state" data="$1/data"
  mkdir -p "$bin" "$state" "$data" "$home/scratch"
  cat > "$bin/fm-herdr-lab.sh" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_SMOKE_LAB_LOG:?}
case "${1:-}" in
  name) printf 'fm-lab-smoke-x\n' ;;
  provision|teardown|stop)
    [ "${2:-}" != default ] || { echo "lab stub refused default" >&2; exit 1; }
    printf '%s %s\n' "$1" "$2" >> "$log" ;;
  run)
    [ "${2:-}" != default ] || exit 1
    printf 'run %s\n' "$2" >> "$log" ;;
  *) echo "fm-herdr-lab: unknown ${1:-}" >&2; exit 2 ;;
esac
SH
  cat > "$bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' 'SESSION START' 'BOOTSTRAP' 'FLEET STATE' 'CONTEXT'
printf '%s\n' "${FM_TEST_START_BANNER:-}"
if [ "${FM_TEST_REJECT_TELEMETRY:-0}" = 1 ]; then
  mkdir -p "$FM_DATA_OVERRIDE/telemetry"
  : > "$FM_DATA_OVERRIDE/telemetry/smoke.jsonl"
  chmod 0644 "$FM_DATA_OVERRIDE/telemetry/smoke.jsonl"
fi
if [ "${FM_TEST_SCOPE:-0}" = 1 ]; then
  [ "$FM_BACKEND" = herdr ] && [ -z "${TMUX:-}" ] &&
    [ "${FM_WAKE_QUEUE:-$FM_STATE_OVERRIDE/.wake-queue}" = "$FM_STATE_OVERRIDE/.wake-queue" ] || exit 72
fi
if [ "${FM_TEST_GIT_HOME:-0}" = 1 ]; then
  [ "$(git -C "$FM_HOME" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$FM_HOME" && pwd -P)" ] || exit 73
fi
exit "${FM_TEST_START_RC:-0}"
SH
  cat > "$bin/fm-harness.sh" <<'SH'
#!/usr/bin/env bash
printf 'pi\n'
SH
  cat > "$bin/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:?}
mkdir -p "$FM_DATA_OVERRIDE/$id"
printf 'brief\n' > "$FM_DATA_OVERRIDE/$id/brief.md"
SH
  cat > "$bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:?}
scratch="$FM_HOME/scratch/$id"
mkdir -p "$scratch" "$FM_STATE_OVERRIDE/$id.inbox/handled"
printf 'window=lab:fm-%s\nkind=scout\naccess=reader\nworktree=%s\nharness=pi\nspawn_gen=g1\n' "$id" "$scratch" > "$FM_STATE_OVERRIDE/$id.meta"
printf 'spawned %s harness=pi kind=scout access=reader window=lab:fm-%s worktree=%s\n' "$id" "$id" "$scratch"
SH
  cat > "$bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:?}
message=${2:?}
mkdir -p "$FM_STATE_OVERRIDE/$id.inbox/handled"
printf '%s\n' "$message" > "$FM_STATE_OVERRIDE/$id.inbox/handled/001.msg"
if [ "${FM_SMOKE_WAKE_MODE:-}" = ok ]; then
  printf 'working: %s\n' "$message" > "$FM_STATE_OVERRIDE/$id.status"
fi
SH
  cat > "$bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --ack-through ]; then
  printf 'acknowledged\n' >&2
  exit 0
fi
cat "$FM_STATE_OVERRIDE/smoke-wake.status" 2>/dev/null || true
printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 1 --recovery-generation g1\n' >&2
SH
  cat > "$bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$bin/fm-pr-check.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_REPLACE_FIELD:-}" ]; then
  meta="$FM_STATE_OVERRIDE/$1.meta"
  awk -F= -v key="$FM_TEST_REPLACE_FIELD" '$1 != key' "$meta" > "$meta.new"
  printf '%s=replacement\n' "$FM_TEST_REPLACE_FIELD" >> "$meta.new"
  /bin/mv "$meta.new" "$meta"
  exit "${FM_TEST_REPLACE_RC:-0}"
fi
if [ "${FM_SMOKE_REAL_PR:-0}" = 1 ]; then
  exec "$FM_SMOKE_REAL_BIN/fm-pr-check.sh" "$@"
fi
exit 0
SH
  cat > "$bin/mv" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_PR_PUBLISH_FAIL:-0}" = 1 ]; then
  for arg in "$@"; do
    case "$arg" in
      */smoke-wake.pr-poll)
        cp "$FM_STATE_OVERRIDE/smoke-wake.meta" "${FM_SMOKE_LAB_LOG}.failed-pr-meta"
        exit 71 ;;
    esac
  done
fi
exec /bin/mv "$@"
SH
  cat > "$bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
SH
  cat > "$bin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ] && [ -n "${FM_TEST_CLOCK:-}" ]; then
  read -r tick < "$FM_TEST_CLOCK"
  printf '%s\n' "$((tick - 1))" > "$FM_TEST_CLOCK"
  printf '%s\n' "$tick"
  exit 0
fi
exec /bin/date "$@"
SH
  cat > "$bin/fm-pr-context-watch.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:?}
printf 'task-teardown %s\n' "$id" >> "$FM_SMOKE_LAB_LOG"
if [ "${FM_SMOKE_REAL_PR:-0}" = 1 ]; then
  cp -R "$FM_STATE_OVERRIDE" "${FM_SMOKE_LAB_LOG}.before-teardown"
fi
rm -rf "$FM_STATE_OVERRIDE/$id.meta" "$FM_STATE_OVERRIDE/$id.inbox" "$FM_STATE_OVERRIDE/$id.status" "$FM_HOME/scratch/$id"
SH
  chmod +x "$bin"/*.sh "$bin/gh" "$bin/mv" "$bin/date"
  printf '%s' "$mode" > "$home/wake-mode"
}

run_smoke() {  # <home> <wake-mode> [wake-budget-ms] -> writes out/err, echoes rc
  local home=$1 mode=$2 wake_ms=${3:-2000} rc=0
  install_stubs "$home" "$mode"
  : > "$home/lab.log"
  mkdir -p "$home/data/telemetry"
  env PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" FM_SMOKE_BIN="$home/fakebin" FM_SMOKE_TASK_ID=smoke-wake \
    FM_SMOKE_LAB_LOG="$home/lab.log" FM_SMOKE_WAKE_MODE="$mode" \
    FM_SMOKE_BUDGET_SESSION_START_MS=5000 FM_SMOKE_BUDGET_SPAWN_MS=5000 \
    FM_SMOKE_BUDGET_STEER_MS=5000 FM_SMOKE_BUDGET_WAKE_MS="$wake_ms" \
    FM_SMOKE_BUDGET_PR_MS=5000 FM_SMOKE_BUDGET_TEARDOWN_MS=5000 \
    "${FM_TEST_SMOKE_SHELL:-bash}" "$SMOKE" > "$home/out" 2> "$home/err" || rc=$?
  printf '%s' "$rc"
}

test_help() {
  local out rc=0
  out=$("$SMOKE" -h) || rc=$?
  expect_code 0 "$rc" "fm-smoke.sh -h"
  assert_contains "$out" "fm-smoke.sh" "-h prints usage"
  pass "fm-smoke.sh -h prints usage and exits 0"
}

test_broken_wake_fails() {
  local home rc line
  home="$TMP_ROOT/broken"
  mkdir -p "$home"
  rc=$(run_smoke "$home" broken 200)
  expect_code 1 "$rc" "broken wake must exit nonzero"
  line=$(grep -E '^stage=steer result=fail ms=[0-9]+ budget_ms=5000 detail=over-budget$' "$home/out" || true)
  [ -n "$line" ] || fail "missing bounded steer failure"$'\n'"--- stdout ---"$'\n'"$(cat "$home/out")"$'\n'"--- stderr ---"$'\n'"$(cat "$home/err")"
  grep -E '^summary result=fail ' "$home/out" >/dev/null || fail "missing failing summary"
  pass "broken wake evidence fails the correlated lifecycle run"
}

test_passing_lab_run() {
  local home rc
  home="$TMP_ROOT/pass"
  mkdir -p "$home"
  rc=$(run_smoke "$home" ok 2000)
  expect_code 0 "$rc" "passing stub lab must exit 0"
  grep -E '^stage=session-start result=pass ' "$home/out" >/dev/null || fail "session-start did not pass"
  grep -E '^stage=spawn result=pass ' "$home/out" >/dev/null || fail "spawn did not pass"
  grep -E '^stage=steer result=pass ' "$home/out" >/dev/null || fail "steer did not pass"
  grep -E '^stage=wake result=pass ' "$home/out" >/dev/null || fail "wake did not pass"
  grep -E '^stage=pr result=skipped ms=[0-9]+ budget_ms=5000 detail=no-FM_SMOKE_PR_URL$' "$home/out" >/dev/null \
    || fail "pr did not skip without URL"$'\n'"$(cat "$home/out")"
  grep -E '^stage=teardown result=pass ' "$home/out" >/dev/null || fail "teardown did not pass"
  grep -E '^summary result=pass ' "$home/out" >/dev/null || fail "missing pass summary"
  order=$(grep '^stage=' "$home/out" | awk -F'[ =]' '{print $2}')
  expected=$(printf '%s\n' session-start spawn steer wake pr teardown)
  [ "$order" = "$expected" ] || fail "stage order was not preserved: $order"
  [ ! -e "$home/state/smoke-wake.meta" ] || fail "teardown left meta"
  [ ! -e "$home/scratch/smoke-wake" ] || fail "teardown left scratch"
  [ ! -d "$home/projects" ] || fail "smoke created projects/"
  grep -F 'provision fm-lab-smoke-x' "$home/lab.log" >/dev/null || fail "lab was not provisioned"
  grep -F 'teardown fm-lab-smoke-x' "$home/lab.log" >/dev/null || fail "lab was not torn down"
  grep -F ' default' "$home/lab.log" >/dev/null && fail "lab helper was invoked on default"
  [ ! -e "$home/state/smoke-wake.meta" ] || fail "caller home was modified"
  [ ! -e "$home/data/telemetry/smoke.jsonl" ] || fail "caller telemetry was modified"
  local evidence ledger
  evidence=$(sed -n 's/^evidence=//p' "$home/out")
  ledger="$evidence/../home/data/telemetry/smoke.jsonl"
  jq -se 'length == 6 and all(.[]; (.at|type)=="string")' "$ledger" >/dev/null || fail "missing timestamped stage rows"
  jq -se 'all(.[]; (.exit_code|type)=="number" and (.ms|type)=="number")' "$evidence/owners.jsonl" >/dev/null || fail "missing exact owner telemetry"
  pass "passing stub lab run exits 0 with no caller-home artifacts"
}

test_start_failure_stops_mutation() {
  local home rc
  home="$TMP_ROOT/start-failure"
  mkdir -p "$home"
  rc=$(FM_TEST_START_RC=23 run_smoke "$home" ok)
  expect_code 1 "$rc" "startup failure must fail the run"
  grep -E '^owner=fm-session-start.sh exit_code=23 ms=[0-9]+$' "$home/out" >/dev/null || fail "exact startup owner exit was lost"
  grep -E '^stage=spawn result=skipped .*detail=prior-stage-failed$' "$home/out" >/dev/null || fail "startup failure allowed spawn"
  grep -E '^stage=teardown result=pass ' "$home/out" >/dev/null || fail "startup failure skipped lab cleanup"
  pass "owner failure retains its exact exit and stops downstream mutation"
}

test_real_pr_registration() {
  local home rc snapshot
  home="$TMP_ROOT/real-pr"
  mkdir -p "$home"
  rc=$(FM_SMOKE_REAL_PR=1 FM_SMOKE_REAL_BIN="$ROOT/bin" \
    FM_SMOKE_PR_URL=https://github.com/example/repository/pull/1 run_smoke "$home" ok)
  expect_code 0 "$rc" "real PR registration composition"
  grep -E '^owner=fm-pr-check.sh exit_code=0 ms=[0-9]+$' "$home/out" >/dev/null || fail "PR stage did not call the registration owner"
  snapshot="$home/lab.log.before-teardown"
  grep -Fx 'pr=https://github.com/example/repository/pull/1' "$snapshot/smoke-wake.meta" >/dev/null || fail "real owner did not record PR identity"
  grep -Fx 'pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$snapshot/smoke-wake.meta" >/dev/null || fail "real owner did not retain observed head"
  [ -s "$snapshot/smoke-wake.check.sh" ] || fail "real owner did not install the PR poll"
  pass "smoke composes the real PR registration owner without fabricated test evidence"
}

test_start_banner_and_scope() {
  local home rc
  home="$TMP_ROOT/banner-scope"
  mkdir -p "$home"
  rc=$(FM_BACKEND=tmux TMUX=foreign FM_WAKE_QUEUE="$home/foreign-queue" \
    FM_TEST_SCOPE=1 FM_TEST_START_BANNER='STARTUP TRUNCATED - SESSION START HIT ITS RUNTIME BOUND' \
    run_smoke "$home" ok)
  expect_code 1 "$rc" "uppercase startup refusal"
  grep -E '^owner=fm-session-start.sh exit_code=0 ms=[0-9]+$' "$home/out" >/dev/null || fail "owner received inherited operational selectors"
  grep -E '^stage=session-start result=fail ' "$home/out" >/dev/null || fail "uppercase startup refusal was accepted"
  grep -E '^stage=spawn result=skipped ' "$home/out" >/dev/null || fail "truncated startup allowed mutation"
  [ ! -e "$home/foreign-queue" ] || fail "foreign queue was modified"
  pass "inherited selectors are isolated and uppercase truncation gates mutation"
}

test_git_home_is_self_contained() {
  local home rc
  home="$TMP_ROOT/git-home"
  mkdir -p "$home"
  rc=$(FM_TEST_GIT_HOME=1 run_smoke "$home" ok)
  expect_code 0 "$rc" "lab owner must resolve its own Git root"
  pass "lab Git discovery cannot escape into an enclosing repository"
}

test_foreign_git_archive() {
  local home rc evidence foreign
  home="$TMP_ROOT/foreign-git"
  foreign="$home/foreign"
  mkdir -p "$foreign"
  git -C "$foreign" init -q
  printf 'private foreign content\n' > "$foreign/foreign-content"
  git -C "$foreign" add foreign-content
  git -C "$foreign" -c commit.gpgsign=false -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
  rc=$(GIT_DIR="$foreign/.git" run_smoke "$home" ok)
  expect_code 0 "$rc" "archive must select the script checkout, not inherited GIT_DIR"
  evidence=$(sed -n 's/^evidence=//p' "$home/out")
  [ ! -e "$evidence/../home/foreign-content" ] || fail "archive consumed foreign Git content"
  [ -s "$evidence/../home/README.md" ] || fail "archive did not seed checkout support files"
  pass "source archive ignores foreign Git selectors"
}

test_failed_pr_registration_tears_down_same_task() {
  local home rc evidence
  home="$TMP_ROOT/failed-pr"
  mkdir -p "$home"
  rc=$(FM_SMOKE_REAL_PR=1 FM_SMOKE_REAL_BIN="$ROOT/bin" FM_TEST_PR_PUBLISH_FAIL=1 \
    FM_SMOKE_PR_URL=https://github.com/example/repository/pull/1 run_smoke "$home" ok)
  expect_code 1 "$rc" "failed real PR publication must fail smoke"
  grep -Fx 'pr=https://github.com/example/repository/pull/1' "$home/lab.log.failed-pr-meta" >/dev/null || fail "fixture did not reach metadata rewrite before publication failure"
  grep -E '^owner=fm-pr-check.sh exit_code=1 ms=[0-9]+$' "$home/out" >/dev/null || fail "real PR owner exit was lost"
  grep -E '^stage=pr result=fail .*detail=pr-check-failed$' "$home/out" >/dev/null || fail "failed PR stage was not retained"
  grep -E '^stage=teardown result=pass ' "$home/out" >/dev/null || fail "failed registration suppressed task teardown"
  [ "$(grep -c '^task-teardown smoke-wake$' "$home/lab.log")" = 1 ] || fail "same task must be delegated to teardown exactly once"
  evidence=$(sed -n 's/^evidence=//p' "$home/out")
  [ ! -e "$evidence/../home/state/smoke-wake.meta" ] || fail "failed registration left task metadata"
  [ ! -e "$evidence/../home/scratch/smoke-wake" ] || fail "failed registration left scratch"
  pass "failed real PR publication preserves identity and delegates teardown"
}

test_replaced_task_refuses_teardown() {
  local home rc evidence field owner_rc
  for field in spawn_gen window worktree; do
    for owner_rc in 0 31; do
      home="$TMP_ROOT/replaced-$field-$owner_rc"
      mkdir -p "$home"
      rc=$(FM_TEST_REPLACE_FIELD="$field" FM_TEST_REPLACE_RC="$owner_rc" \
        FM_SMOKE_PR_URL=https://github.com/example/repository/pull/1 run_smoke "$home" ok)
      expect_code 1 "$rc" "replaced $field must fail smoke even after owner exit $owner_rc"
      grep -E '^stage=teardown result=fail .*detail=spawn-receipt-lost$' "$home/out" >/dev/null || fail "replacement $field was trusted"
      ! grep -q '^task-teardown ' "$home/lab.log" || fail "teardown invoked on replacement $field"
      evidence=$(sed -n 's/^evidence=//p' "$home/out")
      grep -Fx "$field=replacement" "$evidence/../home/state/smoke-wake.meta" >/dev/null || fail "replacement metadata was removed"
      [ -d "$evidence/../home/scratch/smoke-wake" ] || fail "replacement scratch was removed"
    done
  done
  pass "PR owner success or failure cannot authorize teardown of changed task identity"
}

test_backward_owner_clock() {
  local home rc evidence tick
  home="$TMP_ROOT/backward-clock"
  mkdir -p "$home"
  printf '1000\n' > "$home/clock"
  printf 'unset EPOCHREALTIME\n' > "$home/clock-env"
  rc=$(BASH_ENV="$home/clock-env" FM_TEST_CLOCK="$home/clock" FM_TEST_SMOKE_SHELL=/bin/bash run_smoke "$home" ok)
  expect_code 0 "$rc" "clock correction must not change successful owner exits"
  read -r tick < "$home/clock"
  [ "$tick" -lt 990 ] || fail "fixture did not exercise the backward clock"
  awk '/^owner=/ {count++; if ($3 !~ /^ms=[0-9]+$/) exit 1} END {if (!count) exit 1}' "$home/out" || fail "printed owner duration was negative"
  evidence=$(sed -n 's/^evidence=//p' "$home/out")
  jq -se 'length > 0 and all(.[]; .ms >= 0 and .exit_code == 0)' "$evidence/owners.jsonl" >/dev/null || fail "durable owner duration was negative or exit changed"
  pass "backward epoch clock preserves nonnegative owner durations and exact exits"
}

test_rejected_telemetry_keeps_all_stage_outcomes() {
  local home rc evidence stage
  home="$TMP_ROOT/rejected-telemetry"
  mkdir -p "$home"
  rc=$(FM_TEST_REJECT_TELEMETRY=1 run_smoke "$home" ok)
  expect_code 1 "$rc" "unsafe telemetry must fail smoke"
  for stage in spawn steer wake pr; do
    grep -E "^stage=$stage result=skipped .*detail=prior-stage-failed$" "$home/out" >/dev/null || fail "rejected ledger erased $stage skip"
  done
  for stage in session-start teardown; do
    grep -E "^stage=$stage result=fail .*detail=telemetry-failed$" "$home/out" >/dev/null || fail "rejected ledger did not fail $stage"
  done
  [ "$(grep -c '^stage=' "$home/out")" = 6 ] || fail "console must report exactly six outcomes"
  [ "$(grep '^stage=' "$home/out" | cut -d' ' -f1)" = "$(printf 'stage=%s\n' session-start spawn steer wake pr teardown)" ] || fail "telemetry rejection changed stage order"
  grep -Fx 'summary result=fail passed=0 failed=2 skipped=4' "$home/out" >/dev/null || fail "summary disagrees with represented stage outcomes"
  ! grep -E '^owner=fm-(brief|spawn|send|wake-drain|pr-check)\.sh ' "$home/out" || fail "downstream mutation ran after telemetry failure"
  ! grep -q '^task-teardown ' "$home/lab.log" || fail "unspawned task teardown was invoked"
  grep -Fx 'teardown fm-lab-smoke-x' "$home/lab.log" >/dev/null || fail "telemetry rejection prevented lab cleanup"
  evidence=$(sed -n 's/^evidence=//p' "$home/out")
  [ ! -s "$evidence/../home/data/telemetry/smoke.jsonl" ] || fail "unsafe ledger received rows"
  pass "rejected private ledger keeps six truthful console outcomes and matching totals"
}

test_help
test_broken_wake_fails
test_passing_lab_run
test_start_failure_stops_mutation
test_real_pr_registration
test_start_banner_and_scope
test_git_home_is_self_contained
test_foreign_git_archive
test_failed_pr_registration_tears_down_same_task
test_replaced_task_refuses_teardown
test_backward_owner_clock
test_rejected_telemetry_keeps_all_stage_outcomes
